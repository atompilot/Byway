# Byway iPhone 和 iPad API

在「AI 控制」开启局域网访问，从同一 Wi‑Fi 连接页面显示的地址。请求携带 `Authorization: Bearer <访问令牌>`，带正文的请求使用 `Content-Type: application/json`。VPN 断开时由前台 App 接收请求，连接后由 VPN 扩展接收。

## 私网

同一设备使用一个私网。使用原有 API 令牌。通过 `relayMode` 设置 Byway 如何使用协调服务下发的 DERP 清单。

- `{"provider":"tailscale","relayMode":"tailscaleDefault"}` 跟随 Tailscale 配置。`relayHosts` 可省略或传空数组。
- `relayMode` 传 `strict` 或省略时严格匹配 `relayHosts` 中的 1–16 个域名。Headscale 始终使用严格模式。

| 方法和路径 | 用法 |
| --- | --- |
| `GET /v1/private-network` 或 `GET /v1/private-network/config` | 读取配置、启用意图和内核状态 |
| `PUT /v1/private-network/config` | 提交 `provider`、`relayMode`、严格模式的 `relayHosts`、Headscale 的 HTTPS `controlURL` 及可选的 `deviceName` |
| `POST /v1/private-network/join` | 无正文，发起加入并返回 202。在设备上授权 VPN 和登录，随后回读状态 |
| `PUT /v1/private-network/state` | 用 `{"enabled":false}` 暂停，`true` 恢复 |
| `DELETE /v1/private-network/membership` | 清除本机私网身份及设置 |
| `GET /v1/private-network/peers` | 读取内核当前可见设备 |
| `GET /v1/private-network/relays` | 读取 `configuration.relayMode`、`configuration.relayHosts` 和实际下发的 `runtime.relays.hosts` |
| `POST /v1/private-network/probe` | 用 `{"address":"100.83.4.12"}` 探测已知设备，返回路径、区域、毫秒数和观测时间 |

入网密钥和登录链接在设备内处理。运行态为 `Running` 且 `runtime.relays.verified = true` 时，私网已经就绪。跟随模式收到协调端清单即满足中继条件。严格模式要求清单与预期一致，`RelayMismatch` 时在协调端修正清单。

在「AI 控制 → 管理网页」可用默认浏览器打开或复制网页链接。用 `GET /v1/discovery` 查询局域网发现状态，或 `PATCH /v1/discovery` 发送 `{"enabled":false}` 修改发现开关。 [管理网页](management-web.md)

## 代理与节点

| 方法和路径 | 用法 |
| --- | --- |
| `GET /v1/guide` | 读取此指南 |
| `GET /v1/status` | 读取设备信息、实际 VPN 状态、当前节点和生效配置 |
| `GET /v1/device` | 查询当前设备信息，包含用来区分同款设备的 ID |
| `PATCH /v1/device` | 用 `{"displayName":"设备名称"}` 改名，返回更新后的设备信息。详见[设备 API](device-api.md) |
| `PUT /v1/proxy` | 用 `{"enabled":true}` 请求连接，或用 `{"enabled":false}` 请求断开。收到回执后通过状态接口确认。初次设置 VPN 需用户在设备上授权 |
| `GET /v1/nodes`，`GET /v1/nodes/{id}` | 查看节点的名称、主机和端口 |
| `POST /v1/nodes`，`PATCH /v1/nodes/{id}` | 通过 `link` 和可选的 `name` 新建或更新节点 |
| `DELETE /v1/nodes/{id}` | 删除节点 |
| `POST /v1/nodes/{id}/probe`，`POST /v1/nodes/{id}/select` | 测试节点或切换到该节点。VPN 连接或断开时均可测试，连接期间切换前会先测试 |
| `POST /v1/import` | 用 `link` 导入单节点、订阅或整组分享链接，用 `text` 导入节点列表、Base64 列表或 Shadowrocket 节点 JSON，用 `parts` 一次提交整组分段码 |
| `GET /v1/groups` | 列出手动组和订阅组。通过 `PUT /v1/routing` 修改手动组 |
| `GET /v1/nodes/{id}/share`，`GET /v1/groups/{id}/share` | 返回分享链接 `link` 和二维码内容 `parts` |

节点导入结果包含解析数量 `parsed`、跳过数量 `skipped`、实际新增数量 `added` 和本次导入涉及的 `nodeIDs`。若节点已存在，`nodeIDs` 使用已保存的 ID。订阅导入返回订阅及成员 ID。

支持 TCP / RAW / WebSocket VLESS、TCP / WebSocket VMess、Shadowsocks、SOCKS5。REALITY 节点继续使用其支持的 TCP 配置。分享接口会返回含访问凭据的链接，请在用户要求时调用。

## 订阅与分流

| 方法和路径 | 用法 |
| --- | --- |
| `GET /v1/subscriptions`，`GET /v1/subscriptions/{id}` | 查看订阅节点、额度、剩余流量及到期时间 |
| `POST /v1/subscriptions` | 用 `{"link":"https://…","name":"可选名称"}` 导入 HTTPS 或 `sub://` 订阅 |
| `PATCH /v1/subscriptions/{id}` | 用 `name` 改名，或用 `link` 更换地址 |
| `POST /v1/subscriptions/{id}/refresh` | 刷新节点与额度，保留本机编辑和删除 |
| `DELETE /v1/subscriptions/{id}` | 删除订阅及其节点 |
| `GET /v1/subscriptions/{id}/share` | 返回订阅分享链接和二维码内容 |
| `GET /v1/config/routing` | 列出具名分流配置与其 `activeID` |
| `POST /v1/config/routing` | 用 `name`、`text`、`acceptWarnings` 保存配置。传 `activate:true` 同时启用 |
| `GET /v1/config/routing/{id}`，`PATCH /v1/config/routing/{id}` | 读取原文，或修改名称与原文。修改原文时用 `acceptWarnings` 确认兼容提示 |
| `PUT /v1/config/routing/active` | 用 `{"id":"<UUID>"}` 启用某份配置，或用 `{"useDefault":true}` 恢复默认分流 |
| `DELETE /v1/config/routing/{id}` | 删除配置，删除当前配置时恢复默认分流 |
| `POST /v1/config/routing/test-rule` | 用 `host` 测试域名或 IP，可用 `port` 匹配目标端口规则。用 `id` 指定配置，未给 `id` 时测试默认分流 |
| `POST /v1/config/routing/{id}/rules` | 用 `type`、`value`、`policy`、可选 `noResolve` 在 Shadowrocket 的 `[Rule]` 段首添加规则 |
| `GET /v1/config`，`PATCH /v1/config` | 读取或修改默认分流的 `defaultRoute`、`dnsServer`、`bypassPrivateNetworks` 和 `directDomains` |
| `GET /v1/config/dns`，`PUT /v1/config/dns` | 查看或用 `{"dnsSettings":{…}}` 更新加密 DNS 设置 |
| `GET /v1/routing`，`PUT /v1/routing` | 查看或用 `{"globalRouting":{…}}` 更新路由模式、节点组、场景和故障切换 |

`/v1/config/shadowrocket` 原有接口仍可预览、保存和启停当前导入配置。导入前可用 `POST /v1/config/shadowrocket/preview` 提交 `{"text":"…"}` 查看兼容提示。

分流支持 Shadowrocket `.conf` 和 Clash YAML 规则模式。Clash 的手选组按文件中的默认成员解释，非直连策略使用当前 Byway 节点。依赖外部策略提供者的配置会明确报错。测速和测试规则分别测量节点出口和配置匹配，规则测试会在 IP 规则需要时使用设备当前的解析结果。

## 流量与诊断

| 方法和路径 | 用法 |
| --- | --- |
| `GET /v1/statistics` | 读取本次和累计流量 |
| `GET /v1/statistics/history?range=today` | 读取分时记录。可选择 `today`、`yesterday`、`last7days`、`last30days` 或 `all` |
| `GET /v1/connections` | 读取活跃连接及来源、目标、命中规则、出口和流量 |
| `DELETE /v1/connections/{id}`，`DELETE /v1/connections` | 断开单条或全部活跃连接 |
| `GET /v1/diagnostics/engine` | 读取脱敏的当前 VPN 内核日志 |
| `GET /v1/diagnostics/api-calls` | 读取最近 200 条局域网 API 调用的时间、方法、路径、状态和耗时 |

流量单位为字节。日期字段为自 2001-01-01 00:00:00 UTC 起的秒数。历史按设备系统时区分组，`missing` 表示无采样，`future` 表示未到达，实际零流量会作为采样记录保留。
