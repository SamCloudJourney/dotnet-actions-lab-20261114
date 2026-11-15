#!/usr/bin/env bash
set -euo pipefail

sdk_version="$(dotnet --version)"
printf 'SDK_VERSION=%s\n' "$sdk_version"
case "$sdk_version" in
  10.*|11.*) printf 'LAB_SMOKE_PASS\n' ;;
  *) printf 'Unexpected SDK version\n' >&2; exit 1 ;;
esac

if [[ "$sdk_version" == 11.* ]]; then
  printf 'PUBLIC_OUTPUT_CACHE_REGRESSION_START\n'
  dotnet run --project tests/PublicCacheRegression/PublicCacheRegression.csproj --configuration Release --framework net11.0
  printf 'PUBLIC_OUTPUT_CACHE_REGRESSION_COMPLETE\n'
else
  printf 'PUBLIC_OUTPUT_CACHE_REGRESSION_SKIPPED_REQUIRES_NET11\n'
fi
