#!/usr/bin/env bash
set -euo pipefail

sdk_version="$(dotnet --version)"
printf 'SDK_VERSION=%s\n' "$sdk_version"
case "$sdk_version" in
  10.*|11.*) printf 'LAB_SMOKE_PASS\n' ;;
  *) printf 'Unexpected SDK version\n' >&2; exit 1 ;;
esac
