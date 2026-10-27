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
    'arm64': ReleaseTarget(('arm64',), '15.0', 'macOS-arm64'),
    'amd64': ReleaseTarget(('x86_64',), '15.0', 'macOS-amd64'),
}
RELEASE_FLAVORS = ('arm64', 'amd64')
