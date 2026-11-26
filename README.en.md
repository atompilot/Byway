# Byway

[简体中文](README.md) · [GitHub Releases](https://github.com/atompilot/Byway/releases)

Byway is an open-source proxy client for iPhone, iPad, Mac, Windows, and Linux Wi‑Fi hotspot gateways. Bring your own proxy nodes to test HTTPS connectivity, check your exit IP address, or switch to a working node. You can authorize AI tools and scripts to do the same through the target device’s API. Byway uses [sing-box 1.14.4](Vendor/README.md) as its proxy engine.

## Platforms

| Platform | Traffic capture | Installation and build |
| --- | --- | --- |
| macOS 14+ | System proxy, full traffic (TUN), or listen only | [Mac](#mac) |
| Windows 11 x64 | System proxy, full traffic (TUN), or listen only | [Windows](#windows) |
| iOS / iPadOS 17+ | VPN through Apple Network Extension | [iPhone and iPad](#iphone-and-ipad) |
| Linux ARM64 | Proxy for Wi‑Fi hotspot clients on a Debian / Armbian host | [Linux hotspot gateway](#linux-hotspot-gateway) |

See the assets on [GitHub Releases](https://github.com/atompilot/Byway/releases) for available packages. Build instructions are below.

The interface supports Simplified Chinese, English, and Spanish. The apps use the system or per-app language, the Linux gateway CLI uses its locale, and the management page uses the browser language. Other languages fall back to English.

## Get started

1. In the desktop or mobile app, import a compatible node link, a QR code image, or an HTTPS or `sub://` subscription. Supported protocols include VLESS, VMess, and Shadowsocks. Import options vary by platform. The Linux gateway uses a Shadowrocket node JSON export.
2. Test your nodes, select a working exit, and start the proxy or VPN. For Linux, set up the gateway first, then connect your devices to its Wi‑Fi hotspot.
3. To route by domain or IP, import a Shadowrocket `.conf` or compatible Clash YAML file on Mac, Windows, iPhone, or iPad. Review compatibility notes before saving and activating it. Rules are evaluated in order. `PROXY` uses the selected node, `DIRECT` connects directly, and `FINAL` handles traffic that matches no earlier rule. Configurations that depend on external rule or proxy providers may fail to import.

The desktop and mobile apps show traffic history and connection diagnostics. Quotas and expiry dates come from the subscription provider and update when you refresh the subscription. iPhone, iPad, and Windows can also join a Tailscale or self-hosted Headscale network. On Windows, select TUN so ordinary apps can reach private peers. Headscale requires the expected DERP hostnames. See the [product documentation in Chinese](PRODUCT.md#私网).

## Installation and builds

### Before building

To build for Mac, Windows, iPhone, or iPad, follow the [GeoIP data notice](Tunnel/Resources/GeoIP-NOTICE.txt) to download the pinned upstream file. Verify its SHA-256 and save it as `Tunnel/Resources/geoip-cn.srs`. Run the build commands below from the repository root.

### Mac

If the release package contains `Byway.app`, move it to Applications and open it. Listen-only mode exposes a local HTTP and SOCKS5 port at `127.0.0.1:7890` by default. System proxy mode points apps that follow the system proxy at that port. TUN mode captures traffic through a virtual network interface. System proxy and TUN modes require administrator approval. The Mac app can import QR codes from images.

To build from source, install Xcode, XcodeGen 2.40+, Go 1.25.5+, Git, and Python 3. Build the iOS and simulator slices before adding the macOS slice.

```sh
./Scripts/build-core.sh
./Scripts/build-core.sh --macos
xcodegen generate
open Byway.xcodeproj
```

Select the **BywayMac** scheme in Xcode. You can reuse an existing `Vendor/Libbox.xcframework` if it contains the required slices.

### Windows

Extract the entire Windows x64 ZIP and run the install script from the extracted folder. It installs Byway for the current user. Open **Byway** from the Start menu.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

Under **Configuration → Proxy capture** (「配置 → 代理接管」), choose system proxy, full traffic (TUN), or listen only. TUN requires administrator privileges. Listen-only mode provides a local HTTP and TCP SOCKS5 port at `127.0.0.1:7890` by default. To try Byway while Clash is running, use a different port. To copy the routing rules and proxy exceptions in use by Clash for Windows, choose **Configuration → Routing profiles → Migrate from Clash** (「配置 → 分流配置 → 从 Clash 迁移…」). Save the profile, quit Clash, and start the Byway proxy. You can enable launch at sign-in and proxy restoration separately in Settings.

To build from source, use Windows with the .NET 10 SDK, Go 1.25.5+, and Git. The script writes a self-contained ZIP under `.build/windows/`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\build-windows.ps1
```

### iPhone and iPad

Build with Xcode, XcodeGen 2.40+, Go 1.25.5+, Git, and Python 3.

```sh
./Scripts/build-core.sh
xcodegen generate
open Byway.xcodeproj
```

Select the **Byway** scheme. The simulator can test the UI and configuration. For a physical device, select the same Apple Developer Team for `Byway` and `BywayTunnel`. Enable App Groups for both App IDs and add them to the same group. The provisioning profiles must include the appropriate Network Extension entitlement. To use your own identifiers, change `BYWAY_BUNDLE_ID` in `project.yml` and the App Group in `App/App.entitlements` and `Tunnel/Tunnel.entitlements`, then regenerate the project. Allow iOS to add the VPN configuration on first connect.

### Linux hotspot gateway

The Linux edition runs on the host that provides the Wi‑Fi hotspot. The gateway proxies IPv4 TCP, UDP, and DNS for connected clients. The [Linux gateway guide in Chinese](Linux/README.md) covers the configuration generator, sing-box, systemd services, and NetworkManager hotspot setup.

## Connect AI tools

- **iPhone, iPad, and Mac**. In **AI Control** (「AI 控制」), enable LAN control and copy the setup instructions to your AI tool on the same network. On iPhone and iPad, the VPN extension serves the API while the VPN is connected, including when the device is locked. Keep Byway in the foreground when the VPN is disconnected. [Mobile API guide in Chinese](docs/mobile-ai.md)
- **Windows**. Copy the setup instructions from the **AI** page. Use the local API on port `8766` from the same machine. For another device, enable LAN control on port `8767` and approve the firewall prompt if needed. [Windows API guide in Chinese](Windows/AI-GUIDE.md) · [byway-control](Windows/Skills/byway-control/SKILL.md)
- **Linux**. The gateway guide covers the local device API, node queries and switching, SSH forwarding, and the management page. [Linux gateway guide in Chinese](Linux/README.md#节点控制)

The copied instructions include the target device’s address and access token. For manual requests, set them as `BYWAY_LAN_URL` and `BYWAY_LAN_TOKEN`. Read the status first to confirm the device, then read it again after an action to verify the active node, routing profile, or connection state. The LAN API uses HTTP. Enable it on a trusted network.

```sh
curl --noproxy '*' --header "Authorization: Bearer $BYWAY_LAN_TOKEN" \
  "$BYWAY_LAN_URL/v1/status"
```

You can also open the [management page](docs/management-web.md) and enter the access token to see the device, node, and connection status.

### MCP relay

To control an iPhone or iPad from outside the local network, run a self-hosted MCP relay. It requires Python 3.10+. Set separate random values for `BYWAY_DEVICE_KEY` and `BYWAY_MCP_KEY` before starting it. You can generate each with `openssl rand -hex 32`.

```sh
python3 Control/server.py
```

The relay listens on `127.0.0.1:8765` by default and currently pairs with one device. Give the mobile device an HTTPS endpoint with a trusted certificate using a reverse proxy or the `--host`, `--cert`, and `--key` options. Allow at least 30 seconds for `/device/exchange` long polling if you use a reverse proxy.

1. With the VPN disconnected, enter the HTTPS base URL and device key under **AI Control → Relay control settings** (「AI 控制 → 中继控制设置」), then connect the VPN.
2. Add a Streamable HTTP MCP server to your AI client. If it runs on the same machine as the relay, use `http://127.0.0.1:8765/mcp` with `Authorization: Bearer <MCP key>`.
3. Use `byway_status` to read the latest device report, `byway_probe` to test a candidate node, and `byway_select` to test, switch, and verify the active node.

## Development and tests

```sh
python3 -m unittest discover -s Control -v
python3 Tests/test-localization.py
mkdir -p .build
swiftc -D BYWAY_LOCAL_TEST Shared/*.swift Tests/LANServerFixture.swift -o .build/lan-server-fixture
python3 Tests/test-lan-handoff.py .build/lan-server-fixture
swiftc Shared/*.swift Tests/MobileParityFixture.swift -o .build/mobile-parity-fixture
.build/mobile-parity-fixture
dotnet run --project Tests/WindowsNodeImport
```

Run the Swift checks on a Mac. The .NET tests require the .NET 10 SDK. See the [roadmap in Chinese](ROADMAP.md) for build and device verification status.

Project docs in Chinese · [Product](PRODUCT.md) · [Concepts](CONCEPTS.md) · [UI and UX](UIUX.md) · [Architecture](ARCHITECTURE.md) · [Device API](docs/device-api.md)

## License

Byway’s own source code is licensed under the [GNU GPL v3 or later](LICENSE) (`GPL-3.0-or-later`). Third-party components and data have their own terms. See the [proxy engine](Vendor/README.md), [GeoIP data](Tunnel/Resources/GeoIP-NOTICE.txt), [ZXing.Net](Windows/ZXing.Net.LICENSE), and [YamlDotNet](Windows/YamlDotNet.LICENSE).
