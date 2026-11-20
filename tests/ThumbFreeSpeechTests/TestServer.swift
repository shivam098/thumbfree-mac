import Foundation
import Network

/// What `TestServer` does with one request.
enum Reply: Sendable {
    /// The file, or the part a Range header asks for (206).
    case normal

    /// Half of what was asked, then the connection is cut.
    case dropHalfway

    /// Half of what was asked, then nothing more (a stalled connection).
    case stallHalfway

    /// HTTP 500.
    case serverError

    /// The whole file with 200, ignoring a Range header (a server that can't resume).
    case ignoreRange
}

/// A local HTTP server (Network.framework, on the loopback interface) serving test bytes for the download tests,
/// misbehaving on request. The C# tests use an HttpListener the same way.
final class TestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ThumbFreeSpeechTests.TestServer")
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var log: [String] = []
    private var reply: @Sendable (Int) -> Reply = { _ in .normal }
    private var connections: [NWConnection] = []
    private var closing = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 10)
        if port == 0 {
            throw URLError(.cannotConnectToHost)
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    /// The reply to request number n (from 1, counting every request).
    var behave: @Sendable (Int) -> Reply {
        get {
            lock.lock()
            defer { lock.unlock() }
            return reply
        }
        set {
            lock.lock()
            reply = newValue
            lock.unlock()
        }
    }

    /// Every request so far as "name range" ("model.bin -", "model.bin bytes=150000-").
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// Serves `bytes` as `name`; returns its URL.
    func add(_ name: String, _ bytes: Data) -> String {
        lock.lock()
        files[name] = bytes
        lock.unlock()
        return "http://127.0.0.1:\(port)/\(name)"
    }

    /// Cuts every connection, the stalled ones too, and stops listening.
    func close() {
        lock.lock()
        closing = true
        let open = connections
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.forceCancel() }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let refuse = closing
        if !refuse {
            connections.append(connection)
        }

        lock.unlock()
        if refuse {
            connection.forceCancel()
            return
        }

        connection.start(queue: queue)
        receive(connection, Data())
    }

    /// Reads until the end of the request's headers.
    private func receive(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, done, error in
            guard let self else { return }
            var head = received
            if let content {
                head.append(content)
            }

            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, String(decoding: head[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, head)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ")
        let target = requestLine.count > 1 ? String(requestLine[1]) : "/"
        let name = String(target.drop { $0 == "/" })
        let rangeLine = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
        let range = rangeLine.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        lock.lock()
        log.append("\(name) \(range ?? "-")")
        let behaviour = reply(log.count)
        let bytes = files[name]
        lock.unlock()

        guard let bytes, behaviour != .serverError else {
            send(connection, bytes == nil ? "404 Not Found" : "500 Internal Server Error", [:], Data(), then: .close)
            return
        }

        var from = 0
        var status = "200 OK"
        var headers: [String: String] = [:]
        if let range, behaviour != .ignoreRange, range.hasPrefix("bytes="), range.hasSuffix("-"),
           let start = Int(range.dropFirst(6).dropLast()) {
            from = start
            if from >= bytes.count {
                send(connection, "416 Range Not Satisfiable", [:], Data(), then: .close)
                return
            }

            status = "206 Partial Content"
            headers["Content-Range"] = "bytes \(from)-\(bytes.count - 1)/\(bytes.count)"
        }

        let length = bytes.count - from
        headers["Content-Length"] = "\(length)"
        let half = behaviour == .dropHalfway || behaviour == .stallHalfway
        let body = bytes.subdata(in: from..<from + (half ? length / 2 : length))
        switch behaviour {
        case .dropHalfway:
            send(connection, status, headers, body, then: .drop)
        case .stallHalfway:
            send(connection, status, headers, body, then: .stall)
        default:
            send(connection, status, headers, body, then: .close)
        }
    }

    private enum After {
        /// Ends the response and closes the connection.
        case close

        /// Cuts the connection 200 ms later: the client reads what was sent first (a reset can discard unread data).
        case drop

        /// Sends nothing more and keeps the connection open until `close`.
        case stall
    }

    private func send(_ connection: NWConnection, _ status: String, _ headers: [String: String], _ body: Data,
                      then after: After) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }

        if headers["Content-Length"] == nil {
            head += "Content-Length: 0\r\n"
        }

        head += "Content-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
        let message = Data(head.utf8) + body
        switch after {
        case .close:
            connection.send(content: message, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        case .drop:
            connection.send(content: message, completion: .contentProcessed { [queue] _ in
                queue.asyncAfter(deadline: .now() + 0.2) { connection.forceCancel() }
            })
        case .stall:
            connection.send(content: message, completion: .contentProcessed { _ in })
        }
    }
}
