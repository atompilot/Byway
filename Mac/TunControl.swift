import Darwin
import Foundation
import Network

/// App 与特权内核进程之间的本机控制通道。
/// 帧格式：4 字节大端长度（令牌 + 载荷）+ 32 字节令牌 + JSON 载荷。
enum TunControl {
    static let tokenLength = 32
    static let maxFrame = 4 << 20

    static func frame(token: String, payload: Data) -> Data {
        let body = Data(token.utf8) + payload
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    static func payload(from frame: Data, token: String) -> Data? {
        guard frame.count > 4, let tokenData = token.data(using: .utf8) else { return nil }
        let declared = Int(UInt32(bigEndian: frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard declared <= maxFrame, frame.count >= 4 + declared else { return nil }
        let body = frame.dropFirst(4)
        guard body.prefix(tokenData.count) == tokenData else { return nil }
        return Data(body.dropFirst(tokenData.count))
    }

    static func declaredLength(_ frame: Data) -> Int? {
        guard frame.count >= 4 else { return nil }
        let value = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Int(UInt32(bigEndian: value))
    }
}

/// 一次请求只允许结束一次。超时、连接失败和对端关闭会竞争同一次 continuation，
/// 重复 resume 会触发 CheckedContinuation 的运行时 fatalError 并直接打死内核进程。
private final class TunReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    /// 返回 true 表示这次调用真正结束了请求，调用方可以继续做收尾动作。
    func resolve(_ result: Result<Data, Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

/// App 侧的一次请求。超时或连接失败即视为内核未响应。
enum TunControlClient {
    static func send(port: UInt16, token: String, payload: Data, timeout: TimeInterval = 15) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "cn.splaz.byway.tun-rpc")
            guard let endpoint = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(throwing: BywayError.message(L10n.text("控制端口无效")))
                return
            }
            let connection = NWConnection(host: .ipv4(.loopback), port: endpoint, using: .tcp)
            let gate = TunReplyGate(continuation)
            let timer = DispatchWorkItem {
                if gate.resolve(.failure(BywayError.message(L10n.text("内核进程未响应")))) {
                    connection.cancel()
                }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)

            func finish(_ result: Result<Data, Error>) {
                guard gate.resolve(result) else { return }
                timer.cancel()
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: TunControl.frame(token: token, payload: payload),
                                    completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) }
                    })
                    receive(connection, head: Data(), on: queue, finish: finish)
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func receive(_ connection: NWConnection, head: Data, on queue: DispatchQueue,
                                finish: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { chunk, _, isComplete, error in
            if let error {
                finish(.failure(error))
                return
            }
            var buffer = head
            if let chunk { buffer.append(chunk) }
            if let length = TunControl.declaredLength(buffer), buffer.count >= 4 + length {
                finish(.success(Data(buffer[4..<(4 + length)])))
                return
            }
            if isComplete {
                finish(.failure(BywayError.message(L10n.text("内核进程已结束"))))
                return
            }
            receive(connection, head: buffer, on: queue, finish: finish)
        }
    }
}

/// 特权进程侧的监听服务：校验令牌，把载荷交给内核运行时处理。
final class TunControlServer: @unchecked Sendable {
    private let listener: NWListener
    private let token: String
    private let queue = DispatchQueue(label: "cn.splaz.byway.tun-control")
    private let handle: @Sendable (Data) async -> Data?
    private let onEvent: @Sendable () -> Void

    init?(port: UInt16, token: String, handle: @escaping @Sendable (Data) async -> Data?,
          onEvent: @escaping @Sendable () -> Void) {
        guard let value = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        // 端口本身就是第二道单实例闸门：允许复用会让两个内核同时绑定同一端口，
        // 谁收到请求取决于内核调度，心跳和指令会随机丢。
        parameters.allowLocalEndpointReuse = false
        guard let listener = try? NWListener(using: parameters, on: value) else { return nil }
        self.listener = listener
        self.token = token
        self.handle = handle
        self.onEvent = onEvent
    }

    func start() {
        listener.stateUpdateHandler = { state in
            FileHandle.standardError.write(Data("listener state: \(state)\n".utf8))
            if case .failed = state { exit(2) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, head: Data())
    }

    private func read(_ connection: NWConnection, head: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = head
            if let chunk { buffer.append(chunk) }
            guard let length = TunControl.declaredLength(buffer) else {
                if isComplete { connection.cancel() }
                else { self.read(connection, head: buffer) }
                return
            }
            guard buffer.count >= 4 + length else {
                if isComplete { connection.cancel() }
                else { self.read(connection, head: buffer) }
                return
            }
            let frame = Data(buffer.prefix(4 + length))
            guard let payload = TunControl.payload(from: frame, token: self.token) else {
                connection.cancel()
                return
            }
            self.onEvent()
            Task {
                let reply = await self.handle(payload)
                self.respond(connection, payload: reply ?? Data())
            }
        }
    }

    private func respond(_ connection: NWConnection, payload: Data) {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
