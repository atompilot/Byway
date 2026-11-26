#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf 'Usage: %s [--macos]\nBuild the pinned sing-box XCFramework for iOS and iOS Simulator.\n' "$0"
    printf 'With --macos, add the macOS slice to the existing Vendor/Libbox.xcframework.\n'
    exit 0
fi
build_macos=0
if [[ ${1:-} == --macos ]]; then
    build_macos=1
elif (( $# > 0 )); then
    printf 'Unexpected arguments. See --help.\n' >&2
    exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
core_version=1.14.4
gomobile_version=v0.1.13
work="$(mktemp -d "${TMPDIR:-/tmp}/byway-core.XXXXXXXX")"
if [[ -n ${BYWAY_KEEP_WORK:-} ]]; then
    printf 'Keeping the build directory at %s\n' "$work"
else
    trap 'rm -rf "$work"' EXIT
fi
export GOBIN="$root/.build/bin"
export PATH="$GOBIN:$PATH"
mkdir -p "$GOBIN"

curl --fail --silent --show-error --location --max-time 120 --retry 2 \
    "https://codeload.github.com/SagerNet/sing-box/tar.gz/refs/tags/v$core_version" -o "$work/core.tar.gz"
tar -xzf "$work/core.tar.gz" -C "$work"
cd "$work/sing-box-$core_version"
git apply "$root/Vendor/byway-tailscale.patch"
git apply "$root/Vendor/byway-native-tun.patch"
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

if (( build_macos )); then
    gomobile bind -target macos -macosversion=13.0 -libname=box \
        -tags with_gvisor,with_utls,with_tailscale,with_low_memory,grpcnotrace,badlinkname,tfogo_checklinkname0 \
        -ldflags "-checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=$core_version -s -w" \
        -trimpath -buildvcs=false -o "$work/Libbox-macos.xcframework" ./experimental/libbox
    if [[ ! -e "$root/Vendor/Libbox.xcframework" ]]; then
        printf 'Vendor/Libbox.xcframework is missing. Run %s without arguments first.\n' "$0" >&2
        exit 1
    fi
    macos_framework=""
    if [[ -d "$work/Libbox-macos.xcframework" ]]; then
        for candidate in "$work"/Libbox-macos.xcframework/*/Libbox*.framework; do
            if [[ -d $candidate ]]; then
                macos_framework=$candidate
                break
            fi
        done
    fi
    if [[ -z $macos_framework ]]; then
        printf 'The macOS slice is missing from the gomobile output:\n' >&2
        ls -R "$work/Libbox-macos.xcframework" >&2 || true
        exit 1
    fi
    # gomobile 给 macOS 产物加上 -Macos 后缀。统一改回 Libbox，两个平台共用 import Libbox。
    slice_name=$(basename "$macos_framework" .framework)
    slice="$work/macos-slice/Libbox.framework"
    rm -rf "$work/macos-slice"
    mkdir -p "$work/macos-slice"
    cp -R "$macos_framework" "$slice"
    mv "$slice/Versions/A/$slice_name" "$slice/Versions/A/Libbox"
    if [[ -e "$slice/Versions/A/Headers/$slice_name.h" ]]; then
        mv "$slice/Versions/A/Headers/$slice_name.h" "$slice/Versions/A/Headers/Libbox.h"
    fi
    sed -i '' "s/$slice_name/Libbox/g" "$slice/Versions/A/Modules/module.modulemap"
    rm -f "$slice/$slice_name"
    ln -sfn Versions/Current/Libbox "$slice/Libbox"
    printf 'Staged the macOS slice at %s\n' "$slice"
    xcodebuild -create-xcframework \
        -framework "$root/Vendor/Libbox.xcframework/ios-arm64/Libbox.framework" \
        -framework "$root/Vendor/Libbox.xcframework/ios-arm64_x86_64-simulator/Libbox.framework" \
        -framework "$slice" \
        -output "$work/Libbox-merged.xcframework" >/dev/null
    backup="$root/.build/Libbox-$(date +%Y%m%d_%H%M%S)-$$.xcframework"
    mv "$root/Vendor/Libbox.xcframework" "$backup"
    mv "$work/Libbox-merged.xcframework" "$root/Vendor/Libbox.xcframework"
    printf 'Updated Vendor/Libbox.xcframework with the macOS slice. Previous copy: %s\n' "$backup"
    exit 0
fi

gomobile bind -target ios,iossimulator -iosversion=17.0 -libname=box \
    -tags with_gvisor,with_utls,with_tailscale,with_low_memory,grpcnotrace,badlinkname,tfogo_checklinkname0 \
    -ldflags "-checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=$core_version -s -w" \
    -trimpath -buildvcs=false -o "$work/Libbox.xcframework" ./experimental/libbox

if [[ -e "$root/Vendor/Libbox.xcframework" ]]; then
    backup="$root/.build/Libbox-$(date +%Y%m%d_%H%M%S)-$$.xcframework"
    mv "$root/Vendor/Libbox.xcframework" "$backup"
fi
mv "$work/Libbox.xcframework" "$root/Vendor/"
