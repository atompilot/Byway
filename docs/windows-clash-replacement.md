# Windows 替代 Clash 调研

调研于 2026-11-23。以这台 Windows 11 PC 的生效配置为迁移基线，以 Clash Verge Rev、Mihomo 和 sing-box 官方文档补充能力对照。当前产品要求见 [PRODUCT](../PRODUCT.md#windows-分流与代理接管)，阶段安排见 [ROADMAP](../ROADMAP.md#近期迭代--windows-单节点分流)。

## 当前 PC 基线

| 核对项 | 读回结果 |
| --- | --- |
| 客户端与内核 | Clash for Windows 0.20.16 的 iKuuu 便携版。运行中的内核回报 Clash Premium 2023.05.19。 |
| 流量接管 | 当前 Windows 用户系统代理指向 `127.0.0.1:7890`。Clash 正在该地址提供 HTTP/SOCKS 混合代理，使用规则模式。采样时观察到 Logitech Options+ Agent 连接该端口。 |
| 进程与网卡 | 找到 Clash 用户登录自启项。采样时未发现 Clash 专用服务或活动 Clash TUN 网卡，程序目录包含 Wintun。以太网、Wi‑Fi 和 Tailscale 网卡处于 Up。全机接管、UDP 和 Tailscale 同时运行的行为待验证。 |
| 代理例外与外部依赖 | 系统代理例外已有内容，当前 PAC 未生效，Clash 本地保存了 PAC 模板。内核只监听回环地址，局域网流量代理处于关闭。读取的 WinHTTP 配置及用户级、机器级代理环境变量未指向该端口。应用内手动配置尚未逐项盘点。 |
| 配置和订阅 | 保存了两份 YAML，包括一份有订阅来源的活动配置。活动 YAML 为 495,067 字节，配置目录保有选择及订阅刷新元数据。 |
| 节点与策略组 | 运行中有 46 个节点，34 个 AES-256-GCM Shadowsocks，12 个 VMess。VMess 中有 2 个 WebSocket 和 3 个启用 TLS。46 个节点均声明 UDP。活动 YAML 定义 11 个手选策略组，其中 9 个引用其他组。内核另外显示 `GLOBAL`。 |
| 规则 | 生效的 9,816 条规则包含 9,018 条域名后缀、151 条精确域名、127 条关键词、505 条 IPv4/IPv6 CIDR、13 条目标端口规则、1 条 GEOIP 和 1 条 `MATCH`。活动 YAML 有 252 条 `no-resolve`，绝大多数规则引用具名组，末条 `MATCH` 也指向一个策略组。 |
| YAML 兼容 | 活动文件同时含 `proxies`/`rules` 和内容不同的旧式 `Proxy`/`Rules`。运行中节点数、规则数与小写字段一致。活动文件的 `proxy-providers` 和 `rule-providers` 均为 0 个。 |
| DNS | 活动 YAML 启用了 DNS，含 2 条 Host 映射、9 个引导解析地址、7 个主上游（5 个 DoT）及 1 条按域名匹配的 DNS 策略。规则优先级和真实解析路径尚未做逐请求回放。 |
| Byway | 本机 API 回报 Windows 0.7.0 正在运行，代理停用，已保存 63 个节点和 2 个节点组，分流配置为 0 份。已经有 GUI/API 多份 Shadowrocket 配置和切换验收。 |

版本、监听、代理状态、自启登记和网卡来自 PC 只读回查。规则与组数量来自 Clash 回环 API 的 `/version`、`/configs`、`/proxies` 和 `/rules`，以及活动文件的结构统计。Byway 版本和数据来自本机 API。此处记录结构统计，订阅地址、节点凭据、控制令牌和完整 YAML 留在原设备。旧版 Clash 以 PC 读回为准，现代客户端文档用于对照生态能力。 [Byway PC 验收摘要](../ROADMAP.md#当前状态) · [Clash Verge Rev 官方文档](https://www.clashverge.dev/guide/term.html)

## 功能差距

| 能力 | Byway 0.7.0 的实际边界 | 替代时的要求 |
| --- | --- | --- |
| 本地配置与远程订阅 | 分流导入器读取 128 KB 内的 Shadowrocket 文本。节点订阅读取链接文本及其 Base64 包装。 | 支持活动 Clash YAML 的体积和字段组合，从本地文件与订阅 URL 导入整份配置。读取现有配置索引与缓存或允许选择文件。预览生效字段、覆盖关系和不兼容项。支持订阅刷新、可设置更新周期、失败继续使用上一份有效配置。 |
| 节点字段与凭据 | 支持 SS、VMess、VLESS 链接等入口。现有协议支持只覆盖节点格式的一部分。 | 先验证实际 46 个节点的 SS/VMess 参数、WS、TLS 和 UDP 声明可迁移。保留证书校验设置。导入和实际能连接分别验收，按后续真实订阅需要扩展 Trojan、Hysteria2、TUIC 等协议。 |
| 策略组及组内选择 | 手动组和订阅组组织节点。Windows 内核只装载一个当前代理节点，`PROXY` 共用该出口。 | 规则能分别引用多个策略组，保留嵌套组、组内手选、当前选择和 `MATCH` 默认组。显示从规则到组再到最终出口的结果。更新后续沿用有效选择，并提示移除成员带来的变化。 |
| 完整分流与模式 | 支持 Shadowrocket 的有序域名、CIDR、`GEOIP,CN` 和 `FINAL` 等。可切换配置。 | 保存实际 YAML 的首命中顺序、端口匹配、`no-resolve`、`MATCH` 和具名策略。规则、全局、直连独立切换，并明确显示其与关闭代理的关系。 |
| DNS 行为 | 有配置级主 DNS 和 Host 映射。系统代理让代理客户端决定向 Byway 交付域名还是地址。 | 先保持实际配置的引导解析、多个上游、DoT/TCP 与 `nameserver-policy`。逐请求对照直连、代理、`no-resolve` 和 Host。Fake-IP、过滤、劫持及回退随使用场景推进。 |
| HTTP/SOCKS 接入与接棒 | 混合监听在回环接口，启动候选内核时自动选端口，系统代理跟着端口切换。 | 提供可配置的稳定 HTTP/SOCKS 混合端口，可接棒本机 7890。发现占用时显示原因和可选处理方式。切换策略和配置后按同一端口验证新请求。保留 Windows 代理例外，给现有命令行和应用提供兼容接入。 |
| 自动启动、托盘和恢复 | 已有托盘、Windows 代理恢复记录、守护和版本化安装。登录自启和迁移交接需要补齐。 | 登录后按明确保存的偏好恢复有效配置、模式和代理状态。可在并行验收后接管，再验证重启、睡眠唤醒、内核退出及回退。需要恢复 Clash 时，先确认它重新监听再恢复指向它的系统代理。 |
| 连接列表与排障 | 统计页读取速度、用量和活跃连接数。AI 页记录 API 调用。 | 可查看当前连接、流量、协议、规则、策略链和最终出口，必要时断开单条或全部。提供内核和 DNS 错误定位、日志级别及脱敏导出。迁移验收先做最小规则/出口解释。 |
| TUN 与网络兼容 | Windows 版使用系统代理。iOS 已有 TUN 实现可作产品行为参考。 | 全流量方案覆盖不读系统代理的应用、TCP/UDP、IPv4/IPv6 和 DNS。验证权限/驱动、路由排除、LAN、Tailscale、网络切换、睡眠和异常退出，停用、更新和卸载后回读恢复结果。 |
| 自动策略和外部提供者 | 支持手动节点测速及手动刷新订阅，具名策略的自动调度和外部 provider 需要新增。 | 现代配置需求包括 `url-test`、`fallback`、`load-balance` 与外部代理/规则 provider。PC 活动配置先交付手选组，后续按实际使用的配置验证自动策略、更新缓存与失效恢复。 |
| 生态接入与附加能力 | 有本机/局域网 Byway AI API、接入指南、skill 和调用日志。 | 迁移、模式、组内选择、刷新和诊断继续走 Byway API。PAC、WinHTTP、LAN 流量共享、Clash 控制 API 兼容层、配置增强脚本、链式代理、备份恢复等按实际依赖验证。 |

Byway 边界根据 [节点订阅解析](../Windows/Subscription.cs)、[Shadowrocket 解析](../Windows/ShadowrocketConfiguration.cs)、[内核路由生成](../Windows/ProxyCoreConfiguration.cs)、[端口与连接统计](../Windows/Core.cs)、[系统代理恢复](../Windows/ProxyLease.cs) 和 [Byway AI 指南](../Windows/AI-GUIDE.md) 核对。对照能力见 [Mihomo 路由](https://wiki.metacubex.one/en/config/rules/)、[Mihomo 策略组](https://wiki.metacubex.one/en/config/proxy-groups/)、[Mihomo DNS](https://wiki.metacubex.one/en/config/dns/)、[代理 provider](https://wiki.metacubex.one/en/config/proxy-providers/)、[规则 provider](https://wiki.metacubex.one/en/config/rule-providers/) 和 [连接与控制 API](https://wiki.metacubex.one/en/api/)。

## 迁移实现方向

1. **转换 PC 的在用配置。** 按 [内核决定](../ARCHITECTURE.md#代理内核) 由 Byway 自动转换 Clash YAML。先支持在用配置中的 SS/VMess、嵌套手选组、当前选择和规则；在本地文件验证通过后接入订阅刷新。GUI 和 AI API 共用导入与预览。 [Selector](https://sing-box.sagernet.org/configuration/outbound/selector/) · [混合入口](https://sing-box.sagernet.org/configuration/inbound/mixed/) · [规则集](https://sing-box.sagernet.org/configuration/rule-set/)
2. **按运行结果验收转换。** 对照当前 Clash 生效的字段和规则顺序，核查旧字段、端口匹配、`no-resolve` 与 DNS 上游。预览列出影响实际行为的转换差异。候选配置通过独立端口检查后才切换，刷新失败时继续使用上一份有效配置。 [Mihomo 规则](https://wiki.metacubex.one/en/config/rules/) · [sing-box DNS 规则](https://sing-box.sagernet.org/configuration/dns/rule/)
3. **让 TUN 作为独立接入能力验收。** 登录自启属于当前 PC 的替代条件，服务模式与 TUN 权限由实际需要决定。Windows 的 DNS、路由和防火墙状态需要单独读取和恢复，既有 Tailscale 是本机验收环境的一部分。涉及 UWP 或 WinHTTP 的需求按应用实测确定。 [Clash Verge Rev 模式说明](https://www.clashverge.dev/guide/term.html) · [sing-box TUN](https://sing-box.sagernet.org/configuration/inbound/tun/) · [Wintun](https://www.wintun.net/) · [WinINet 与 WinHTTP](https://learn.microsoft.com/en-us/windows/win32/wininet/wininet-vs-winhttp) · [Windows 服务管理](https://learn.microsoft.com/en-us/windows/win32/services/service-control-manager)

Clash Verge Rev 的订阅入口、配置增强（Merge/Script）和日志导出提供了后续产品对照。当前 PC 有一个在用远程配置及一份本地配置，配置合并、脚本、外部看板和高级统计的日常依赖尚未确认。优先级随迁移验收发现更新。 [Clash Verge Rev 项目](https://github.com/clash-verge-rev/clash-verge-rev) · [配置导入](https://www.clashverge.dev/guide/profile.html) · [日志导出](https://www.clashverge.dev/guide/log.html)

## 建议验收顺序

1. **离线预览与基线核对。** 用 PC 当前 YAML 和配置索引验证结构、旧字段优先级、节点参数、策略组当前选择和刷新来源。定位无法执行的项，分别记录解析结果和内核实际加载结果。
2. **并行对照。** 保留现有 Clash，在 Byway 的独立端口跑同样的请求。对照浏览器、当前观测到的桌面应用与实际常用开发工具，以及 PC 本地服务、局域网和 Tailscale。覆盖代理、直连、拒绝、策略组切换、只按端口命中的规则、DNS 策略和 `no-resolve`。看规则、实际出口和应用结果。
3. **接棒并回退演练。** 由用户选择切换时机。用稳定地址接管并验证订阅刷新、登录自启、一次完整重启、网络变化、内核退出及手动回退。用户确认日常任务后，才将这台 PC 的 Clash 退出现用。
4. **全流量验收。** 在独立阶段引入 TUN，用直接发起的 TCP/UDP 请求验证接管、排除和 DNS。覆盖双栈、Tailscale、权限失败、睡眠、进程崩溃、升级与卸载恢复。对照本机实际应用验证覆盖范围。

## Byway 0.8.0 实机验收

2026-11-23，在 Windows 11 PC 安装并启动 **Byway 0.8.0 x64**，运行 sing-box 1.14.4。使用 PC 原活动 YAML 和 Clash 实际保留的选择生成迁移配置。

- **转换与并行对照。** sing-box 校验并加载 46 个节点、11 个策略组和 9,816 条规则。11 个组选择与 Clash 一致。独立 HTTP 代理端口对 6 个目标的命中规则、组链与最终出口一致；两边的普通 DNS 查询、静态 Host 及一条实际节点域名的 DNS 策略查询都返回记录。
- **已安装版本。** 将原活动配置导入为「Clash · PC 在用」。临时接管系统代理时，百度、GitHub、Google 和 Apple 的 HTTPS 响应状态与 Clash 一致。活动配置可以换组，提交含未知生效规则的更新返回错误，原配置继续工作。停止 Byway 后，Windows 恢复 Clash 原来的代理设置。
- **界面与 AI。** 在 PC 配置页实测粘贴、预览、保存和打开策略组窗口。本机 AI API 验证导入、切换、换组和刷新。Mac 通过局域网验证状态和 Clash 预览，测试后恢复原局域网开关。
- **订阅恢复。** 真实 Clash 订阅通过读取与手动刷新。不通的来源无法覆盖已存原文。将两份临时测试配置标记为已到刷新时间后重启，一份完成自动刷新，另一份报告刷新失败并保留原配置。测试条目已清理。

本轮按样本核对迁移行为。固定端口日常接棒、重启自启、Windows TUN 和未使用的高级策略留在后续阶段验收。

## Byway 0.9.0 实机接棒验收

2026-11-23 在同一台 Windows 11 PC 安装 Byway 0.9.0，使用已迁移的「Clash · PC 在用」及原有 sing-box 1.14.4。

- **端口接棒。** Clash 占用 7890 时，Byway 提示占用并保留原 WinINet 设置。Byway 使用另一固定端口时可以与 Clash 并行。退出 Clash 后，以 Byway 接棒 7890，HTTP 和 SOCKS5 TCP 均取得真实 HTTPS 响应。规则、全局和直连之间切换时固定端口保持可用。
- **实际应用与诊断。** Microsoft Edge 使用系统代理加载 Example Domain，Byway 统计读取到流量。连接 API 读回真实来源、命中规则和出口，并成功断开指定连接。首次接棒时单一 HTTPS 探测超时，加入独立 HTTPS 探测后重跑通过。
- **恢复。** 端口改到被占用的地址或更换到不可用订阅时，原代理继续工作。终止 sing-box 后，Byway 恢复进程撤下已不可用的本机代理，内核日志保留该事件。退出 Byway 代理后重启 Clash，确认 Clash 重新监听 7890，原 Windows 代理设置完整恢复。
- **登录启动。** 在当前用户实际登记 Byway 的 Windows 登录命令，并用同一命令重新启动桌面应用，读回 7890 和先前选中的配置，HTTPS 验证通过。整机重启后的自动启动仍需一次 Windows 交互登录验收。演练后恢复原登录偏好。

## Byway 0.10.0 日常接管验收

2026-11-24，Byway 0.10.0 x64 在同一台 Windows 11 PC 接管日常系统代理。

- 在配置页运行「从 Clash 迁移…」，读到在用订阅、46 个节点、11 个策略组和 9,816 条规则。保存后逐组对照 Clash 当前选择，全部一致。40 条 Windows 代理例外完整保留。原先只含本地快照的 Byway 配置保留，新建订阅配置成为当前配置。实际订阅手动刷新通过。AI API 验证了预览、过期预览拒绝和兼容提示确认。
- 在 Clash 和 Byway 分别监听 7890 时，Google、GitHub、百度的 HTTP 代理与 Apple 的 SOCKS5 TCP 请求返回相同状态码。Edge 使用 Windows 系统代理载入 HTTPS 页面，Byway 读到了流量。Windows 系统代理确认局域网 IP 通配符和 Steam 域名例外继续直连。Tailscale 正在运行，Mac 经 Tailscale 的 SSH 连接仍可用。
- 演练从 Byway 切回 Clash，核对原代理设置和 HTTPS，再切回 Byway 并保留接管。Clash 已退出，登录启动项已备份并停用。Byway 登录启动和代理恢复已开启，同一启动命令实测恢复 7890 和迁入的配置，接管后再次刷新真实订阅通过。整机重启后的首次交互登录待验。

## Byway 0.11.0 全流量接管验收

2026-11-24，在同一台 Windows 11 PC 安装 Byway 0.11.0。通过「配置 → 代理接管」和本机 `PATCH /v1/config` 切换接管方式。应用启动全流量模式前验证透明 HTTPS，失败时保留原接管方式或恢复原配置。

- **终端与 DNS。** TUN 有效时，Windows 系统代理处于关闭状态。`curl.exe --noproxy '*'` 仍能访问 Google 并返回 `204`。额外验证了全局模式选择代理节点时的同一请求。TUN 地址和公网 UDP 53 查询均返回 DNS 应答。Windows 原生每接口 DNS 保留 Tailscale MagicDNS，Mac 经 Tailscale SSH 到 PC 成功。
- **路由和回退。** 公网 IPv4、IPv6 路由都指向 Byway-TUN，Tailscale 私网路由仍使用自己的网卡。切回系统代理时移除 TUN 网卡并恢复 7890。终止 TUN 内核时回读确认网卡和公网路由已恢复。验收结束后 PC 使用系统代理模式。PC 当时没有物理 IPv6 默认路由，原生 IPv6 网络的端到端表现待验。
- **UDP。** 直连出口的 NTP 和 STUN 已取得应答。本机可控的 Shadowsocks 测试端完成了 TUN 下的 UDP 请求、回包和原目的地址还原。全局模式也确认外部 UDP 流量命中所选节点，当前订阅抽测的两个节点未能返回 STUN 或 NTP 应答。测试结束后已删除临时配置并停用测试端。

## Byway 0.12.0 仅监听验收

2026-11-24，在同一台 Windows 11 PC 安装 Byway 0.12.0，通过「配置 → 代理接管 → 仅监听（手动代理）」启用。

- 从系统代理切到仅监听后，Windows 恢复原设置。显式使用 `127.0.0.1:7890` 的 HTTP 和 TCP SOCKS5 请求成功，普通 curl 沿用自身的直连设置。
- 通过 AI API 启停和切换模式。仅监听启停前后 WinINet 设置的读回值一致。目标端口已被占用时返回 `409`，原监听继续可用。仅监听与 TUN 来回切换通过，切回后回读确认虚拟网卡已移除。
- 重新执行已登记的 Windows 登录启动命令，应用恢复仅监听及 HTTPS 转发。验收后切回原先的系统代理模式，复测 HTTPS 通过。整机重启后的交互登录仍待验。

## Byway 0.12.2 批量测速验收

2026-11-24，在同一台 PC 的节点页点击「测试全部」。原版串行测试中 59 次成功的 HTTPS 请求累计 91.4 秒，该数字还未计入进程启动和失败请求。0.12.2 并发执行 HTTPS 请求，首轮部分成功时限时复测失败项。

- 新版完成全部 63 个节点及复测用时约 28 秒，61 个可用、2 个失败。实测最多同时运行 8 个探测内核，启动失败为 0。成功结果均返回出口 IP。
- 批量测试期间活动配置和混合端口保持可用，测试结束后通过 7890 的 HTTPS 请求返回 204。
