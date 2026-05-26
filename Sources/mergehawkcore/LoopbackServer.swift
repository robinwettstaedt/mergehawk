import Darwin
import Foundation
import Network

public enum LoopbackServerError: LocalizedError {
    case portInUse(port: Int)
    case bindFailed(port: Int, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .portInUse(let port):
            "Port \(port) is already in use. Try signing in again in a few seconds."
        case .bindFailed(let port, let underlying):
            "Failed to bind GitHub auth callback port \(port): \(underlying.localizedDescription)"
        }
    }
}

@MainActor
public protocol LoopbackServing: AnyObject {
    func start() throws -> URL
    func waitForCallback(timeout: TimeInterval) async throws -> (code: String, state: String)
    func stop()
}

@MainActor
public final class LoopbackServer: LoopbackServing {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(code: String, state: String), Error>?
    private var pendingResult: (code: String, state: String)?

    public init(port: Int) {
        self.port = UInt16(port)
    }

    public func start() throws -> URL {
        if Self.isPortInUse(Int(port)) {
            throw LoopbackServerError.portInUse(port: Int(port))
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw LoopbackServerError.bindFailed(port: Int(port), underlying: error)
        }

        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handle(connection: connection)
            }
        }
        listener.start(queue: .main)
        return URL(string: "http://127.0.0.1:\(port)/callback")!
    }

    public func waitForCallback(timeout: TimeInterval = 180) async throws -> (code: String, state: String) {
        if let pendingResult {
            self.pendingResult = nil
            stop()
            return pendingResult
        }

        let timeoutTask = Task { @MainActor in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if let continuation {
                continuation.resume(throwing: URLError(.timedOut))
                self.continuation = nil
            }
        }
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
            (code: String, state: String),
            Error
        >) in
            self.continuation = continuation
        }
        timeoutTask.cancel()
        stop()
        return result
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        continuation = nil
        pendingResult = nil
    }

    public nonisolated static func parse(request: String) -> (code: String, state: String)? {
        guard
            let firstLine = request.components(separatedBy: "\r\n").first,
            let range = firstLine.range(of: "GET ")
        else {
            return nil
        }

        let pathPart = firstLine[range.upperBound...].split(separator: " ").first ?? ""
        let components = URLComponents(string: "http://localhost\(pathPart)")
        let code = components?.queryItems?.first(where: { $0.name == "code" })?.value ?? ""
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        return (code, state)
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                    return
                }
                guard let parsed = Self.parse(request: request) else {
                    return
                }

                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\n\r\nSuccess"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
                    connection.cancel()
                    Task { @MainActor in self?.listener?.cancel() }
                })

                if let continuation {
                    continuation.resume(returning: parsed)
                    self.continuation = nil
                } else {
                    self.pendingResult = parsed
                }
            }
        }
    }

    private nonisolated static func isPortInUse(_ port: Int) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            return false
        }
        defer { close(socket) }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                connect(socket, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
