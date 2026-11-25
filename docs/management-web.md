# 局域网管理网页

打开 Byway 显示的管理网页链接，输入目标设备的访问令牌。可查看设备名称、识别码、系统和 Byway 版本、代理状态、当前节点和分流配置，也可修改 Byway 设备名称。

- **iPhone 和 iPad** 在「AI 控制」开启「允许局域网控制」。地址就绪后可复制局域网 IP 链接。VPN 连接时可用本机默认浏览器打开，设备锁屏后其他设备也可继续访问。VPN 断开时，其他设备仍可在 Byway 保持前台期间访问。
- **Windows** 在「AI」页点击「打开管理网页」或「复制网页链接」。关闭局域网时使用本机地址。开启局域网且地址就绪后使用首选地址。
- **Linux** 用 `byway-gateway-config device-web-url` 查看地址，有桌面环境时可用 `open-device-web` 调用默认浏览器。在网页中可复制链接。网关可通过 `BYWAY_LAN_IP` 显式开启同网段访问。 [Linux 设置](../Linux/README.md)

开启局域网后默认允许发现。Byway 用设备 ID 发布独立网页服务。iPhone、iPad 和 Linux 发布 `byway-<设备 ID 前 12 位>.local`。Windows 使用能解析到当前局域网 IP 的系统 `.local` 主机名，Byway 服务仍由设备 ID 区分。记录发布成功时打开与复制都优先用 mDNS 链接。关闭发现或发布不可用时使用局域网 IP。关闭局域网后撤下 Byway 的广播。接收端若解析不了 `.local`，可用备用 IP 链接。

`GET /v1/discovery` 读取 `enabled`、`status`、`mdnsUrl` 和 `ipUrl`，地址未就绪时省略或返回空值。`PATCH /v1/discovery` 用 `{"enabled":false}` 或 `{"enabled":true}` 修改发现偏好。这些 API 沿用设备的访问令牌。登录网页后可在「局域网发现」中查看和修改开关。状态值为 `off`（关闭）、`waiting`（等待局域网）、`publishing`（发布中）、`published`（已发布）或 `unavailable`（不可用）。

链接只包含地址。网页在当前标签页内使用访问令牌，刷新整页后需要重新输入。
