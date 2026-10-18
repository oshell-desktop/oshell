# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""One catalog for package construction, verification and CI publication."""
from dataclasses import dataclass

@dataclass(frozen=True)
class ReleaseTarget:
    architectures: tuple[str, ...]
    minimum: str
    suffix: str

TARGETS = {
    'legacy': ReleaseTarget(('x86_64',), '10.13', 'macOS10.13-Intel'),
    'compat': ReleaseTarget(('arm64', 'x86_64'), '11.0', 'macOS11-Universal'),
    'arm64': ReleaseTarget(('arm64',), '13.0', 'macOS13-arm64'),
    'intel': ReleaseTarget(('x86_64',), '13.0', 'macOS13-x86_64'),
    # Retain the existing optional modern Universal command for local builds.
    'modern': ReleaseTarget(('arm64', 'x86_64'), '13.0', 'macOS13-Universal'),
}
# Historical targets remain available for explicit local diagnostics only.
RELEASE_FLAVORS = ('legacy', 'arm64')
