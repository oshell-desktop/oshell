#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
cd "$(dirname "$0")/../dist/fullscreen-acceptance" || exit 1
exec bash ./打开验收版.command
