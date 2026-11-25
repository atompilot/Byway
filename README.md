# Byway

Byway 是一个支持 iPhone、iPad、Windows 和 Linux 热点网关的代理客户端。AI 可以查询当前节点，测试 HTTPS 连通性，并切换到可用的出口。各客户端使用 sing-box 1.14.4 作为代理内核。

[产品文档](PRODUCT.md) · [概念](CONCEPTS.md) · [UIUX](UIUX.md) · [技术架构](ARCHITECTURE.md) · [路线图](ROADMAP.md)

构建 iPhone、iPad 或 Windows 版需要 `Tunnel/Resources/geoip-cn.srs`。如果本地缺少该文件，请按 [GeoIP 数据说明](Tunnel/Resources/GeoIP-NOTICE.txt) 从上游下载，核对 SHA-256 后存到该路径。

## Linux 热点网关

手机连接 Linux 主机发出的 Wi‑Fi，由主机用选中的 Byway 节点代理热点流量。手机侧使用普通 Wi‑Fi 连接。构建、部署、节点控制和停用方法见 [Linux 网关指南](Linux/README.md)。

## Windows 11 x64

在 Windows 上用 .NET 10 SDK、Go 1.25.5 和 Git 构建自包含发行包。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\build-windows.ps1
```

解压构建输出的 ZIP，在解压目录运行以下命令安装到当前用户。安装后从开始菜单打开 **Byway**。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

选择「添加订阅…」，粘贴 `sub://` 或 HTTPS 订阅链接，也可在对话框中读取二维码图片。成功后打开对应节点组。选中组后可手动刷新、测试本组或打开组设置。当前支持链接列表或 Base64 包装的链接列表，包含 TCP / WebSocket VMess、TCP / WebSocket VLESS 或 Shadowsocks。无法识别的节点会计入跳过数量。

选中订阅组后，节点列表上方显示服务端提供的剩余流量、总额度、上传、下载和本地到期时间。刷新订阅时一起更新。已导入的订阅组可以通过刷新补齐这些信息。

「扫码…」支持开启相机、选择本地二维码图片或粘贴分享链接。右键节点可使用、测试、查看与编辑、分享二维码或删除。选中节点组可测试本组或分享整组。二维码可保存为 PNG，也可复制链接。手动组用 Byway 扫码导入，较大的组会生成多张二维码。

「添加节点…」可粘贴单节点链接并填写名称。手动组可在「组设置」中调整名称与成员，订阅组可改名或更换地址。订阅刷新会保留本机对节点的修改或删除。单击节点行即可切换，代理停用时可以从侧栏开启。托盘菜单也支持启停、按组切换节点和退出。

「配置」可编辑 Windows 系统代理例外。「统计」显示实时速率和活跃连接，并可查看此设备记录的累计及分时流量。「设置」可选择关闭窗口时收起到托盘或退出，也可打开数据文件夹。

「配置 → 代理接管」可选择系统代理、全流量（TUN）或仅监听（手动代理）。全流量模式需要管理员权限，终端和其他应用通过虚拟网卡接入。仅监听模式为显式指定代理的应用提供本机混合端口，默认 `127.0.0.1:7890`，支持 HTTP 和 TCP SOCKS5。接管方式和规则、全局或直连独立设置。运行 Clash 时可用另一端口试用 Byway，再接棒 7890。「统计」提供连接列表和内核日志。「设置 → 登录启动」可分别开启登录启动和恢复上次启用的代理。

「配置 → 分流配置」支持保存多份 Shadowrocket `.conf`。可从文件导入或粘贴，预览后保存，再从列表切换。规则模式下，`PROXY` 使用节点页的当前节点，`DIRECT` 直连。需核对支持范围时参见 [产品文档](PRODUCT.md#windows-分流与代理接管)。配置可由 AI 通过 [Windows API](Windows/AI-GUIDE.md#配置与授权) 管理。

同一入口也可读取旧 Clash YAML 的规则。原配置的代理规则使用 Byway 当前节点，详情见 [旧配置兼容行为](PRODUCT.md#windows-分流与代理接管)。

Clash for Windows 正在提供系统代理时，可用「配置 → 分流配置 → 从 Clash 迁移…」读取在用分流规则及系统代理例外。确认保存后，退出 Clash，选择节点并开启 Byway 代理。

左侧「AI」显示连接地址与局域网开关。点「复制 AI 接入指令」，将两行文字粘贴给 AI。AI 会从设备读取指南，并按宿主支持的方式安装可复用的 `byway-control`。 [API 指南](Windows/AI-GUIDE.md) · [byway-control](Windows/Skills/byway-control/SKILL.md)

本机 API 用端口 8766，局域网用 8767。在「AI」页打开「允许局域网控制」。当前版本缺少放行规则时，按 Windows 提示确认管理员授权。再次开关可复用该授权。关闭后停止局域网监听。

运行 `dotnet run --project Tests/WindowsNodeImport` 验证节点导入、订阅解析、刷新时复用节点 ID 及保留本机修改。

## iPhone 和 iPad 构建

需要 Xcode、Go 1.25.5 或更新版本及 XcodeGen。本地已有 `Vendor/Libbox.xcframework` 时可直接打开 `Byway.xcodeproj`。新检出可用以下命令构建。

```sh
./Scripts/build-core.sh
xcodegen generate
open Byway.xcodeproj
```

选择 Byway scheme。模拟器可验证界面和配置。真机需要给 Byway 和 BywayTunnel 选择同一个 Apple Developer Team，在开发者账号中将两个 App ID 加入 `group.cn.splaz.byway`，再让 Xcode 生成包含该组和 Network Extensions 的描述文件。更换命名空间时修改 `project.yml` 的 `BYWAY_BUNDLE_ID` 和两个 `.entitlements` 中的 App Group，再重新生成工程。首次连接时在手机上允许添加 VPN 配置。

「添加节点」可粘贴链接或列表、扫相机或图片二维码，也可导入 Shadowrocket 节点 JSON。支持 TCP / RAW / WebSocket VLESS、TCP / WebSocket VMess、Shadowsocks 和 SOCKS5。「订阅」可添加、替换和刷新 HTTPS 或 `sub://` 订阅，查看服务端提供的流量与到期信息。节点及节点组可生成分享链接或二维码。

## 分流配置

从首页「分流配置」导入 Shadowrocket `.conf` 或 Clash YAML。预览规则和兼容提示后保存，再选择当前配置。旧版保存的一份配置会保留原文和启用状态。规则按原顺序首命中生效，`PROXY` 使用 Byway 当前选择的节点。已保存的配置支持测试域名或 IP 所命中的规则，Shadowrocket 配置可从测试结果添加规则。

Clash 规则模式支持文件内的手选组、基本域名和 IP 规则，以及 `GEOIP,CN`。依赖外部规则或代理提供者的配置会提示无法导入。

## 全局路由

在首页进入「全局路由」，可选择按配置、全局代理、全局直连或按场景。全局代理与全局直连覆盖域名和 IP 分流规则，继续使用已启用配置的 DNS 和隧道排除路由。

节点组可以指定代理出口的候选节点。启用故障切换后，VPN 扩展定期测试当前节点。连续两次 HTTPS 测试失败时，扩展会尝试同组内的备用节点，仅在备用节点测试成功后切换。未选节点组时，候选范围是全部节点。删除最后一个组成员时会移除空组并恢复相关设置到全部节点。

场景可根据 Wi‑Fi、蜂窝网络、有线网络或其他网络选择路由模式和节点组。未匹配的网络使用「其他网络」场景或当前默认节点组的配置分流。VPN 运行期间由扩展监测网络类型变化。

## DNS

首页「DNS」可以添加、编辑和删除加密 DNS，最多保存 8 个。内置 Cloudflare、AliDNS、DNSPod 和 Google。自定义服务器填写 HTTPS DNS（DoH）地址，可选填连接 IP。

- 「跟随分流配置」优先使用导入配置或旧 DNS 设置，未指定时自动选择。
- 「自动选择」通过当前出口并行测试已添加的加密 DNS。Byway 在隧道会话内为每个出口记住所选服务器。主用服务器连续两次查询失败且备用查询成功时，切换到已响应的服务器。
- 「手动指定」通过当前出口使用所选加密 DNS。

## 流量与测速

首页「流量」显示 VPN 转发的应用流量。上传和下载分别计数，连接期间还显示实时速率和本次用量。累计用量由 VPN 扩展在运行期间定期保存。可按时段查看上传和下载历史，并通过「连接与排障」查看实际出口、断开连接或查看内核日志。

连接 VPN 后，可用节点旁的按钮测试单个节点，也可点「测试全部节点延迟」。列表显示 HTTPS 连通性、延迟和出口 IP。在「流量 → 带宽测速」可测当前节点的上传和下载速度，一次通过该节点向 Cloudflare 传输约 5 MB 测试数据。

## 私网

iPhone 在首页 DNS 下方进入「私网」，iPad 和 Windows 用侧栏。选「Tailscale 账号」后直接授权即可使用默认中继。如果使用自托管 Headscale，或选择「严格匹配自定义中继」，把协调服务下发的中继域名填入 Byway。完成授权后，从设备详情测试连接，查看实际路径。

在 Headscale 仅提供自建中继时，从其配置移除默认 DERP 来源。Windows 选择「全流量（TUN）」以便普通应用访问私网。需要从其他私网设备访问 Windows 本机服务时，在「私网和中继设置」填写对应 TCP 端口。

[Tailscale 自定义 DERP](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers) · [Headscale DERP](https://headscale.net/stable/ref/derp/) · [移动端 API](docs/mobile-ai.md#私网) · [Windows API](Windows/AI-GUIDE.md#私网)

## 接入 AI

在 iPhone 的 **AI 控制** 开启 **允许局域网控制**，点 **复制接入指令**，再粘贴给同一 Wi‑Fi 上电脑中的 AI。手动调用时，每次 HTTP/1.1 请求都需要附上 `Authorization: Bearer <访问令牌>`。Mac 可以直接调用，例如先用 `curl` 查询状态。

```sh
curl --header "Authorization: Bearer $BYWAY_LAN_TOKEN" "$BYWAY_LAN_URL/v1/status"
```

接口监听当前 Wi‑Fi 的 IPv4 地址。VPN 已连接时由 VPN 扩展提供接口，主 App 退到后台或锁屏后，Mac 仍使用同一个地址和令牌。VPN 断开时由前台 App 提供接口，退到后台会关闭监听。两处交接监听时使用同一个端口。关闭开关会使当前令牌失效，再开启会生成新令牌。局域网接口使用 HTTP，请在信任的 Wi‑Fi 使用。

移动端的接口及请求字段见 [iPhone 和 iPad API 指南](docs/mobile-ai.md)。同一份指南也可以通过 `GET /v1/guide` 获取。

### 中继控制

「AI 控制」中的「中继控制设置」提供 MCP 接入。修改中继地址或密钥时先断开 VPN。

控制服务使用 Python 3.10 及以上版本。分别设置 `BYWAY_DEVICE_KEY` 和 `BYWAY_MCP_KEY` 环境变量，使用不同的随机密钥，例如分别执行 `openssl rand -hex 32`。用以下命令启动服务。

```sh
python3 Control/server.py
```

默认监听 `127.0.0.1:8765`。为 iPhone 提供可访问且证书受信任的 HTTPS 地址，可以在该服务前配置 HTTPS 反向代理，或使用 `--host`、`--cert` 和 `--key` 直接提供 TLS。控制服务当前配对一台设备。反向代理需允许 `/device/exchange` 的 15 秒长轮询，超时建议至少 30 秒。

1. 在 iPhone 的 **中继控制设置** 输入控制服务的 HTTPS 基础地址和设备密钥，随后连接隧道。
2. 在 AI 客户端添加 Streamable HTTP MCP。AI 与控制服务在同一台 Mac 时使用 `http://127.0.0.1:8765/mcp`，设置 `Authorization: Bearer <MCP 密钥>`。
3. 使用 `byway_status` 获取手机回报的节点 ID。使用 `byway_probe` 测得延迟和出口 IP。用 `byway_select` 先测试目标节点，再切换并回读生效的节点。

探测由手机代理内核经指定节点访问 HTTPS 测试接口。控制服务报告的是手机最近一次状态，显示距回报已过的时间。设备失联时，等待中的操作会到期，重新查询状态后再决定是否重试。节点连接凭据保留在手机共享容器，控制服务只收节点 ID、名称、状态和探测结果。

## 验证

```sh
python3 -m unittest discover -s Control -v
mkdir -p .build
swiftc -D BYWAY_LOCAL_TEST Shared/*.swift Tests/LANServerFixture.swift -o .build/lan-server-fixture
python3 Tests/test-lan-handoff.py .build/lan-server-fixture
swiftc Shared/*.swift Tests/MobileParityFixture.swift -o .build/mobile-parity-fixture
.build/mobile-parity-fixture
```

本地测试用两个 Mac 进程检查端口交接、令牌变更和配置保存。真机安装和锁屏后的局域网验收见 [ROADMAP.md](ROADMAP.md)。

## 许可证

Byway 自有源码采用 [GNU GPL v3 或后续版本](LICENSE)（`GPL-3.0-or-later`）。第三方组件和数据适用各自的许可。参见 [代理内核](Vendor/README.md)、[GeoIP 数据](Tunnel/Resources/GeoIP-NOTICE.txt)、[ZXing.Net](Windows/ZXing.Net.LICENSE) 和 [YamlDotNet](Windows/YamlDotNet.LICENSE)。
