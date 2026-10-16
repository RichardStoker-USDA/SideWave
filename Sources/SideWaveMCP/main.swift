// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

// SideWaveMCP: bridges an MCP client's stdio to SideWave's Unix domain socket. MCP clients launch
// it as a stdio server; there's no network connection and no permission prompt.

import Foundation

// Turn off stdout buffering, or responses can sit in the buffer while the client waits.
setbuf(stdout, nil)
// A client or app may close its pipe while a response is in flight.
signal(SIGPIPE, SIG_IGN)

// MARK: - Connect to SideWave Socket

func connectToSocket(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= 104 else {
        FileHandle.standardError.write("sidewave-mcp: Socket path is too long\n".data(using: .utf8)!)
        close(fd)
        return nil
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        let raw = UnsafeMutableRawPointer(ptr)
        pathBytes.withUnsafeBufferPointer { buf in
            raw.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
        }
    }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

// MARK: - Main

let userTmp = NSTemporaryDirectory()
let execPath = CommandLine.arguments.first ?? ""

// Same socket rule as the app (MCPServerManager.isDevBuild): a debug build uses the dev socket;
// otherwise the executable path decides, for a helper run by hand.
var isDev: Bool = {
    #if DEBUG
    return true
    #else
    return execPath.contains("SideWave Dev") || execPath.contains("SideWave-Dev")
        || execPath.contains("com.sidewave.app.dev")
    #endif
}()

let preferredName = isDev ? "sidewave-mcp-dev.sock" : "sidewave-mcp.sock"
let fallbackName = isDev ? "sidewave-mcp.sock" : "sidewave-mcp-dev.sock"

let preferredPath = (userTmp as NSString).appendingPathComponent(preferredName)
let fallbackPath = (userTmp as NSString).appendingPathComponent(fallbackName)
let arguments = Array(CommandLine.arguments.dropFirst())
let socketPaths: [String]
if arguments.isEmpty {
    socketPaths = [preferredPath, fallbackPath]
} else if arguments.count == 2, arguments[0] == "--socket", arguments[1].hasPrefix("/") {
    socketPaths = [arguments[1]]
} else {
    FileHandle.standardError.write(Data("Usage: sidewave-mcp [--socket /absolute/path.sock]\n".utf8))
    exit(64)
}

// Connect to SideWave's socket with retries
var socketFD: Int32?
for attempt in 1...5 {
    for path in socketPaths {
        socketFD = connectToSocket(path: path)
        if socketFD != nil { break }
    }
    if socketFD != nil { break }
    
    if attempt < 5 { Thread.sleep(forTimeInterval: 0.5) }
}

guard let fd = socketFD else {
    // The socket is missing both when SideWave isn't running and when it is
    // running with the MCP server off, so name both causes.
    FileHandle.standardError.write(
        "sidewave-mcp: Could not connect to SideWave. Open Settings, enable Advanced view and Experimental Features, then turn on Experimental > MCP Server.\n"
            .data(using: .utf8)!)
    exit(1)
}

// Bridge stdin -> socket (background thread)
DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine(strippingNewline: false) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        let bytes = Array(line.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress! + sent, bytes.count - sent)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { exit(0) }
            sent += n
        }
    }
    // stdin closed: the client exited.
    shutdown(fd, SHUT_RDWR)
    close(fd)
    exit(0)
}

// Bridge socket -> stdout (main thread, blocks until socket closes)
// Use raw write() syscall to STDOUT_FILENO to bypass all buffering.
// FileHandle.write + fflush can still buffer in Foundation's layer.
let bufferSize = 65536
var buffer = [UInt8](repeating: 0, count: bufferSize)
while true {
    let bytesRead = read(fd, &buffer, bufferSize)
    if bytesRead < 0 && errno == EINTR { continue }
    if bytesRead <= 0 { break }
    // Write directly to stdout file descriptor -- no buffering at all
    var written = 0
    while written < bytesRead {
        let n = buffer.withUnsafeBufferPointer { buf in
            write(STDOUT_FILENO, buf.baseAddress! + written, bytesRead - written)
        }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { exit(0) }
        written += n
    }
}

close(fd)
exit(0)
