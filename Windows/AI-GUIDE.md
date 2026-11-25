# Byway Windows API 指南

本机地址为 http://127.0.0.1:8766。另一台设备连接时，在 Byway 的「AI」页开启局域网控制，按需确认 Windows 防火墙授权，再使用页面显示的 mDNS 地址，如 `http://pc.local:8767`。Byway 用设备 ID 发布独立服务，网页地址使用已能解析到本机局域网 IP 的 Windows `.local` 主机名。如果当前网络无法解析 `.local`，请使用页面显示的局域网 IP 地址。防火墙规则仅放行当前程序在专用网络上的同网段连接。局域网访问使用 HTTP，请在信任的局域网开启。Byway 收起到托盘时 API 仍可用。

每个请求带上 `Authorization: Bearer <TOKEN>`。JSON 请求带上 `Content-Type: application/json`。使用 HTTP 客户端直连设备。如果系统设置了代理，将 Byway 地址加入该客户端的代理例外，例如 curl 使用 `--noproxy '*'`。

浏览器可访问 API 地址的根路径。可在「AI」页直接打开或复制管理网页链接。 [管理网页](../docs/management-web.md)

## 首次接入与长期复用

1. 在当前 AI 宿主检查是否已安装 `byway-control`。如未安装，向同一设备发送 `GET /v1/skill`，把响应保存为 `byway-control/SKILL.md`，放到该宿主识别的用户级技能目录。优先使用宿主提供的安装机制。
2. 安装后回读文件，确认技能名是 `byway-control`，然后在本次及后续请求中使用。遇到已存在的同名自定义技能时先保留。宿主无法安装时，可用本指南继续本次操作。
3. 通过宿主的凭据功能保存连接地址与令牌，供后续会话使用。令牌单独保存，避免写进 `SKILL.md`。令牌失效时使用用户重新复制的接入指令。

## AI 操作顺序

1. 先请求 `GET /v1/status`，用 `deviceInfo.id` 核对设备，再查看版本、连接状态和当前出口。
2. 用 `GET /v1/nodes` / `GET /v1/groups` 拿到 ID，再执行用户要求的操作。多个同名对象需要按 ID 确认。
3. 操作返回后读取状态或对象，核实已应用的结果。切换失败时查看当前出口。遇到 409 时，先查看当前状态，再判断是否重试。
4. 令牌、节点分享链接、二维码原文和订阅地址都可用来访问资源。只在用户要求的范围内读取或分享，避免写进聊天摘要或日志。

## 接口

### 状态和代理

- `GET /v1/status` 获取设备、版本、连接状态、当前所选节点、生效节点和分流配置。规则模式的所有 `PROXY` 连接使用生效节点，单条连接的实际出口见 `GET /v1/connections`。
- `GET /v1/device` 读取当前设备信息，与状态中的 `deviceInfo` 一致。`PATCH /v1/device` 用 `{"displayName":"设备名称"}` 改名，返回更新后的设备信息。按 `id` 区分设备。详见[设备 API](../docs/device-api.md)。
- `PUT /v1/proxy` 用 `{"enabled":true}` 开启代理，用 `{"enabled":false}` 停用并交还系统代理。
- `GET /v1/statistics` 读取实时或上次代理流量。速率单位是字节/秒，总量单位是字节。尚无数据的字段为 null。
- `GET /v1/statistics/history?range=today` 读取此设备的累计和分时流量。范围可用 `today`（默认）、`yesterday`、`last7days`、`last30days` 或 `all`。结果给出设备时区 `timeZone`、范围边界和采样时间（UTC）、累计下载、上传和合计（字节），以及按同一时区分组的 `bins`。每个时段的 `state` 为 `recorded`（包括零流量）、`missing`（无采样）或 `future`（尚未到达）。无采样的用量为 `null`。`recordedSinceUtc` 是设备开始记录的时间。`storageIssue:true` 表示存在历史文件读写问题。
- `GET /v1/connections` 读取当前连接的 ID、来源、目标、协议、规则、策略链、最终出口及上传下载量。用 `DELETE /v1/connections/{id}` 断开指定连接，或按用户请求用 `DELETE /v1/connections` 断开全部。
- `GET /v1/diagnostics/engine` 读取本次运行保留的脱敏内核日志。AI 调用日志在桌面「AI」页单独显示。

### 节点

- `GET /v1/nodes` 列出节点。 `GET /v1/nodes/{id}` 查看一条。`protocol` 为连接协议，`protocolLabel` 为列表显示名称，`lastTestedAtUtc` 为本次运行中所显示测试结果的完成时间，无结果时为 `null`。`groups` 列出所属组的 `id`、`name` 和 `kind`。未分组时为 `[]`。
- `POST /v1/nodes` 用 `{"link":"ss://…","name":"节点名"}` 添加节点。名称可省略。加上 `groupId` 可同时将节点加入手动组。
- `PATCH /v1/nodes/{id}` 用 `{"name":"新名称"}` 或 `{"link":"vless://…"}` 更新，也可同时提供两项。
- `DELETE /v1/nodes/{id}` 删除节点，同时移除组引用。删除正在使用的节点前，先切换出口或停用代理。
- `POST /v1/nodes/{id}/probe` 测试一个节点，`POST /v1/nodes/probe` 测试全部。返回列表，包含每个节点的耗时、出口 IP 或失败原因。HTTPS 响应提供可用地区代码时，`probe.exitRegionCode` 返回该代码，否则为 `null`。
- `POST /v1/nodes/{id}/select` 选择出口。代理已开启时先验证候选，再切换。

### 节点组

- `GET /v1/groups` 列出手动组和订阅组。 `GET /v1/groups/{id}` 读取组成员与订阅额度、剩余流量和到期时间。
- `POST /v1/groups` 用 `{"name":"组名","members":["<NODE_ID>"]}` 创建手动组，或用 `{"subscription":"sub://…"}` 创建订阅组。订阅可用 HTTPS 地址，并可附自定义 `name`。
- `PATCH /v1/groups/{id}` 修改名称、手动组成员集合或订阅地址。更换地址成功后替换成员，原订阅的本机修改随之移除。
- `DELETE /v1/groups/{id}` 删除组。删除订阅组同时移除其导入节点。
- `POST /v1/groups/{id}/refresh` 刷新订阅与额度。 `POST /v1/groups/{id}/probe` 测试组内节点。

### 导入和分享

- `POST /v1/import` 用 `{"link":"…" }` 导入单节点、订阅或 Byway 手动组分享链接。多张二维码用 `{"parts":["<CODE_1>","<CODE_2>"]}` 一次提交同组的所有码。
- `POST /v1/import/shadowrocket` 提交 Shadowrocket 节点导出的原始 JSON 数组。
- `POST /v1/qr/decode` 上传原始图片字节，最大 20 MB。把结果的 `code` 交给导入接口。
- `POST /v1/import/camera` 打开 PC 上的扫码窗口。由现场用户开启相机、选择图片或确认扫码，完成后返回导入结果。
- `GET /v1/nodes/{id}/share` 和 `GET /v1/groups/{id}/share` 返回分享链接与二维码张数。加 `?qr=1` 获取第一张 PNG，依次用 2、3 获取后续图片。

### 配置与授权

- `GET /v1/config` 读取代理例外、固定混合端口和路由模式。`PATCH /v1/config` 可设置 `bypass`、`mixedPort` 和 `mode`（`rule`、`global`、`direct`）。通过 `POST /v1/nodes/{id}/select` 选择规则或全局模式使用的节点。端口占用时选择其他端口，或退出占用程序后重试。模式和端口修改失败会保留当前代理。
- `PATCH /v1/config` 可设置 `captureMode`。`system` 使用 Windows 系统代理，`tun` 使用全流量接管，`manual` 只开本机混合端口供显式指定代理的应用使用。代理当前停用时先保存选择，再用 `PUT /v1/proxy` 开启。`GET /v1/config` 返回已保存选择和 `tunAvailable`，`GET /v1/status` 返回当前实际接管方式及 `mixedEndpoint`，停用时接管方式为 `null`。开启 TUN 要求 Byway 已在 PC 上获得管理员授权。无授权时返回 `403`，由本机用户在配置页发起授权。全流量模式覆盖 TCP、UDP 和 DNS，局域网与 Tailscale 私网保留直连。
- `GET /v1/config/routing` 列出分流配置、格式和当前 `activeId`。`GET /v1/config/routing/{id}` 读取兼容报告。旧 Clash 条目保留导入时的策略组选项，解析出的代理规则统一使用当前节点。仅在需要编辑 Clash 原文时加 `?includeText=1`，原文可能含节点凭据。
- `POST /v1/config/routing/test-rule` 接收 `{"id":"<SHADOWROCKET_ID>","host":"example.com"}`。`id:null` 测试默认配置。结果含 `match.type`、`match.policy`、`match.rule`、`match.lineNumber` 和代理策略使用的 `nodeName`。按配置的规则测试，必要时查询 DNS。
- `POST /v1/config/routing/{id}/rules` 接收 `{"type":"DOMAIN-SUFFIX","value":"example.com","policy":"DIRECT"}`，把规则加到所选 Shadowrocket 配置的 `[Rule]` 段首。支持 `DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`IP-CIDR`、`GEOIP`（`CN`）。IP 规则可指定 `"noResolve":true`。已在段首的等价规则返回 `changed:false`。
- `POST /v1/config/routing/preview` 用 `{"text":"…"}` 预览本地 Shadowrocket 或 Clash 配置，或用 `{"subscription":"https://…"}` 读取 Clash YAML 订阅。Clash 原文最多 2 MB。
- `POST /v1/config/routing` 用同样的来源字段和 `name` 保存。用 `acceptWarnings:true` 确认兼容提示。可提供 `activate:true`、`refreshHours` 和 `selections`。`selections` 的键和值必须来自预览中的策略组及成员。
- Windows 正由 Clash for Windows 提供系统代理且 Byway 代理停用时，`POST /v1/config/routing/migrate-clash/preview` 用 `{}` 读取迁移摘要。确认后 `POST /v1/config/routing/migrate-clash` 提交 `{"revision":"<REVISION>","acceptWarnings":true}`。迁移会保存并选中原配置，保留订阅、实时策略选择、混合端口、模式和系统代理例外。退出 Clash 后，用 `PUT /v1/proxy` 让 Byway 接管。
- `PATCH /v1/config/routing/{id}` 更新名称、原文、订阅地址或刷新间隔。用空订阅地址取消订阅，保留目前保存的原文。默认每 24 小时刷新，间隔 0 小时启用手动刷新，与 GUI 共用刷新结果。
- `POST /v1/config/routing/{id}/refresh` 刷新订阅。下载、解析、内核检查或应用失败时继续使用上一份有效配置。
- `PUT /v1/config/routing/active` 用 `{"id":"<CONFIG_ID>"}` 切换配置，用 `{"id":null}` 回到默认。`DELETE /v1/config/routing/{id}` 删除指定配置。
- `GET /v1/config/shadowrocket` 列出分流配置和当前 `activeId`。`GET /v1/config/shadowrocket/{id}` 读取指定配置的原文和兼容报告。
- `POST /v1/config/shadowrocket/preview` 用 `{"text":"…"}` 预览 UTF-8 `.conf`，最多 128 KB。
- `POST /v1/config/shadowrocket` 用 `{"name":"工作","text":"…"}` 保存新配置。加 `"activate":true` 可同时切换。有兼容提示时先确认，再传 `"acceptWarnings":true`。
- `PATCH /v1/config/shadowrocket/{id}` 修改 `name` 或 `text`。更新原文时也要确认兼容提示。配置正在使用时，更新成功后切换到新规则。
- `PUT /v1/config/shadowrocket/active` 用 `{"id":"<CONFIG_ID>"}` 切换配置，用 `{"id":null}` 切回默认。切换后读取 `activeId`。代理正在运行时，`GET /v1/status` 的 `usesImportedConfiguration` 表示是否在使用导入规则。
- `DELETE /v1/config/shadowrocket/{id}` 删除指定分流配置。删除当前配置会切回默认。
- `GET /v1/settings` 读取窗口、登录启动和代理恢复偏好，以及启动项登记状态。`PATCH /v1/settings` 可设置 `closeToTray`、`sidebarWidth`、`startAtLogin` 和 `resumeProxy`。侧栏宽度 `sidebarWidth` 的范围为 144 到 320 个设备无关像素。登录启动和代理恢复同时开启后，Byway 在 Windows 用户登录时恢复上次明确启用的代理。主动停用代理会清除恢复启用状态。
- `GET /v1/ai` 读取连接地址和局域网监听是否已开启。`lanHostAddress` 提供 mDNS 地址或 `null`，`lanAddresses` 提供局域网 IP 地址列表。使用 `GET /v1/discovery` 查询发现状态，或 `PATCH /v1/discovery` 发送 `{"enabled":false}` 修改发现开关。
- `PUT /v1/ai` 用 `{"lanEnabled":true}` 更新局域网开关。当前版本尚未放行时返回 `403`，由用户在 Byway 的「AI」页打开开关并完成 Windows 授权。关闭用 `{"lanEnabled":false}`。`POST /v1/ai/rotate-token` 更换令牌并返回新值。这些写入必须从 Byway 所在电脑的本机地址调用。

## 私网

在「私网」加入 Tailscale 或 Headscale。Windows 透明访问需要全流量（TUN）。

- `{"provider":"tailscale","relayMode":"tailscaleDefault"}` 跟随 Tailscale 配置。`relayHosts` 可省略或传空数组。
- `relayMode` 传 `strict` 或省略时严格匹配 `relayHosts` 中的 1–16 个域名。Headscale 始终使用严格模式。

| 方法和路径 | 用法 |
| --- | --- |
| `GET /v1/private-network` 或 `GET /v1/private-network/config` | 读取配置、启用意图和内核状态 |
| `PUT /v1/private-network/config` | 提交 `provider`、`relayMode`、严格模式的 `relayHosts`、Headscale 的 HTTPS `controlURL` 和可选的 `deviceName`、`inboundTcpPorts` |
| `POST /v1/private-network/join` | 无正文，发起加入并返回 202。若需要 TUN 或登录，在 Byway 界面完成 |
| `POST /v1/private-network/key` | 向本机回环 API 提交 `{"key":"一次性入网密钥"}`，返回 202 |
| `PUT /v1/private-network/state` | 用 `{"enabled":false}` 暂停，`true` 恢复 |
| `DELETE /v1/private-network/membership` | 清除本机私网身份及设置 |
| `GET /v1/private-network/peers` | 读取内核当前可见设备 |
| `GET /v1/private-network/relays` | 读取 `configuration.relayMode`、`configuration.relayHosts` 和实际下发的 `runtime.relays.hosts` |
| `POST /v1/private-network/probe` | 提交目标设备的 `address`，返回路径、区域、毫秒数和观测时间 |

运行态为 `Running` 且 `runtime.relays.verified = true` 时，私网已经就绪。跟随模式收到协调端清单即满足中继条件。严格模式要求清单与预期一致，`RelayMismatch` 时在协调端修正清单。

入站 TCP 端口默认关闭，用户指定端口后仍受私网访问规则和本机服务鉴权约束。代理端口与 AI API 端口不可加入允许清单。收到回执后通过状态接口确认实际连接。

## 响应

成功读写返回 200，创建返回 201。失败返回 `{"error":"原因"}`。401 表示令牌无效，403 表示来源不允许，404 表示对象或接口不存在，409 表示应用忙或当前状态有冲突，422 表示节点、订阅或其他输入未通过校验。
