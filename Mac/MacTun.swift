import Darwin
import Foundation

/// macOS 特权内核进程里的原生 utun 设备。
/// iOS 由 NetworkExtension 提供 TUN，macOS 的内核进程没有隧道扩展，
/// 必须自己开一块 utun 并把文件描述符交给代理内核，由内核按 `auto_route` 接管路由。
enum MacTun {
    /// `SYSPROTO_CONTROL`：PF_SYSTEM 下内核控制通道的协议号。Darwin 头文件里有同名字符串常量，
    /// 但它不是 Swift 可用的 C 常量，这里显式给出数值。
    private static let controlProtocol: Int32 = 2
    /// `AF_SYS_CONTROL`：sockaddr_ctl 的地址族。
    private static let systemControlFamily: UInt8 = 2
    /// `UTUN_OPT_IFNAME`：取内核分配的接口名。
    private static let ifNameOption: Int32 = 2
    /// `CTLIOCGINFO = _IOWR('N', 3, struct ctl_info)`：头文件里是 C 宏，Swift 拿不到，按定义展开。
    private static let getControlInfo: UInt = 0xc0644e03

    /// 打开一块 utun 设备。调用方负责在进程退出时让内核回收描述符。
    static func open() throws -> Int32 {
        let descriptor = socket(PF_SYSTEM, SOCK_DGRAM, controlProtocol)
        guard descriptor >= 0 else {
            throw BywayError.message(L10n.text("无法创建 utun 套接字：{0}", errorText()))
        }

        var info = ctl_info()
        info.ctl_id = 0
        let controlName = "com.apple.net.utun_control"
        withUnsafeMutableBytes(of: &info.ctl_name) { buffer in
            buffer.copyBytes(from: Array(controlName.utf8))
        }
        guard ioctl(descriptor, getControlInfo, &info) == 0 else {
            let message = errorText()
            close(descriptor)
            throw BywayError.message(L10n.text("utun 控制接口不可用（需要 root）：{0}", message))
        }

        var address = sockaddr_ctl()
        address.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        address.sc_family = UInt8(AF_SYSTEM)
        address.ss_sysaddr = UInt16(controlProtocol)
        address.sc_id = info.ctl_id
        // 0 表示让内核选出第一个空闲的 utunN。
        address.sc_unit = 0

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }
        guard connected == 0 else {
            let message = errorText()
            close(descriptor)
            throw BywayError.message(L10n.text("无法连接 utun 设备：{0}", message))
        }

        var nameBuffer = [CChar](repeating: 0, count: 64)
        var length = socklen_t(nameBuffer.count)
        _ = nameBuffer.withUnsafeMutableBytes { buffer in
            getsockopt(descriptor, controlProtocol, ifNameOption, buffer.baseAddress, &length)
        }
        let interface = String(cString: nameBuffer)
        guard !interface.isEmpty else {
            close(descriptor)
            throw BywayError.message(L10n.text("无法取得 utun 接口名"))
        }
        log("utun \(interface) opened (fd \(descriptor))")
        return descriptor
    }

    private static func errorText() -> String {
        String(cString: strerror(errno))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
