#!/usr/bin/env bash
set -euo pipefail

printf 'SDK_VERSION=%s\n' "$(dotnet --version)"
printf 'HOST_ARCH=%s\n' "$(uname -m)"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  printf 'This smoke test requires Linux x64\n' >&2
  exit 2
fi

source /etc/os-release
if [[ "$ID" != ubuntu ]]; then
  printf 'This smoke test requires Ubuntu\n' >&2
  exit 2
fi

package_config="$(mktemp /tmp/ms-packages.XXXXXX.deb)"
trap 'rm -f "$package_config"' EXIT
curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -o "$package_config"
sudo dpkg -i "$package_config"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libmsquic
dotnet run --project tests/quic-smoke/quic-smoke.csproj -c Release
