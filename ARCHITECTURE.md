# Byway 技术架构

## 代理内核

Byway 以 sing-box 作为各平台唯一的代理内核。Windows 将当前节点和所选分流配置编译为同一份运行配置。交付顺序和验收范围见 [路线图](ROADMAP.md#近期迭代--windows-单节点分流)。

## 私网接入

iOS 的 VPN 扩展与 Windows 的全流量模式使用 sing-box 内嵌的 Tailscale endpoint。已识别的私网目标优先匹配 endpoint，私网域名由独立的 Tailscale DNS 规则解析。设备身份分别留在 App Group 与 Windows 用户数据目录。

统一的 Go 代码在 Tailscale 数据路径记录协调端 DERP 清单。默认模式原样应用清单，严格模式在清单不符时拒绝私网业务连接。iOS 通过 Libbox 命令桥查询与操作，Windows 通过已有的带令牌的回环内核接口查询与操作。[构建与补丁](Vendor/README.md)

## 当前 iPhone 和 iPad

SwiftUI 主 App 管理界面和设备配置。主 App 与 VPN 扩展通过 App Group 共享配置；扩展使用 Apple Network Extension 接管流量，由 sing-box 执行代理、分流和 DNS。VPN 连接时，扩展接管局域网控制接口。构建与接口见 [README](README.md)。

移动端界面和局域网请求使用同一套配置及节点操作。VPN 连接期间，主 App 将管理请求转发给扩展，由扩展校验和保存配置。扩展把累计流量和按 UTC 记录的采样一起写入共享容器，内核连接和日志由扩展按需返回。

## macOS

- **进程内内核。** 主 App 直接加载与 iPhone 相同的内核绑定。`Scripts/build-core.sh --macos` 在 iOS 与模拟器切片之外追加 macOS 切片，并把 gomobile 的 `Libbox-Macos` 统一重命名为 `Libbox`，两端共用 `import Libbox`。
- **入站与接管。** 内核以本机混合端口入站运行（`EngineInbound.mixed`），不使用 Network Extension。系统代理由用户触发，经 `networksetup` 写入 HTTP、HTTPS 与 SOCKS 三项并请求一次管理员授权，关闭时逐项恢复。未接管时应用可直接使用 `127.0.0.1:7890`。
- **共享实现。** 主 App 复用 iPad 的分栏工作区与 `Shared` 中的节点、订阅、分流、DNS、全局路由和局域网接口；平台差异集中在 `App/PlatformCompat.swift`、`Mac/` 与条件编译的少量入口。
- **配置目录。** macOS 不依赖 App Group，配置写入 `~/Library/Application Support/Byway`。
- **未接入 TUN。** 全流量接管需要签名内核服务或系统扩展，列入后续迭代。

## Linux 热点网关

- 配置生成器复用 Byway 的 Shadowrocket 节点导入器，生成 sing-box 的节点选择器和本机控制 API。DNS 经选中的节点查询 DoH，节点服务器的域名由主机解析。
- NetworkManager 提供热点和 DHCP。网关的防火墙规则只捕获热点接口的包，通过 TProxy 和按标记的路由把 IPv4 TCP、UDP 交给 sing-box。独立的防火墙服务持续阻挡热点接口的直接转发；网关启动后接续已有热点或启用指定的热点配置。 [Linux 网关指南](Linux/README.md)

## Windows 11 x64

- **桌面进程**。C# / .NET 10 LTS 和 WPF 管理节点及托盘。节点配置使用当前用户的 DPAPI 加密保存，通过标准输入传给 sing-box。桌面进程在固定的本机端口转发 HTTP 和 TCP SOCKS5。切换时在独立回环端口启动并探测候选内核，验证后更新固定入口的目标。
- **AI API**。Kestrel 在回环地址提供本机 API，用户启用后另开局域网端口，仅接受同一私有 IPv4 子网的请求。访问令牌与配置一并加密。请求鉴权后进入桌面线程，与界面共用代理和配置操作。令牌更新与局域网开关由本机授权。[Kestrel 端点](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/kestrel/endpoints?view=aspnetcore-10.0)
- **订阅节点组**。订阅地址、节点和本机修改一并加密。客户端读取 HTTPS 订阅并校验各节点，配置写入成功后更新列表。刷新时按服务商提供的原始参数或组内唯一的同名同协议节点复用 ID，再应用本机保存的名称、连接和删除状态。更换订阅地址时用新响应生成成员。[sing-box VMess 配置](https://sing-box.sagernet.org/configuration/outbound/vmess/)
- **订阅信息**。从订阅响应的 `Subscription-Userinfo` 读取流量字节数及 Unix 到期时间，与节点组一起保存。剩余流量按总额度减去上传与下载计算，时间按 Windows 本地时区显示。[响应头字段约定](https://github.com/XTLS/Xray-core/discussions/4877)
- **分流配置**。具名配置及所选 ID 与节点一起加密保存。应用将 Shadowrocket 规则按原顺序转换为 sing-box 路由，Windows 和 iOS 共用内置 `GEOIP,CN` 数据。Windows 内核补丁让 `PROXY` 保留请求域名，即使此前为匹配 IP 规则执行过 DNS 查询。切换时，候选内核用独立回环入口验证所选节点，再更新系统代理和已保存的配置。 [Windows 内核补丁](Vendor/sing-box-preserve-domain.patch) · [sing-box 路由规则](https://sing-box.sagernet.org/configuration/route/rule/)
- **Clash 配置读取**。应用加密保存原文、订阅源和导入时的组内选择。编译规则时保留直连和拒绝，其余规则映射到当前节点。有序 IP 规则控制解析时机，DNS 引导查询与正常查询经回环进入各自的 DNS 规则。 [转换入口](Windows/ClashConfiguration.cs) · [DNS 生成](Windows/ClashDns.cs)
- **扫码与分享**。相机通过 Windows MediaFrameReader 获取图像，二维码在本机解码。节点及订阅以各自的分享链接生成二维码，手动组将节点链接压缩后生成一张或多张 Byway 二维码。[Windows 相机接口](https://learn.microsoft.com/en-us/windows/apps/develop/camera/process-media-frames-with-mediaframereader) · [Shadowsocks 分享链接](https://shadowsocks.org/doc/sip002.html) · [VMess 分享链接](https://github.com/2dust/v2rayn/wiki/Description-of-subscription)
- **系统代理**。通过 WinINet 接管当前用户 LAN 代理，记录原代理及接管前后的设置。独立恢复进程监视客户端和内核，遇到异常退出时检查所有权，再恢复可用的原代理。如果原本机代理已退出，禁用失效的静态代理并保留其它恢复设置。下次启动也会处理上次留下的恢复记录。 [WinINet 连接选项](https://learn.microsoft.com/en-us/windows/win32/api/wininet/ns-wininet-internet_per_conn_optiona)
- **全流量接管**。同一 sing-box 增加双栈 TUN 入站，通过默认物理接口发出代理连接。TUN 使用原生每接口 DNS，进入网卡的端口 53 请求交由 sing-box 解析，保留 Windows 私网解析。代理恢复记录在 TUN 期间临时停用 WinINet 代理。切换前验证实际透明 HTTPS，同一时间只运行一个 Byway TUN，进程退出时由系统回收其接口设置。 [sing-box TUN](https://sing-box.sagernet.org/configuration/inbound/tun/)
- **登录启动**。用户启用后在 HKCU Run 登记版本化安装路径，升级时随应用路径更新。登录命令以托盘状态启动，按保存的偏好和上次启用状态恢复代理。 [Windows 用户登录启动](https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys)
- **桌面配置和统计**。代理例外及关闭窗口偏好与配置一并保存。运行中可以更新代理例外，恢复进程继续使用原系统代理记录。流量统计通过 sing-box 的回环接口获取，接口使用每次启动生成的访问令牌。[WinINet 代理例外](https://learn.microsoft.com/en-us/windows/win32/wininet/enabling-internet-functionality) · [sing-box Clash API](https://sing-box.sagernet.org/configuration/experimental/clash-api/)
- **部署**。Windows x64 自包含包带有固定版本及校验过的 sing-box，由开始菜单启动。验收结果见 [路线图](ROADMAP.md)。

节点、当前分流配置和 AI 操作沿用[项目语义](CONCEPTS.md)。各端适配本机流量入口和运行方式。
