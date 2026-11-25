# 查询和命名 Byway 设备

iPhone、iPad、Windows 和 Linux 热点网关使用同一套设备信息字段。接口沿用各端的访问令牌和连接地址。

| 请求 | 结果 |
| --- | --- |
| `GET /v1/device` | 返回当前 Byway 设备的信息 |
| `GET /v1/status` | 通过 `deviceInfo` 返回相同信息。Windows 兼容字段 `device` 仍是字符串，值为 Byway 显示名称 |
| `PATCH /v1/device` | 用 `{"displayName":"书房 iPhone"}` 设置当前设备名称，返回更新后的设备信息 |

请求携带 `Authorization: Bearer <令牌>`。改名请求使用 `Content-Type: application/json`。名称会去除首尾空白，需包含 1 至 80 个 Unicode 字符，且正文中不能包含换行或控制字符。

- `id` 是由 Byway 保存的 UUID。连接地址、访问令牌和显示名称变更时沿用同一个 ID。执行批量修改前，用它核对目标设备。
- `displayName` 由用户在 Byway 内设置。默认显示设备类型加上 ID 的前八位，即界面上的识别码。
- `type` 通常为 `iphone`、`ipad`、`windows` 或 `linux`。系统未报告 iPhone 或 iPad 型号代码的移动环境使用 `ios`。
- `modelIdentifier` 是可选的硬件型号代码或型号名。`osVersion` 和 `appVersion` 分别为系统和 Byway 版本。

移动端 App 与 VPN 扩展共享本机钥匙串里的 ID。将 iOS 备份恢复到另一台设备时，新设备生成自己的 ID。
