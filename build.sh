#!/usr/bin/env bash
# Thin wrapper: build.sh -> driver.sh build + reload
# reload kills chronod/widgetd so desktop widgets pick up the rebuilt
# extension instead of showing a stale/blank cached instance.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
