#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Offline checks: no GitHub mutations and no macOS toolchain required."""
import importlib.util
import base64
import json
import os
import plistlib
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from release_targets import TARGETS, RELEASE_FLAVORS
import installer_metadata

SCRIPTS = Path(__file__).resolve().parent

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS/filename)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

CI = module('ci_release', 'ci-release.py')
PACK = module('package_release', 'package-release.py')
META = dict(tag='v1.2.3', version='1.2.3', build='45', commit='a' * 40)

class ReleaseTests(unittest.TestCase):
    def test_github_failure_reports_actionable_stderr(self):
        failure = subprocess.CompletedProcess(['gh'], 1, '', 'workflow scope may be required')
        with patch.object(CI.subprocess, 'run', return_value=failure):
            with self.assertRaisesRegex(RuntimeError, 'workflow scope may be required'):
                CI.gh('release', 'create', 'v1.2.3')
            self.assertIs(CI.gh('release', 'view', 'v1.2.3', check=False), failure)

    @staticmethod
    def workflow_jobs(filename):
        text = (SCRIPTS.parent/'.github/workflows'/filename).read_text()
        jobs = text.split('\njobs:\n', 1)[1]
        sections = re.split(r'^  ([a-z][a-z0-9-]*):\n', jobs, flags=re.MULTILINE)
        return text, dict(zip(sections[1::2], sections[2::2]))

    def test_linux_jobs_use_hosted_ubuntu(self):
        release, jobs = self.workflow_jobs('release.yml')
        pages, site = self.workflow_jobs('update-pages.yml')
        for name, job in [('metadata', jobs['metadata']), ('release', jobs['release']), ('pages', site['deploy'])]:
            with self.subTest(job=name):
                self.assertIn('runs-on: ubuntu-24.04', job)
                self.assertNotIn('container:', job)
                self.assertIn('persist-credentials: false', job)
                for secret in ['OSHELL_CODESIGN_P12', 'OSHELL_CODESIGN_PASSWORD']:
                    self.assertNotIn(secret, job)
                if name != 'release': self.assertNotIn('OSHELL_UPDATE_SIGNING_KEY', job)
        for workflow in [release, pages]:
            self.assertNotIn('self-hosted', workflow)
            self.assertIn('defaults:\n  run:\n    shell: bash', workflow)

    def test_tag_dispatch_uses_default_branch_and_no_publication_job(self):
        _, jobs = self.workflow_jobs('release.yml')
        dispatch = jobs['dispatch']
        self.assertIn("github.event_name == 'push'", dispatch)
        self.assertIn('actions: write', dispatch)
        self.assertIn('--ref "$DEFAULT_BRANCH"', dispatch)
        self.assertNotIn('OSHELL_UPDATE_SIGNING_KEY', dispatch)
        self.assertNotIn('ci-release.py publish', dispatch)
        self.assertIn("github.event_name == 'workflow_dispatch'", jobs['metadata'])
        self.assertIn('git merge-base --is-ancestor', jobs['metadata'])
        self.assertIn('git checkout --detach "refs/tags/$RELEASE_TAG"', jobs['metadata'])

    def test_post_migration_metadata_can_read_frozen_release(self):
        _, jobs = self.workflow_jobs('release.yml')
        steps = re.split(r'^      - ', jobs['release'], flags=re.MULTILINE)
        migration = [step for step in steps if 'scripts/publish-legacy-updates.py' in step]
        self.assertEqual(len(migration), 1)
        # Later versions must fetch the immutable 0.4.1 handoff using gh in CI.
        self.assertIn('GH_TOKEN: ${{ github.token }}', migration[0])

    def test_pages_runs_after_successful_release_when_bridge_is_skipped(self):
        _, jobs = self.workflow_jobs('release.yml')
        self.assertIn("if: always() && needs.metadata.outputs.publish == 'true' && needs.release.result == 'success'", jobs['update-pages'])

    def test_signing_dependencies_cached_and_tested_without_release_secrets(self):
        _, jobs = self.workflow_jobs('release.yml')
        build = jobs['build']
        prepare = build.split('      - name: Set up cached Python signing dependencies')[1].split('      - name: Sign verified DMG update metadata')[0]
        self.assertIn('actions/setup-python@', prepare)
        self.assertIn("python-version: '3.12'", prepare)
        self.assertIn('cache: pip', prepare)
        self.assertIn('scripts/requirements-release.txt', prepare)
        self.assertIn('scripts/test-update-pages.py', prepare)
        self.assertNotIn('OSHELL_UPDATE_SIGNING_KEY', prepare)
        self.assertNotIn('if:', prepare)

    def test_compatibility_secrets_are_scoped_before_publication(self):
        _, jobs = self.workflow_jobs('release.yml')
        release = jobs['release']
        before, signing = release.split('      - name: Prepare signed original-repository Pages metadata (two DMGs)', 1)
        self.assertNotIn('scripts/ci-release.py publish', before)
        self.assertIn('scripts/ci-release.py publish', signing)
        self.assertIn('--release-output dist/github-release', signing)
        self.assertNotIn('OSHELL_UPDATE_SIGNING_KEY', before.split('      - name: Attach the verified one-time migration')[0])
        self.assertIn("if: github.repository == 'oshell-desktop/oshell'", signing)
        signing, deploy = signing.split("      - name: Update the original repository's Pages entry", 1)
        self.assertIn('OSHELL_UPDATE_SIGNING_KEY:', signing)
        self.assertNotIn('OSHELL_LEGACY_PAGES_DEPLOY_KEY', signing)
        self.assertIn('OSHELL_LEGACY_PAGES_DEPLOY_KEY:', deploy)
        self.assertNotIn('OSHELL_UPDATE_SIGNING_KEY', deploy)

    def test_hosted_macos_builds_are_parallel_and_cached(self):
        _, jobs = self.workflow_jobs('release.yml')
        build = jobs['build']
        self.assertIn('runs-on: ${{ matrix.runner }}', build)
        self.assertIn('max-parallel: 2', build)
        self.assertNotIn('container:', build)
        entries = re.findall(r'- flavor: (\w+)\n\s+runner: ([\w-]+)', build)
        self.assertEqual(entries, [('amd64','macos-15-intel'),('arm64','macos-15')])
        self.assertIn('/Applications/Xcode_16.4.app/Contents/Developer', build)
        self.assertIn('actions/cache/restore@', build)
        self.assertIn('actions/cache/save@', build)
        self.assertLess(build.index('Verify DMG payload'), build.index('Save verified compilation cache'))
        self.assertIn('scripts/package-release.py --flavor "$FLAVOR" --format dmg --test-core', build)
        self.assertIn('scripts/verify-installers.py --flavor "$FLAVOR" --format dmg', build)

    def test_runner_migration_keeps_release_order_and_permissions(self):
        release, jobs = self.workflow_jobs('release.yml')
        pages, site = self.workflow_jobs('update-pages.yml')
        self.assertIn('needs: metadata', jobs['build'])
        self.assertIn('needs: [metadata, build, bridge]', jobs['release'])
        self.assertIn('needs: [metadata, release]', jobs['update-pages'])
        self.assertIn('uses: ./.github/workflows/update-pages.yml', jobs['update-pages'])
        self.assertIn('contents: write', jobs['metadata']); self.assertIn('contents: write', jobs['release'])
        self.assertIn('pages: write', pages); self.assertIn('id-token: write', pages)
        self.assertIn('workflow_dispatch:', release); self.assertIn('workflow_call:', pages)
        for workflow in [release, pages]:
            self.assertNotIn('pull_request:', workflow)
            self.assertNotIn('pull_request_target:', workflow)
            self.assertNotIn('--privileged', workflow)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='oshell-ci-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root/'CHANGELOG.md').write_text('# 变更日志\n\n## 1.2.3\n\n- 修复分屏独立关闭。\n\n## 1.2.2\n\n- 旧版本记录。\n', encoding='utf-8')
        root_patch = patch.object(CI, 'ROOT', self.root); root_patch.start(); self.addCleanup(root_patch.stop)
        self.incoming = self.root/'incoming'; self.incoming.mkdir()
        self.source = self.root/'OShell-1.2.3-source.tar.gz'; self.source.write_bytes(b'audited source fixture')
        self.output = self.root/'release'
        for flavor in RELEASE_FLAVORS:
            target = TARGETS[flavor]; folder = self.incoming/('dmg-' + flavor); folder.mkdir()
            name = CI.artifact_name(META['version'], flavor); dmg = folder/name; dmg.write_bytes(('fixture ' + flavor).encode())
            verification = dict(passed=True, version=META['version'], build=META['build'], dmg=name, dmgSHA256=CI.sha256(dmg), minimumOS=target.minimum, architectures=sorted(target.architectures), signaturesVerified=True, allMachOMinimumsVerified=True, payloadMatchesStagedApp=True)
            record = dict(META, flavor=flavor, file=name, sha256=CI.sha256(dmg), size=dmg.stat().st_size, verification=verification)
            (folder/'manifest.json').write_text(json.dumps(record))

    def collect(self):
        return CI.collect(META, self.incoming, self.source, self.output)

    def mutate(self, flavor, change):
        path = self.incoming/('dmg-' + flavor)/'manifest.json'; value = json.loads(path.read_text()); change(value); path.write_text(json.dumps(value))

    def test_two_distinct_target_names(self):
        self.assertEqual(len({CI.artifact_name('1.2.3', flavor) for flavor in RELEASE_FLAVORS}), 2)
        self.assertEqual(TARGETS['amd64'].architectures, ('x86_64',))
        self.assertEqual(set(TARGETS), {'arm64', 'amd64'})
        self.assertTrue(all(target.minimum == '15.0' for target in TARGETS.values()))

    def test_stable_tag_must_match_version(self):
        CI.validate_tag('v1.2.3', '1.2.3')
        for tag in ['main', 'v1.2.4', 'v1.2.3-beta', 'v1.2.3\n', '../v1.2.3', 'v$(command)']:
            with self.assertRaises(ValueError): CI.validate_tag(tag, '1.2.3')

    def source_repository(self):
        repo = self.root/'repo'; repo.mkdir(); (repo/'scripts').mkdir()
        (repo/'scripts/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='1.2.3', CFBundleVersion='45')))
        def git(*args):
            return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL, text=True).strip()
        git('init'); git('config', 'user.name', 'Release Test'); git('config', 'user.email', 'release@example.test')
        git('add', '.'); git('commit', '-m', 'Release fixture')
        return repo, git

    def test_build_only_accepts_untagged_source_without_mutation(self):
        repo, git = self.source_repository(); before = git('rev-parse', 'HEAD')
        with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh') as network:
            result = CI.metadata('', commit=before, build_only=True)
            network.assert_not_called()
        self.assertEqual(result['tag'], 'v1.2.3')
        self.assertEqual(result['commit'], before)
        self.assertEqual(git('tag'), '')

    def test_build_only_can_validate_fix_without_moving_existing_tag(self):
        repo, git = self.source_repository(); original = git('rev-parse','HEAD')
        git('tag','v1.2.3'); git('commit','--allow-empty','-m','Fix build tooling'); head = git('rev-parse','HEAD')
        with patch.object(CI,'ROOT',repo), patch.object(CI,'gh') as network:
            result = CI.metadata('',commit=head,build_only=True)
            self.assertEqual(result['commit'],head)
            self.assertEqual(git('rev-parse','refs/tags/v1.2.3'),original)
            with self.assertRaises(ValueError): CI.metadata('v1.2.3')
            with self.assertRaises(ValueError): CI.metadata('',allow_missing_tag=True)
            with self.assertRaises(ValueError): CI.metadata('',commit=original,build_only=True)
            network.assert_not_called()

    def test_manual_first_release_infers_version_and_creates_tag(self):
        repo, git = self.source_repository(); head = git('rev-parse', 'HEAD'); calls = []
        def network(*args, check=True):
            calls.append(args)
            if len(calls) == 1: return subprocess.CompletedProcess(args, 1, '', 'HTTP 404')
            return subprocess.CompletedProcess(args, 0, json.dumps({'object': {'type': 'commit', 'sha': head}}), '')
        with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh', network):
            result = CI.prepare('', 'owner/repo')
        self.assertEqual(result['tag'], 'v1.2.3')
        self.assertEqual(git('rev-parse', 'refs/tags/v1.2.3'), head)
        self.assertIn('ref=refs/tags/v1.2.3', calls[1])
        self.assertIn('sha=' + head, calls[1])

    def test_manual_wrong_version_fails_before_network(self):
        repo, git = self.source_repository()
        with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh') as network:
            with self.assertRaisesRegex(ValueError, 'v1.2.3'):
                CI.prepare('v1.2.2', 'owner/repo')
            network.assert_not_called()
        self.assertEqual(git('tag'), '')

    def test_missing_tag_in_push_mode_has_actionable_error(self):
        repo, _ = self.source_repository()
        with patch.object(CI, 'ROOT', repo), self.assertRaisesRegex(ValueError, 'manually'):
            CI.metadata('v1.2.3')

    def test_manual_existing_tag_cannot_move(self):
        repo, git = self.source_repository(); git('tag', 'v1.2.3')
        git('commit', '--allow-empty', '-m', 'Later source')
        with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh') as network:
            with self.assertRaisesRegex(ValueError, 'never moved'):
                CI.prepare('', 'owner/repo')
            network.assert_not_called()

    def test_manual_existing_annotated_tag_is_reused(self):
        repo, git = self.source_repository(); head = git('rev-parse', 'HEAD')
        git('tag', '-a', 'v1.2.3', '-m', 'Release'); calls = []
        def network(*args, check=True):
            calls.append(args)
            ref = dict(type='commit', sha=head) if '/git/tags/' in args[1] else dict(type='tag', sha=git('rev-parse', 'v1.2.3'))
            return subprocess.CompletedProcess(args, 0, json.dumps(dict(object=ref)), '')
        with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh', network):
            self.assertEqual(CI.prepare('v1.2.3', 'owner/repo')['commit'], head)
        self.assertTrue(all('--method' not in call for call in calls))

    def test_manual_remote_tag_moved_or_api_denied_never_retargeted(self):
        repo, git = self.source_repository()
        for status, payload, error in [(0, json.dumps({'object': {'type': 'commit', 'sha': 'b' * 40}}), ''), (1, '', 'HTTP 403')]:
            with self.subTest(status=status), patch.object(CI, 'ROOT', repo):
                with patch.object(CI, 'gh', return_value=subprocess.CompletedProcess([], status, payload, error)) as network:
                    with self.assertRaises((ValueError, RuntimeError)): CI.prepare('', 'owner/repo')
                    self.assertTrue(all('--method' not in call.args for call in network.call_args_list))
            self.assertEqual(git('tag'), '')

    def test_manual_tag_creation_race_rechecks_remote_commit(self):
        for matching in [True, False]:
            with self.subTest(matching=matching):
                repo, git = self.source_repository(); head = git('rev-parse', 'HEAD')
                results = [subprocess.CompletedProcess([], 1, '', 'HTTP 404'),
                           subprocess.CompletedProcess([], 1, '', 'HTTP 422'),
                           subprocess.CompletedProcess([], 0, json.dumps({'object': {'type': 'commit', 'sha': head if matching else 'b' * 40}}), '')]
                with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh', side_effect=results):
                    if matching: self.assertEqual(CI.prepare('', 'owner/repo')['commit'], head)
                    else:
                        with self.assertRaises(ValueError): CI.prepare('', 'owner/repo')
                        self.assertEqual(git('tag'), '')
                import shutil
                shutil.rmtree(repo)

    def test_collect_complete_set_and_checksums(self):
        result = self.collect()
        self.assertEqual(len(result['installers']), 2)
        self.assertEqual(len(list(self.output.glob('*.dmg'))), 2)
        self.assertFalse(result['notarized'])
        for line in (self.output/'SHA256SUMS.txt').read_text().splitlines():
            expected, name = line.split('  ', 1); self.assertEqual(CI.sha256(self.output/name), expected)
        self.assertIn('ad-hoc', (self.output/'RELEASE_NOTES.md').read_text())

    def test_fixed_signing_release_metadata(self):
        import code_signing
        pin = code_signing.profile()['sha256']
        for flavor in RELEASE_FLAVORS:
            self.mutate(flavor, lambda r: r['verification'].update(signing='self-signed', codeSigningCertificateSHA256=pin))
        record = self.collect()
        self.assertEqual(record['signing'], 'self-signed')
        self.assertEqual(record['codeSigningCertificateSHA256'], pin)
        self.assertIn('固定自签名证书', (self.output/'RELEASE_NOTES.md').read_text())

    def test_mixed_signing_identities_rejected(self):
        self.mutate('arm64', lambda r: r['verification'].update(signing='self-signed', codeSigningCertificateSHA256='a'*64))
        with self.assertRaisesRegex(ValueError, 'different signing'): self.collect()

    def test_wrong_pinned_certificate_rejected(self):
        for flavor in RELEASE_FLAVORS:
            self.mutate(flavor, lambda r: r['verification'].update(signing='self-signed', codeSigningCertificateSHA256='a'*64))
        with self.assertRaisesRegex(ValueError, 'pinned identity'): self.collect()

    def test_official_release_cannot_fall_back_to_adhoc(self):
        with patch.dict(os.environ, {'OSHELL_REQUIRE_FIXED_SIGNING':'1'}):
            with self.assertRaisesRegex(ValueError, 'requires fixed signing'): self.collect()

    def test_release_notes_include_only_matching_version_changes(self):
        self.collect()
        notes = (self.output/'RELEASE_NOTES.md').read_text()
        self.assertIn('## 本次变更\n\n- 修复分屏独立关闭。', notes)
        self.assertNotIn('旧版本记录', notes)
        self.assertLess(notes.index('## 本次变更'), notes.index('## 安装包'))

    def test_missing_changelog_prevents_collection(self):
        (self.root/'CHANGELOG.md').unlink()
        with self.assertRaisesRegex(ValueError, 'CHANGELOG.md'): self.collect()
        self.assertFalse(self.output.exists())

    def test_missing_empty_or_duplicate_version_notes_rejected(self):
        for content in ['## 1.2.2\n- older\n', '## 1.2.3\n\n## 1.2.2\n- older\n', '## 1.2.3\n- first\n## 1.2.3\n- second\n']:
            with self.subTest(content=content):
                (self.root/'CHANGELOG.md').write_text(content)
                with self.assertRaisesRegex(ValueError, 'non-empty section'): self.collect()
                self.assertFalse(self.output.exists())

    def test_missing_build_prevents_release(self):
        import shutil
        shutil.rmtree(self.incoming/'dmg-amd64')
        with self.assertRaises(ValueError): self.collect()
        self.assertFalse(self.output.exists())

    def test_wrong_source_commit_rejected(self):
        self.mutate('arm64', lambda record: record.update(commit='b' * 40))
        with self.assertRaises(ValueError): self.collect()

    def test_wrong_architecture_rejected(self):
        self.mutate('amd64', lambda record: record['verification'].update(architectures=['arm64']))
        with self.assertRaises(ValueError): self.collect()

    def test_wrong_minimum_rejected(self):
        self.mutate('amd64', lambda record: record['verification'].update(minimumOS='13.0'))
        with self.assertRaises(ValueError): self.collect()

    def test_unverified_payload_rejected(self):
        self.mutate('amd64', lambda record: record['verification'].update(payloadMatchesStagedApp=False))
        with self.assertRaises(ValueError): self.collect()

    def test_modified_dmg_rejected(self):
        next((self.incoming/'dmg-amd64').glob('*.dmg')).write_bytes(b'tampered fixture')
        with self.assertRaises(ValueError): self.collect()

    def test_unexpected_files_rejected(self):
        (self.incoming/'dmg-arm64/unexpected.txt').write_text('not a release asset')
        with self.assertRaises(ValueError): self.collect()

    def test_stage_requires_verified_dmg(self):
        flavor = 'arm64'
        record = json.loads((self.incoming/'dmg-arm64/manifest.json').read_text())
        (self.root/'dist/installers').mkdir(parents=True)
        (self.root/'validation').mkdir()
        import shutil
        shutil.copy2(self.incoming/'dmg-arm64'/record['file'], self.root/'dist/installers'/record['file'])
        report = self.root/'validation/package-installers-verification.json'
        report.write_text(json.dumps(dict(passed=True, packages=[record['verification']])))
        # A report must explicitly identify its flavor, not just pass globally.
        with patch.object(CI, 'ROOT', self.root), self.assertRaises(ValueError):
            CI.stage(META, flavor, self.root/'staged')
        record['verification']['flavor'] = flavor
        report.write_text(json.dumps(dict(passed=True, packages=[record['verification']])))
        with patch.object(CI, 'ROOT', self.root): CI.stage(META, flavor, self.root/'staged')
        staged = json.loads((self.root/'staged/manifest.json').read_text())
        self.assertEqual(staged['commit'], META['commit'])
        self.assertEqual(staged['sha256'], record['sha256'])

    def update_artifacts(self):
        import xml.etree.ElementTree as ET
        root = self.root/'updates'; root.mkdir()
        namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
        for flavor in RELEASE_FLAVORS:
            folder = root/('updates-' + flavor); folder.mkdir(); target = TARGETS[flavor]
            record = json.loads((self.incoming/('dmg-' + flavor)/'manifest.json').read_text())
            rss = ET.Element('rss'); channel = ET.SubElement(rss, 'channel'); item = ET.SubElement(channel, 'item')
            for key, value in [('version', META['build']), ('shortVersionString', META['version']), ('minimumSystemVersion', target.minimum)]: ET.SubElement(item, namespace+key).text = value
            ET.SubElement(item, 'enclosure', {'url': f"https://github.com/owner/repo/releases/download/{META['tag']}/{record['file']}", 'length': str(record['size']), namespace+'edSignature': base64.b64encode(b'x'*64).decode()})
            (folder/(flavor+'.json')).write_text(json.dumps(dict(format='OShell.release-update.v1',version=META['version'],build=META['build'],tag=META['tag'],repository='owner/repo',flavor=flavor,file=record['file'],size=record['size'],sha256=record['sha256'],signedFeed=base64.b64encode(ET.tostring(rss)).decode())))
        return root

    def test_signed_update_metadata_embedded_without_extra_assets(self):
        updates = self.update_artifacts()
        result = CI.collect(META, self.incoming, self.source, self.output, updates, 'owner/repo')
        self.assertEqual(result['updateMetadata'], 'embedded-in-release-notes-v1')
        notes = (self.output/'RELEASE_NOTES.md').read_text()
        for flavor in RELEASE_FLAVORS: self.assertIn('<!-- oshell-update-v1:'+TARGETS[flavor].suffix+':', notes)
        calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls)): CI.publish(META, 'owner/repo', self.output)
        upload = next(call for call in calls if call[:2] == ('release', 'upload'))
        self.assertFalse(any(path.endswith(('.xml','-update.zip','.json','.txt')) for path in upload))
        self.assertEqual(len(list(self.output.glob('*.dmg'))),2)

    def test_missing_update_architecture_prevents_release(self):
        import shutil
        updates = self.update_artifacts(); shutil.rmtree(updates/'updates-amd64')
        with self.assertRaises(ValueError): CI.collect(META, self.incoming, self.source, self.output, updates, 'owner/repo')
        self.assertFalse(self.output.exists())

    def test_changed_update_archive_rejected(self):
        updates = self.update_artifacts()
        path=updates/'updates-arm64/arm64.json';record=json.loads(path.read_text());record['sha256']='bad';path.write_text(json.dumps(record))
        with self.assertRaises(ValueError): CI.collect(META, self.incoming, self.source, self.output, updates, 'owner/repo')
        self.assertFalse(self.output.exists())

    def test_wrong_update_repository_rejected(self):
        updates = self.update_artifacts()
        with self.assertRaises(ValueError): CI.collect(META, self.incoming, self.source, self.output, updates, 'another/repo')

    def test_ci_signing_requires_secret(self):
        import os, sys
        env = dict(os.environ, OSHELL_UPDATE_SIGNING_KEY='')
        for flavor in CI.RELEASE_FLAVORS:
            result = subprocess.run([sys.executable, str(SCRIPTS/'sign-ci-updates.py'), '--flavor', flavor, '--tag', 'v1.2.3'], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('OSHELL_UPDATE_SIGNING_KEY', result.stderr)

    def test_empty_checksum_list_prevents_publish(self):
        self.collect(); (self.output/'SHA256SUMS.txt').write_text('')
        with patch.object(CI, 'gh') as network, self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)
        network.assert_not_called()

    def fake_gh(self, calls, existing=None, fail_upload=False, incomplete=False, moved=False):
        def invoke(*args, check=True):
            calls.append(args)
            output, error, status = '', '', 0
            if args[0] == 'api':
                output = json.dumps({'object': {'type': 'commit', 'sha': 'b' * 40 if moved else META['commit']}})
            elif args[:2] == ('release', 'view'):
                if args[-1] == 'isDraft,body':
                    if existing is None: status, error = 1, 'release not found'
                    else: output = json.dumps(existing)
                elif args[-1] == 'assets,body':
                    assets = [dict(name=path.name, size=path.stat().st_size) for path in self.output.iterdir() if path.name not in {'RELEASE_NOTES.md', 'release-manifest.json', 'SHA256SUMS.txt'}]
                    output = json.dumps({'assets': assets[:-1] if incomplete else assets, 'body': (self.output/'RELEASE_NOTES.md').read_text()})
            elif args[:2] == ('release', 'upload') and fail_upload:
                raise subprocess.CalledProcessError(1, ['gh', *args])
            return subprocess.CompletedProcess(['gh', *args], status, output, error)
        return invoke

    def test_publication_is_draft_upload_verify_publish(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls)):
            CI.publish(META, 'owner/repo', self.output)
        steps = [call[:2] for call in calls]
        self.assertLess(steps.index(('release', 'create')), steps.index(('release', 'upload')))
        self.assertEqual(steps[-1], ('release', 'edit'))
        self.assertIn('--draft', next(call for call in calls if call[:2] == ('release', 'create')))
        self.assertIn('--draft=false', calls[-1])
        upload = next(call for call in calls if call[:2] == ('release', 'upload'))
        self.assertNotIn(str(self.output/'SHA256SUMS.txt'), upload)
        self.assertNotIn(str(self.output/'release-manifest.json'), upload)
        self.assertEqual({Path(arg).name for arg in upload if arg.endswith('.dmg')}, {CI.artifact_name(META['version'], f) for f in RELEASE_FLAVORS})

    def test_upload_failure_leaves_draft(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls, fail_upload=True)), self.assertRaises(subprocess.CalledProcessError):
            CI.publish(META, 'owner/repo', self.output)
        self.assertFalse(any('--draft=false' in call for call in calls))

    def test_incomplete_remote_assets_never_published(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls, incomplete=True)), self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)
        self.assertFalse(any('--draft=false' in call for call in calls))

    def add_compatibility_alias(self):
        source = CI.artifact_name(META['version'], 'amd64')
        name = f"OShell-{META['version']}-macOS13-x86_64.dmg"
        (self.output/name).write_bytes((self.output/source).read_bytes())
        path = self.output/'release-manifest.json'; manifest = json.loads(path.read_text())
        manifest['compatibilityAliases'] = [dict(file=name,source=source,sha256=CI.sha256(self.output/source),size=(self.output/source).stat().st_size)]
        path.write_text(json.dumps(manifest))
        files = sorted(p for p in self.output.iterdir() if p.name not in ('SHA256SUMS.txt','RELEASE_NOTES.md'))
        (self.output/'SHA256SUMS.txt').write_text(''.join(CI.sha256(p)+'  '+p.name+'\n' for p in files))
        return self.output/name

    def test_compatibility_alias_rejected_even_with_matching_bytes(self):
        self.collect(); self.add_compatibility_alias()
        with patch.object(CI,'gh') as network, self.assertRaisesRegex(ValueError, 'aliases'):
            CI.publish(META,'owner/repo',self.output)
        network.assert_not_called()

    def test_undeclared_extra_dmg_rejected_before_any_github_call(self):
        self.collect()
        (self.output/'OShell-1.2.3-macOS13-x86_64.dmg').write_bytes(b'extra installer')
        with patch.object(CI,'gh') as network, self.assertRaisesRegex(ValueError, 'asset set'):
            CI.publish(META,'owner/repo',self.output)
        network.assert_not_called()

    def test_retired_feed_rejected_even_without_alias_file(self):
        self.collect()
        with (self.output/'RELEASE_NOTES.md').open('a') as stream:
            stream.write('\n<!-- oshell-update-v1:macOS13-x86_64:c3ludGhldGlj -->\n')
        with patch.object(CI,'gh') as network, self.assertRaisesRegex(ValueError, 'platforms'):
            CI.publish(META,'owner/repo',self.output)
        network.assert_not_called()

    def test_published_release_is_immutable(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls, existing=dict(isDraft=False, body=''))), self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)
        self.assertFalse(any(call[:2] == ('release', 'upload') for call in calls))

    def test_retry_only_resumes_own_draft(self):
        self.collect(); calls = []
        owned = dict(isDraft=True, body='<!-- oshell-release:' + META['commit'] + ' -->')
        with patch.object(CI, 'gh', self.fake_gh(calls, existing=owned)):
            CI.publish(META, 'owner/repo', self.output)
        self.assertFalse(any(call[:2] == ('release', 'create') for call in calls))
        with patch.object(CI, 'gh', self.fake_gh([], existing=dict(isDraft=True, body='manual draft'))), self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)

    def test_moved_tag_prevents_any_release_write(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls, moved=True)), self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)
        self.assertEqual(len(calls), 1)

    def installer_fixture(self):
        root = self.root/'image'; contents = root/'OShell.app/Contents'; contents.mkdir(parents=True)
        (contents/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='1.2.3', CFBundleVersion='45', LSMinimumSystemVersion='15.0')))
        (contents/'binary').write_bytes(b'unchanged signed payload fixture')
        (contents/'alias').symlink_to('binary'); (root/'Applications').symlink_to('/Applications')
        (root/'安装说明.txt').write_text('安装说明')
        options = dict(version='1.2.3',build='45',flavor='arm64',minimum='15.0',architectures=['arm64'])
        installer_metadata.write(root, **options, source_root=self.root)
        return root, options

    def test_installer_metadata_records_fixed_certificate(self):
        import code_signing
        root, options = self.installer_fixture()
        path = root/'OShell.app/Contents/Info.plist'; info = plistlib.loads(path.read_bytes())
        info[code_signing.MARKER] = code_signing.profile()['sha256']; path.write_bytes(plistlib.dumps(info))
        installer_metadata.write(root, **options, source_root=self.root)
        record = installer_metadata.verify(root, **options)
        self.assertEqual(record['signing'], 'self-signed')
        self.assertEqual(record['codeSigningCertificateSHA256'], info[code_signing.MARKER])

    def test_installer_metadata_rejects_false_signing_claim(self):
        root, options = self.installer_fixture(); path = root/'release-manifest.json'
        record = json.loads(path.read_text()); record['signing'] = 'self-signed'; path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'signing metadata'): installer_metadata.verify(root, **options)

    def test_installer_metadata_covers_payload_without_changing_it(self):
        root, options = self.installer_fixture()
        record = installer_metadata.verify(root, **options)
        self.assertEqual((root/'OShell.app/Contents/binary').read_bytes(), b'unchanged signed payload fixture')
        self.assertIsNone(record['commit'])
        names = {line.split('  ',1)[1] for line in (root/'SHA256SUMS.txt').read_text().splitlines()}
        self.assertIn('release-manifest.json', names)
        self.assertIn('OShell.app/Contents/binary', names)
        self.assertNotIn('SHA256SUMS.txt', names)
        self.assertEqual(record['symlinks']['Applications'], '/Applications')

    def test_installer_metadata_detects_modified_payload(self):
        root, options = self.installer_fixture()
        (root/'OShell.app/Contents/binary').write_bytes(b'tampered')
        with self.assertRaises(ValueError): installer_metadata.verify(root, **options)

    def test_installer_metadata_detects_missing_checksums_and_changed_links(self):
        root, options = self.installer_fixture()
        sums = (root/'SHA256SUMS.txt').read_text(); (root/'SHA256SUMS.txt').write_text('')
        with self.assertRaises(ValueError): installer_metadata.verify(root, **options)
        (root/'SHA256SUMS.txt').write_text(sums)
        alias = root/'OShell.app/Contents/alias'; alias.unlink(); alias.symlink_to('Info.plist')
        with self.assertRaises(ValueError): installer_metadata.verify(root, **options)

    def test_installer_metadata_rejects_wrong_version_or_extra_files(self):
        root, options = self.installer_fixture()
        with self.assertRaises(ValueError): installer_metadata.write(root, **dict(options, version='9.9.9'), source_root=self.root)
        (root/'OShell.app/Contents/unexpected').write_text('extra')
        with self.assertRaises(ValueError): installer_metadata.verify(root, **options)

    def test_developer_app_cannot_be_packaged(self):
        app = self.root/'developer.app'; (app/'Contents').mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'OShellTestHarness': True}))
        with self.assertRaisesRegex(ValueError, 'cannot be packaged'):
            PACK.package('arm64', ['arm64'], '15.0', app, 'dmg')

    def test_dmg_only_skips_pkg_tools(self):
        root = self.root/'package'; root.mkdir(); (root/'LICENSE').write_text('license fixture')
        app = root/'app/OShell.app'; resources = app/'Contents/Resources'; resources.mkdir(parents=True)
        (resources/'OShell-LICENSE.txt').write_text('license fixture')
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString=PACK.VERSION, CFBundleVersion=PACK.INFO['CFBundleVersion'], LSMinimumSystemVersion='15.0')))
        work, out = root/'work', root/'out'; (work/'arm64').mkdir(parents=True); out.mkdir()
        calls = []
        def fake_run(args, **kwargs):
            calls.append(args)
            if args[:2] == ['hdiutil', 'create']: Path(args[-1]).write_bytes(b'fake DMG')
        with patch.multiple(PACK, ROOT=root, WORK=work, OUT=out), patch.object(PACK, 'run', fake_run):
            artifacts = PACK.package('arm64', ['arm64'], '15.0', app, 'dmg')
        self.assertEqual([path.suffix for path in artifacts], ['.dmg'])
        self.assertFalse(any(call[0] in ['pkgbuild', 'productbuild'] for call in calls))
        self.assertTrue(any(call[:2] == ['hdiutil', 'verify'] for call in calls))
        self.assertTrue((work/'arm64/image/SHA256SUMS.txt').is_file())
        self.assertTrue((work/'arm64/image/release-manifest.json').is_file())

if __name__ == '__main__':
    unittest.main()
