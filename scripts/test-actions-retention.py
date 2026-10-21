#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic retention/API-scope regression; never deletes real workflow runs."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('retention', Path(__file__).with_name('prune-actions-runs.py'))
R = importlib.util.module_from_spec(spec); spec.loader.exec_module(R)


def run(i, workflow=1, event='workflow_dispatch', status='completed', conclusion='success'):
    return dict(id=i, workflow_id=workflow, name='fixture', event=event, status=status, conclusion=conclusion,
                path='.github/workflows/release.yml', created_at=f'2026-10-{i:02}T00:00:00Z',
                updated_at='2026-10-21T01:00:00Z', run_attempt=1, head_sha='a'*40)


class RetentionTests(unittest.TestCase):
    def test_latest_fifteen_includes_failures_and_preserves_active(self):
        values=[run(i, conclusion='failure' if i%2 else 'success') for i in range(1,21)]
        values += [run(21,status='in_progress'),run(22,status='queued'),run(23,status='waiting')]
        report, selected=R.plan(values,lambda _: [])
        self.assertEqual({r['id'] for r in selected},set(range(1,6)))
        self.assertEqual(report['protected'],[21,22,23])
        self.assertEqual(len(report['groups'][0]['keep']),15)

    def test_each_workflow_has_its_own_limit(self):
        values=[run(i,workflow=1 if i<18 else 2) for i in range(1,24)]
        report, selected=R.plan(values,lambda _: [])
        self.assertEqual([r['id'] for r in selected],[2,1])
        self.assertEqual(len(report['groups'][1]['keep']),6)

    def test_legacy_tag_builds_are_not_forwarders(self):
        values=[run(i,event='push') for i in range(1,21)]
        report, selected=R.plan(values,lambda _: [{'name':'DMG / legacy','conclusion':'success'}])
        self.assertEqual(report['groups'][0]['category'],'workflow-runs')
        self.assertEqual(len(selected),5)

    def test_successful_relays_do_not_consume_build_slots(self):
        values=[run(i) for i in range(1,18)]+[run(i,event='push') for i in range(18,23)]
        def jobs(_):return [{'name':'dispatch','conclusion':'success'},{'name':'DMG / legacy','conclusion':'skipped'}]
        report, selected=R.plan(values,jobs)
        self.assertEqual({r['id'] for r in selected},{1,2,18,19,20,21})
        self.assertEqual(next(g['keep'] for g in report['groups'] if g['category']=='tag-relay-success'),[22])

    def test_failed_relays_kept_separately(self):
        report, selected=R.plan([run(i,event='push',conclusion='failure') for i in range(1,18)],lambda _: [{'name':'dispatch','conclusion':'failure'}])
        self.assertEqual(report['groups'][0]['category'],'tag-relay-failed')
        self.assertEqual({r['id'] for r in selected},{1,2})

    def test_real_build_wins_over_dispatch_job(self):
        self.assertEqual(R.category(run(1,event='push'),lambda _: [{'name':'dispatch','conclusion':'success'},{'name':'DMG / arm64','conclusion':'failure'}]),'workflow-runs')

    def test_current_cleanup_run_is_protected(self):
        report, selected=R.plan([run(i) for i in range(1,21)],lambda _: [],current_run=1)
        self.assertIn(1,report['protected']);self.assertNotIn(1,[r['id'] for r in selected])

    def test_rechecks_status_and_attempt_before_deletion(self):
        class API:
            deleted=[]
            def run(self,i):
                value=run(i)
                if i==1:value['status']='in_progress'
                if i==2:value['run_attempt']=2
                return value
            def delete_run(self,i):self.deleted.append(i)
        api=API()
        with patch('builtins.print'): deleted,skipped=R.apply(api,[run(1),run(2),run(3)])
        self.assertEqual(deleted,[3]);self.assertEqual(skipped,[1,2]);self.assertEqual(api.deleted,[3])

    def test_delete_api_targets_only_run_endpoint(self):
        with patch.object(R.subprocess,'run') as call:
            R.GitHub('example/repo').delete_run(123)
        command=call.call_args.args[0]
        self.assertIn('DELETE',command);self.assertEqual(command[-1],'repos/example/repo/actions/runs/123')
        for invalid in ['../repo','example/..','example/repo?x=1']:
            with self.assertRaises(ValueError):R.GitHub(invalid)
        for invalid in ['123/../../caches',0,True]:
            with self.assertRaises(ValueError):R.GitHub('example/repo').delete_run(invalid)

    def test_missing_metadata_and_job_errors_fail_closed(self):
        value=run(1);value.pop('created_at')
        with self.assertRaises(KeyError):R.plan([value],lambda _: [])
        def unavailable(_):raise RuntimeError('API unavailable')
        with self.assertRaises(RuntimeError):R.plan([run(1,event='push')],unavailable)

    def test_duplicate_pages_do_not_double_count(self):
        values=[run(i) for i in range(1,21)]
        _,selected=R.plan(values+values,lambda _: [])
        self.assertEqual(len(selected),5)

    def test_workflow_scheduled_manual_and_least_privilege(self):
        s=(Path(__file__).resolve().parents[1]/'.github/workflows/prune-actions.yml').read_text()
        for item in ['workflow_dispatch:',"cron: '17 20 * * *'",'actions: write','contents: read','default: false','cancel-in-progress: false','github.event.repository.default_branch','scripts/test-actions-retention.py']:
            self.assertIn(item,s)
        for item in ['contents: write','secrets.','pull_request:', 'release.yml --', 'package-release.py']:
            self.assertNotIn(item,s)


if __name__=='__main__':unittest.main()
