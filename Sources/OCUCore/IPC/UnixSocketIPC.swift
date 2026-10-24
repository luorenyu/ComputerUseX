import Foundation
import Darwin

public final class UnixSocketIPC: @unchecked Sendable {
    public static var defaultSocketPath: String {
        "/tmp/ocu-\(getuid()).sock"
    }

    private var serverSocketFD: Int32 = -1
    private var isRunning = false
    private let acceptQueue = DispatchQueue(label: "org.opencomputeruse.ipc.accept", qos: .userInteractive)
    private let clientQueue = DispatchQueue(label: "org.opencomputeruse.ipc.client", qos: .userInteractive, attributes: .concurrent)

    public init() {}

    // MARK: - Daemon Socket Server (Runs inside OpenComputerUse.app)

    public func startServer(socketPath: String = UnixSocketIPC.defaultSocketPath) throws {
        stopServer(socketPath: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OCUError(
                code: .ipcError,
                message: "Failed to create AF_UNIX socket (errno=\(errno)).",
                recoveryHint: "Check /tmp permissions."
            )
        }

        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            close(fd)
            throw OCUError(
                code: .ipcError,
                message: "Socket path too long: \(socketPath)",
                recoveryHint: "Use a shorter path under /tmp."
            )
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (idx, ch) in pathBytes.enumerated() {
                rawPtr[idx] = ch
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw OCUError(
                code: .ipcError,
                message: "Failed to bind socket at \(socketPath) (errno=\(errno)).",
                recoveryHint: "Remove stale socket file at \(socketPath)."
            )
        }

        chmod(socketPath, S_IRUSR | S_IWUSR)

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw OCUError(
                code: .ipcError,
                message: "Failed to listen on socket \(socketPath).",
                recoveryHint: "Check system socket resources."
            )
        }

        serverSocketFD = fd
        isRunning = true

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stopServer(socketPath: String = UnixSocketIPC.defaultSocketPath) {
        isRunning = false
        if serverSocketFD >= 0 {
            close(serverSocketFD)
            serverSocketFD = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while isRunning && serverSocketFD >= 0 {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverSocketFD, sockPtr, &clientLen)
                }
            }

            if clientFD < 0 {
                if !isRunning { break }
                continue
            }

            clientQueue.async {
                Self.handleClientConnection(clientFD)
            }
        }
    }

    private static func handleClientConnection(_ fd: Int32) {
        defer { close(fd) }
        var dataBuffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)

        while true {
            let bytesRead = read(fd, &chunk, chunk.count)
            if bytesRead <= 0 { break }
            dataBuffer.append(contentsOf: chunk[0..<bytesRead])
            if chunk[0..<bytesRead].contains(0x0A) { // newline delimiter
                break
            }
        }

        guard !dataBuffer.isEmpty else { return }
        if let newlineIndex = dataBuffer.firstIndex(of: 0x0A) {
            dataBuffer = dataBuffer.subdata(in: 0..<newlineIndex)
        }

        let response: IPCResponse
        if let request = try? JSONDecoder().decode(IPCRequest.self, from: dataBuffer) {
            response = OCUCommandExecutor.shared.execute(request, isDaemonContext: true)
        } else {
            response = IPCResponse(
                id: "invalid",
                ok: false,
                error: OCUError(
                    code: .invalidArguments,
                    message: "Failed to decode IPCRequest JSON.",
                    recoveryHint: "Ensure CLI and OpenComputerUse.app versions match."
                )
            )
        }

        if var respData = try? JSONEncoder().encode(response) {
            respData.append(0x0A)
            _ = respData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return write(fd, base, respData.count)
            }
        }
    }

    // MARK: - Client & Automatic Daemon Routing

    public static func isDaemonReachable(socketPath: String = defaultSocketPath) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (idx, ch) in pathBytes.enumerated() {
                rawPtr[idx] = ch
            }
        }

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return res == 0
    }

    public static func sendRequest(
        _ request: IPCRequest,
        socketPath: String = defaultSocketPath
    ) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OCUError(
                code: .ipcError,
                message: "Could not allocate client socket.",
                recoveryHint: "Fallback to direct execution."
            )
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (idx, ch) in pathBytes.enumerated() {
                rawPtr[idx] = ch
            }
        }

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectRes == 0 else {
            throw OCUError(
                code: .ipcError,
                message: "Daemon socket not connected at \(socketPath).",
                recoveryHint: "Launch OpenComputerUse.app or run in direct mode."
            )
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return write(fd, base, payload.count)
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 32768)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            responseData.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(0x0A) { break }
        }

        if let nl = responseData.firstIndex(of: 0x0A) {
            responseData = responseData.subdata(in: 0..<nl)
        }

        return try JSONDecoder().decode(IPCResponse.self, from: responseData)
    }

    /// Executes request via OpenComputerUse.app daemon if available and permitted,
    /// or executes in-process (inheriting host Terminal/IDE TCC permissions) while
    /// streaming all visual HUD events live to OpenComputerUse.app!
    public static func executeRoutingThroughDaemonIfAvailable(
        _ request: IPCRequest,
        preferDaemon: Bool = true
    ) -> IPCResponse {
        let daemonOnline = isDaemonReachable()

        if preferDaemon && daemonOnline {
            // Check daemon permission status
            if let daemonStatusResp = try? sendRequest(IPCRequest(command: "status")),
               let daemonStatus = daemonStatusResp.status {
                let localAX = PermissionManager.shared.isAccessibilityGranted(prompt: false)
                // If daemon has AX permission (or command is hud_event/hud_demo), run inside daemon directly
                if daemonStatus.accessibilityGranted || !localAX || request.command == "hud_event" {
                    if let resp = try? sendRequest(request) {
                        return resp
                    }
                }
            }

            // Daemon is online for HUD, and local CLI process has inherited TCC permissions from host IDE/Terminal!
            // Bridge all HUD events from local process -> OpenComputerUse.app HUD overlay in real time.
            KillSwitchMonitor.shared.setHUDHandler { event in
                let hudReq = IPCRequest(command: "hud_event", hudEvent: event)
                _ = try? sendRequest(hudReq)
            }
        }

        return OCUCommandExecutor.shared.execute(request, isDaemonContext: daemonOnline)
    }
}
