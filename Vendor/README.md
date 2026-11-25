# 代理内核

- 上游源码为 [SagerNet/sing-box v1.14.4](https://github.com/SagerNet/sing-box/tree/v1.14.4)。
- `byway_control.go` 是 Byway 增加的 Libbox 绑定，使用上游已启动的代理实例读回选择、切换节点、查询隧道流量和执行 HTTPS 延迟与带宽测试。
- `byway_dns.go` 使用 sing-box 的 HTTPS DNS 传输，通过当前出口探测并选择服务器。构建脚本会运行 `byway_dns_test.go`，验证负答复和故障切换行为。
- [sing-box.LICENSE](sing-box.LICENSE) 保存上游的 GPL-3.0-or-later 许可与衍生项目命名声明。[GPL 正文](../LICENSE)
- `byway-tailscale.patch` 在固定的 sing-box 版本接入私网状态与路由守卫，`byway-tailscale-map.patch` 对同一版本锁定的 [Tailscale 依赖](https://github.com/SagerNet/tailscale/tree/79c1732442a9) 接入协调端 DERP 清单。默认模式记录并原样使用该清单，严格模式校验后使用。构建时修改隔离的源码副本。[Tailscale 许可证](tailscale.LICENSE)
- `byway_private_endpoint.go` 维护中继校验及真实设备状态。Libbox 和回环控制接口分别供 iOS 和 Windows 使用。iOS 内核构建运行 DERP 清单和现有连接的回归用例。
- 从根目录执行 `./Scripts/build-core.sh` 生成对应的 iOS 与 iOS Simulator XCFramework。生成物保留在本机的 `Vendor/`，Git 保存构建入口和对应的 Byway 绑定源码。
