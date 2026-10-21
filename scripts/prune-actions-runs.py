#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Retain Actions history by workflow/category. Dry-run unless --apply is explicit."""
import argparse
from collections import defaultdict
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess

KEEP = 15
RELAY_KEEP = 1


class GitHub:
    def __init__(self, repository):
        if not re.fullmatch(r'[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*/[A-Za-z0-9_.-]+', repository) or repository.split('/')[-1] in ('.', '..'):
            raise ValueError('Expected a GitHub owner/repository')
        self.base = f'repos/{repository}/actions'

    def read(self, suffix, paginated=False):
        command = ['gh', 'api', '--hostname', 'github.com']
        if paginated: command += ['--paginate', '--slurp']
        return json.loads(subprocess.check_output(command + [self.base + suffix], text=True))

    def runs(self):
        # Fetch all pages before deleting: deleting while paging shifts results.
        pages = self.read('/runs?per_page=100', paginated=True)
        return list({run['id']: run for page in pages for run in page['workflow_runs']}.values())

    def jobs(self, identifier):
        return [job for page in self.read(f'/runs/{run_id(identifier)}/jobs?per_page=100', paginated=True) for job in page['jobs']]

    def run(self, identifier):
        return self.read(f'/runs/{run_id(identifier)}')

    def delete_run(self, identifier):
        # This is the only destructive API in this tool. Never delete releases,
        # Git refs, caches, workflow definitions, or artifacts individually.
        subprocess.run(['gh', 'api', '--hostname', 'github.com', '--method', 'DELETE',
                        f'{self.base}/runs/{run_id(identifier)}'], check=True, stdout=subprocess.DEVNULL)


def run_id(value):
    if type(value) is not int or value <= 0: raise ValueError('Invalid run ID')
    return value


def identity(run):
    return tuple(run.get(key) for key in ('id', 'workflow_id', 'event', 'head_sha', 'run_attempt', 'updated_at'))


def category(run, jobs):
    # Before the forwarding workflow existed, push/tag runs built real DMGs.
    # Do not classify a run as a relay just because its event is "push".
    if run.get('path', '').split('@')[0] == '.github/workflows/release.yml' and run.get('event') == 'push':
        executed = [job for job in jobs(run_id(run['id'])) if job.get('conclusion') != 'skipped']
        if executed and all(job.get('name') == 'dispatch' for job in executed):
            return 'tag-relay-success' if run.get('conclusion') == 'success' else 'tag-relay-failed'
    return 'workflow-runs'


def plan(runs, jobs, current_run=None):
    buckets = defaultdict(list)
    protected, snapshots = [], {}
    for run in runs:
        identifier = run_id(run['id'])
        if identifier in snapshots: continue
        snapshots[identifier] = run
        if identifier == current_run or run.get('status') != 'completed':
            protected.append(identifier); continue
        # Fail before deleting anything if the API response is incomplete.
        if not isinstance(run.get('workflow_id'), int) or not run.get('conclusion'):
            raise ValueError('Incomplete workflow run metadata')
        datetime.fromisoformat(run['created_at'].replace('Z', '+00:00'))
        buckets[(run['workflow_id'], category(run, jobs))].append(run)
    groups, selected = [], []
    for (workflow, kind), values in sorted(buckets.items()):
        values.sort(key=lambda value: (datetime.fromisoformat(value['created_at'].replace('Z', '+00:00')), value['id']), reverse=True)
        limit = RELAY_KEEP if kind == 'tag-relay-success' else KEEP
        keep, remove = values[:limit], values[limit:]
        groups.append({'workflowId': workflow, 'name': values[0].get('name', str(workflow)), 'category': kind,
                       'keepLimit': limit, 'keep': [r['id'] for r in keep], 'delete': [r['id'] for r in remove]})
        selected += remove
    return {'groups': groups, 'protected': protected, 'plannedDeletes': len(selected)}, selected


def apply(api, selected, current_run=None):
    deleted, skipped = [], []
    for original in selected:
        identifier = original['id']
        fresh = api.run(identifier)
        if identifier == current_run or fresh.get('status') != 'completed' or identity(fresh) != identity(original):
            skipped.append(identifier); continue
        api.delete_run(identifier); deleted.append(identifier)
        print(f"Deleted completed workflow run {identifier}", flush=True)
    return deleted, skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    current = os.environ.get('GITHUB_RUN_ID')
    current = int(current) if current else None
    api = GitHub(args.repository)
    report, selected = plan(api.runs(), api.jobs, current)
    report.update(repository=args.repository, mode='apply' if args.apply else 'dry-run')
    # A reviewable plan is printed/saved before the first deletion.
    if args.output: args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
    if args.apply:
        report['deleted'], report['skippedAfterRecheck'] = apply(api, selected, current)
        print(json.dumps({'deleted': len(report['deleted']), 'skippedAfterRecheck': report['skippedAfterRecheck']}))
    if args.output: args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(summary, 'a') as stream:
            stream.write(f"### Actions history retention\n\nMode: {report['mode']}; planned: {len(selected)}; deleted: {len(report.get('deleted', []))}; protected active runs: {len(report['protected'])}.\n\n")
            stream.write('Keep 15 completed runs per workflow; pure successful tag relays keep 1, failed relays keep 15 separately. Releases, tags and compilation caches are not targeted.\n')


if __name__ == '__main__': main()
