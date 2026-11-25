#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf 'Usage: %s\nBuild the pinned sing-box XCFramework for iOS and iOS Simulator.\n' "$0"
    exit 0
fi
if (( $# > 0 )); then
    printf 'Unexpected arguments. See --help.\n' >&2
    exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
core_version=1.14.4
gomobile_version=v0.1.13
work="$(mktemp -d "${TMPDIR:-/tmp}/byway-core.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
export GOBIN="$root/.build/bin"
export PATH="$GOBIN:$PATH"
mkdir -p "$GOBIN"

curl --fail --silent --show-error --location --max-time 120 --retry 2 \
    "https://codeload.github.com/SagerNet/sing-box/tar.gz/refs/tags/v$core_version" -o "$work/core.tar.gz"
tar -xzf "$work/core.tar.gz" -C "$work"
cd "$work/sing-box-$core_version"
git apply "$root/Vendor/byway-tailscale.patch"
tailscale_version=$(go list -m -f '{{.Version}}' github.com/sagernet/tailscale)
tailscale_source=$(go mod download -json "github.com/sagernet/tailscale@$tailscale_version" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["Dir"])')
cp -R "$tailscale_source" "$work/tailscale"
chmod -R u+w "$work/tailscale"
(cd "$work/tailscale" && git apply "$root/Vendor/byway-tailscale-map.patch")
go mod edit -replace "github.com/sagernet/tailscale=$work/tailscale"
cp "$root/Vendor/byway_private_endpoint.go" protocol/tailscale/
cp "$root/Vendor/byway_private_endpoint_test.go" protocol/tailscale/
cp "$root/Vendor/byway_private_clash.go" experimental/clashapi/
cp "$root/Vendor/byway_private_libbox.go" experimental/libbox/
cp "$root/Vendor/byway_control.go" experimental/libbox/
cp "$root/Vendor/byway_dns.go" include/
cp "$root/Vendor/byway_dns_test.go" include/
sed -i '' '/transport.RegisterHTTPS(registry)/a\
	registerBywayDNS(registry)\
' include/registry.go
go test ./include -run '^TestBywayDNS$'
go test -tags with_gvisor,with_tailscale ./protocol/tailscale -run '^TestBywayRelayPolicy'
go install "github.com/sagernet/gomobile/cmd/gomobile@$gomobile_version" "github.com/sagernet/gomobile/cmd/gobind@$gomobile_version"
gomobile bind -target ios,iossimulator -iosversion=17.0 -libname=box \
    -tags with_gvisor,with_utls,with_tailscale,with_low_memory,grpcnotrace,badlinkname,tfogo_checklinkname0 \
    -ldflags "-checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=$core_version -s -w" \
    -trimpath -buildvcs=false -o "$work/Libbox.xcframework" ./experimental/libbox

if [[ -e "$root/Vendor/Libbox.xcframework" ]]; then
    backup="$root/.build/Libbox-$(date +%Y%m%d_%H%M%S)-$$.xcframework"
    mv "$root/Vendor/Libbox.xcframework" "$backup"
fi
mv "$work/Libbox.xcframework" "$root/Vendor/"
