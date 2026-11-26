# Byway

[English](README.en.md) · [GitHub Releases](https://github.com/atompilot/Byway/releases)

Byway 是一个开源代理客户端，面向 iPhone、iPad、Mac、Windows 和 Linux Wi‑Fi 热点网关。导入自己的代理节点后，可以测试 HTTPS 连通性、查看出口 IP，或切换到可用节点。授权后，AI 和脚本也可以通过目标设备的 API 进行这些操作。各端使用 [sing-box 1.14.4](Vendor/README.md) 作为代理内核。

## 选择平台

| 平台 | 流量接管 | 安装与构建 |
| --- | --- | --- |
| macOS 14+ | 系统代理、全流量（TUN）、仅监听 | [Mac](#mac) |
| Windows 11 x64 | 系统代理、全流量（TUN）、仅监听 | [Windows](#windows) |
| iOS / iPadOS 17+ | 通过 Apple Network Extension 提供 VPN | [iPhone 和 iPad](#iphone-和-ipad) |
| Linux ARM64 | 代理 Debian / Armbian 主机的 Wi‑Fi 热点流量 | [Linux 热点网关](#linux-热点网关) |

各平台已发布的安装包以 [GitHub Releases](https://github.com/atompilot/Byway/releases) 的附件为准。以下也提供源码构建路径。

界面支持简体中文、英语和西班牙语。客户端跟随系统或应用语言，Linux 网关命令行跟随 locale，管理网页跟随浏览器语言。其他语言默认使用英语。

## 开始使用

1. 在桌面或移动客户端导入兼容的节点链接、二维码图片、HTTPS 或 `sub://` 订阅。支持 VLESS、VMess 和 Shadowsocks 等协议，具体导入方式因平台而异。Linux 网关使用 Shadowrocket 节点 JSON。
2. 测试节点并选用可用的出口，然后启动代理或 VPN。Linux 上请先配置网关，再让设备加入它发出的 Wi‑Fi。
3. 如需按域名或 IP 分流，可在 Mac、Windows、iPhone 和 iPad 导入 Shadowrocket `.conf` 或兼容的 Clash YAML。预览兼容提示后保存并启用。规则按顺序匹配，`PROXY` 使用当前选中的节点，`DIRECT` 走直连，`FINAL` 决定未命中时的走向。依赖外部规则或代理提供者的配置可能无法导入。

桌面和移动客户端可查看流量记录和连接诊断。订阅的额度和到期时间由服务端提供，刷新订阅时一并更新。iPhone、iPad 和 Windows 也可以接入 Tailscale 或自托管 Headscale 私网。Windows 上的普通应用通过 TUN 访问私网，Headscale 需要配置预期的 DERP 域名。详见 [产品文档](PRODUCT.md#私网)。

## 安装与构建

### 构建前准备

从源码构建 Mac、Windows、iPhone 或 iPad 版时，按 [GeoIP 数据说明](Tunnel/Resources/GeoIP-NOTICE.txt) 从上游下载固定版本的数据，核对 SHA-256 后存为 `Tunnel/Resources/geoip-cn.srs`。以下构建命令在仓库根目录运行。

### Mac

如果下载的发行包中有 `Byway.app`，将它移到「应用程序」并打开。仅监听模式提供本机 HTTP 和 SOCKS5 混合端口，默认地址为 `127.0.0.1:7890`。系统代理会把使用系统代理的应用指向该端口。全流量模式通过虚拟网卡接管。系统代理和全流量模式需要管理员授权。Mac 可从图片导入二维码。

从源码构建需要 Xcode、XcodeGen 2.40+、Go 1.25.5+、Git 和 Python 3。先构建 iOS 和模拟器切片，再追加 macOS 切片。

```sh
./Scripts/build-core.sh
./Scripts/build-core.sh --macos
xcodegen generate
open Byway.xcodeproj
```

在 Xcode 选择 **BywayMac** scheme。生成的 `Vendor/Libbox.xcframework` 已包含所需切片时，可以复用。

### Windows

完整解压 Windows x64 ZIP，在解压目录运行安装脚本，然后从开始菜单打开 **Byway**。安装脚本将应用安装到当前用户。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

在「配置 → 代理接管」选择系统代理、全流量（TUN）或仅监听。TUN 需要管理员权限。仅监听模式提供本机 HTTP 和 TCP SOCKS5 混合端口，默认地址为 `127.0.0.1:7890`。运行 Clash 时，可以先用不同端口验证 Byway。若要迁移 Clash for Windows 在用的分流规则和代理例外，使用「配置 → 分流配置 → 从 Clash 迁移…」。保存后退出 Clash，再开启 Byway。登录启动与恢复代理可在设置中分别开启。

从源码构建需要 Windows、.NET 10 SDK、Go 1.25.5+ 和 Git。脚本在 `.build/windows/` 输出自包含 ZIP。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\build-windows.ps1
```

### iPhone 和 iPad

使用 Xcode、XcodeGen 2.40+、Go 1.25.5+、Git 和 Python 3 构建。

```sh
./Scripts/build-core.sh
xcodegen generate
open Byway.xcodeproj
```

选择 **Byway** scheme。模拟器可验证界面和配置。真机运行时，为 `Byway` 和 `BywayTunnel` 选择同一个 Apple Developer Team。两个 App ID 都需要启用 App Groups 并加入同一个组，签名描述文件需要包含相应的 Network Extension 权限。使用自己的标识符时，在 `project.yml` 修改 `BYWAY_BUNDLE_ID`，在 `App/App.entitlements` 和 `Tunnel/Tunnel.entitlements` 修改 App Group，然后重新生成工程。首次连接时，在设备上允许添加 VPN 配置。

### Linux 热点网关

Linux 版运行在提供 Wi‑Fi 热点的主机上。手机接入热点后由网关转发 IPv4 TCP、UDP 和 DNS。配置生成器、sing-box、systemd 服务以及 NetworkManager 热点的安装步骤见 [Linux 网关指南](Linux/README.md)。

## 接入 AI

- **iPhone、iPad 和 Mac**。在「AI 控制」开启「允许局域网控制」，复制接入指令给同一局域网的 AI。iPhone 和 iPad 在 VPN 连接时由 VPN 扩展提供 API，锁屏后仍可接收请求。VPN 断开时请将 Byway 保持在前台。 [移动端 API 指南](docs/mobile-ai.md)
- **Windows**。在「AI」页复制接入指令。在同一设备上使用本机 API（端口 `8766`）。跨设备时开启局域网控制（端口 `8767`），按需确认防火墙授权。 [Windows API 指南](Windows/AI-GUIDE.md) · [byway-control](Windows/Skills/byway-control/SKILL.md)
- **Linux**。网关指南提供本机设备 API、节点查询与切换、SSH 转发和管理网页的入口。 [Linux 网关指南](Linux/README.md#节点控制)

复制指令也会提供目标设备的访问地址和令牌。手动调用时，把它们设置为 `BYWAY_LAN_URL` 和 `BYWAY_LAN_TOKEN`。先读状态确认设备，操作后再回读实际生效的节点、分流或连接状态。局域网 API 使用 HTTP，请在信任的网络中开启。

```sh
curl --noproxy '*' --header "Authorization: Bearer $BYWAY_LAN_TOKEN" \
  "$BYWAY_LAN_URL/v1/status"
```

也可打开 [管理网页](docs/management-web.md)，输入访问令牌后查看设备、节点和连接状态。

### MCP 中继

需要在局域网之外控制 iPhone 或 iPad 时，可以自建 MCP 中继。控制服务需要 Python 3.10+。启动前为 `BYWAY_DEVICE_KEY` 和 `BYWAY_MCP_KEY` 设置各自的随机密钥，例如分别运行 `openssl rand -hex 32` 生成。

```sh
python3 Control/server.py
```

控制服务默认监听 `127.0.0.1:8765`，当前配对一台设备。通过 HTTPS 反向代理，或使用 `--host`、`--cert` 和 `--key`，为移动设备提供证书受信任的 HTTPS 地址。反向代理应为 `/device/exchange` 的长轮询留出至少 30 秒。

1. VPN 断开时，在「AI 控制 → 中继控制设置」填写 HTTPS 基础地址与设备密钥，然后连接 VPN。
2. 在 AI 客户端添加 Streamable HTTP MCP。与中继同机时可用 `http://127.0.0.1:8765/mcp`，请求带上 `Authorization: Bearer <MCP 密钥>`。
3. 用 `byway_status` 查看设备最近回报的状态，用 `byway_probe` 测试候选节点，用 `byway_select` 测试后切换并核对回读结果。

## 开发与验证

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

Swift 检查在 Mac 上运行，.NET 检查需要 .NET 10 SDK。构建与设备验收状态见 [路线图](ROADMAP.md)。

[产品](PRODUCT.md) · [概念](CONCEPTS.md) · [界面设计](UIUX.md) · [架构](ARCHITECTURE.md) · [设备 API](docs/device-api.md)

## 许可证

Byway 自有源码采用 [GNU GPL v3 或后续版本](LICENSE)（`GPL-3.0-or-later`）。第三方组件和数据适用各自的许可。参见 [代理内核](Vendor/README.md)、[GeoIP 数据](Tunnel/Resources/GeoIP-NOTICE.txt)、[ZXing.Net](Windows/ZXing.Net.LICENSE) 和 [YamlDotNet](Windows/YamlDotNet.LICENSE)。
