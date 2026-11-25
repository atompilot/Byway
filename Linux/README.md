# Byway Linux 热点网关

连接主机发出的 Wi‑Fi 即可使用 Byway 出口。网关套件适配 Debian / Armbian 的 systemd、NetworkManager 和 iptables，热点使用 `wlan0`，上游可用现有有线连接。

## 配置和启动

使用 .NET 10 构建配置生成器。`byway-gateway-config` 是把发布产物 `Byway.Gateway` 安装到主机后使用的命令名。

```sh
dotnet publish Linux/Byway.Gateway.csproj -c Release -r linux-arm64 \
  --self-contained -p:PublishSingleFile=true -p:InvariantGlobalization=true
```

将 `Byway.Gateway` 安装为 `/usr/local/bin/byway-gateway-config`。将 [sing-box 1.14.4 Linux ARM64](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4) 和 `hotspot-firewall.sh` 安装到 `/usr/local/lib/byway/`。把本目录的三个 `.service` 文件安装到 `/etc/systemd/system/`。网关需要内核支持 TProxy 和策略路由。

准备一个 WPA2 热点配置，默认名称为 `byway-hotspot`。在现有主机上复用热点时，用 `systemctl edit byway-hotspot.service` 设置环境变量 `BYWAY_HOTSPOT_PROFILE` 为实际的 NetworkManager 配置名。热点配置使用 IPv4 共享、禁用 IPv6，并由网关服务在启动时激活。

在主机上以 root 运行以下命令。配置包含节点登录信息和 API 令牌，保存在主机的私有目录。

```sh
umask 077
install -d -m 0700 /etc/byway-hotspot
export BYWAY_API_TOKEN=$(openssl rand -hex 24)
byway-gateway-config /path/to/shadowrocket.json '默认节点名称' > /etc/byway-hotspot/candidate.json
/usr/local/lib/byway/sing-box check -c /etc/byway-hotspot/candidate.json
mv /etc/byway-hotspot/candidate.json /etc/byway-hotspot/config.json
systemctl daemon-reload
systemctl enable --now byway-hotspot-firewall@wlan0.service
systemctl enable --now byway-hotspot.service
```

已有网关更新配置时，先备份 `config.json`。校验并替换文件后执行 `systemctl restart byway-hotspot.service`。已通过 API 切换的节点会保存在 `/var/lib/byway-hotspot/cache.db`。

## 设备信息和名称

网关同时启动设备 API，监听 `127.0.0.1:16418`，可从本机或 SSH 转发访问。它使用与节点 API 相同的令牌。升级已有网关时更新可执行文件和服务文件，执行 `systemctl daemon-reload`，重启 `byway-hotspot.service`。

```sh
curl --noproxy '*' -H "Authorization: Bearer ${BYWAY_API_TOKEN}" http://127.0.0.1:16418/v1/device
curl --noproxy '*' -H "Authorization: Bearer ${BYWAY_API_TOKEN}" -H 'Content-Type: application/json' \
  -X PATCH -d '{"displayName":"书房热点"}' http://127.0.0.1:16418/v1/device
```

`GET /v1/guide` 提供当前 API 说明。`GET /v1/status` 也返回 `deviceInfo`。设备身份和名称保存于网关状态目录，切换节点或更新热点配置时沿用。 [设备 API](../docs/device-api.md)

### 从浏览器管理

使用 `byway-gateway-config device-web-url` 查看管理网页链接。有桌面环境时，`byway-gateway-config open-device-web` 用默认浏览器打开。同一页可复制链接。

要允许同一局域网里的设备访问，在网关执行 `sudo systemctl edit byway-device-api.service`，把下面的地址换成该网关的私有 IPv4 地址。

```ini
[Service]
Environment=BYWAY_LAN_IP=192.168.31.20
```

执行 `sudo systemctl restart byway-device-api.service`。局域网启用后，如系统提供 Avahi 守护进程和 `avahi-publish`（Debian 的 `avahi-daemon`、`avahi-utils`），Byway 会尝试发布独立的 mDNS 地址。发布成功后命令返回 `.local` 链接。用 `device-web-url --ip` 查询备用 IP 链接。可通过 `GET /v1/discovery` 查看状态，或用 `PATCH /v1/discovery` 和 `{"enabled":false}` 关闭发现。清除局域网 IP 设置并重启后恢复本机访问。 [管理网页](../docs/management-web.md)

## 节点控制

API 监听 `127.0.0.1:16417`，通过本机或 SSH 转发访问。请求使用 `Authorization: Bearer <配置中的 secret>`。输出中的节点名带 `node:` 前缀。

| 请求 | 行为 |
| --- | --- |
| `GET /proxies/byway` | 读取当前节点和可选节点 |
| `GET /proxies/<URL 编码的节点名>/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=8000` | 测试候选节点的 HTTPS 连通性 |
| `PUT /proxies/byway`，正文 `{"name":"node:节点名称"}` | 切换节点，新的代理连接使用所选出口 |

可从主机用 `curl -x socks5h://127.0.0.1:16416 https://cloudflare.com/cdn-cgi/trace` 检查实际选中节点的出口 IP。在手机上用同一地址可检查热点出口。主机的有线出口可单独对照。

`systemctl stop byway-hotspot.service` 停止代理，热点维持连接，外网转发被防火墙阻断。若要把热点交回原本的共享上网，继续停止 `byway-hotspot-firewall@wlan0.service`。用 `systemctl disable` 同时取消两个服务的开机启动。
