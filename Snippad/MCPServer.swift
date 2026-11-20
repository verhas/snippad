import AppKit
import Darwin

/// Snippad's MCP server, so agents can use the clipboard history and the
/// .snippad files.
///
/// The running app listens on a Unix domain socket in its Application
/// Support folder, readable by the user only. Agents do not connect to it
/// directly: they start `Snippad --mcp` (MCPBridge), which speaks MCP's stdio
/// transport and relays each line to this socket. Messages are JSON-RPC, one
/// per line, as on stdio.
final class MCPServer: @unchecked Sendable {
    static let shared = MCPServer()

    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Snippad", isDirectory: true)
    static let socketPath = directory.appendingPathComponent("mcp.sock").path

    private let lock = NSLock()
    private var listenFD: Int32 = -1

    func start() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let fd = try Self.listen(at: Self.socketPath)
            lock.withLock { listenFD = fd }
            Thread.detachNewThread { [self] in acceptLoop(fd) }
        } catch {
            NSLog("Snippad could not start its MCP server: %@", "\(error)")
        }
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            defer { listenFD = -1 }
            return listenFD
        }
        guard fd >= 0 else { return }
        close(fd)
        unlink(Self.socketPath)
    }

    // MARK: - Sockets

    struct SocketError: Error, CustomStringConvertible {
        let call: String
        let code = errno
        var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func listen(at path: String) throws -> Int32 {
        guard var addr = address(path) else { throw SocketError(call: "socket path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(call: "socket") }
        // A socket file left by a copy that crashed, or by another copy of
        // the app; the newest one serves.
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); throw SocketError(call: "bind") }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else { close(fd); throw SocketError(call: "listen") }
        return fd
    }

    /// Connects to the app's socket; -1 when nothing listens there.
    static func connectToApp() -> Int32 {
        guard var addr = address(socketPath) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return -1 }
        noSigPipe(fd)
        return fd
    }

    static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`; false once the other end is gone.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return  // closed by stop()
            }
            // The socket file is the user's only, but check the peer anyway.
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            Self.noSigPipe(fd)
            Thread.detachNewThread { Self.serve(fd) }
        }
    }

    /// Reads requests line by line, answers each on the main thread, where
    /// the history and the pasteboard live.
    private static func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                guard !line.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) else { continue }
                let request = Data(line)
                let response = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { MCPHandler.handle(request) }
                }
                if let response, !writeAll(fd, response + Data("\n".utf8)) { return }
            }
        }
    }
}

/// `Snippad --mcp`: MCP's stdio transport, relayed to the running app.
enum MCPBridge {

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var fd = MCPServer.connectToApp()
        if fd < 0 {
            launchApp()
            for _ in 0..<100 where fd < 0 {
                usleep(100_000)
                fd = MCPServer.connectToApp()
            }
        }
        guard fd >= 0 else {
            FileHandle.standardError.write(Data("Snippad is not running and could not be started; its MCP server is part of the app.\n".utf8))
            exit(1)
        }

        let socket = fd
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            pump(from: socket, to: STDOUT_FILENO)
            // The app went away; nothing more can be answered.
            exit(0)
        }
        Thread.detachNewThread {
            pump(from: STDIN_FILENO, to: socket)
            // The agent closed stdin: let the answers still in flight arrive,
            // then stop.
            shutdown(socket, SHUT_WR)
            done.signal()
        }
        done.wait()
        sleep(2)
        exit(0)
    }

    private static func pump(from source: Int32, to target: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(source, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0, MCPServer.writeAll(target, Data(chunk[0..<n])) else { return }
        }
    }

    /// Starts the app this executable belongs to, in the background.
    private static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", Bundle.main.bundleURL.path]
        try? process.run()
        process.waitUntilExit()
    }
}
