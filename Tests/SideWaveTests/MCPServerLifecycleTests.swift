// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
import MCP
import System
@testable import SideWave

@MainActor
final class MCPServerLifecycleTests: XCTestCase {
    func testBundledStdioHelperExitsCleanlyWhenClientOutputCloses() async throws {
        let directory = URL(fileURLWithPath: "/tmp/sw_mcp_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = MCPServerManager(socketPath: directory.appendingPathComponent("sidewave-mcp-dev.sock").path)
        let process = Process()
        let input = Pipe(), output = Pipe()
        defer {
            if process.isRunning { process.terminate() }
            server.stop()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? FileManager.default.removeItem(at: directory)
        }
        await server.start()
        XCTAssertTrue(server.isRunning)
        process.executableURL = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "sidewave-mcp"))
        process.arguments = ["--socket", directory.appendingPathComponent("sidewave-mcp-dev.sock").path]
        var environment = ProcessInfo.processInfo.environment
        for key in ["DYLD_INSERT_LIBRARIES", "XCTestBundlePath", "XCInjectBundleInto", "XCTestConfigurationFilePath"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        let client = MCP.Client(name: "Bundled bridge fixture", version: "1")
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            if process.isRunning { process.terminate() }
            await client.disconnect()
        }
        defer { timeout.cancel() }
        do {
            _ = try await client.connect(transport: StdioTransport(
                input: FileDescriptor(rawValue: output.fileHandleForReading.fileDescriptor),
                output: FileDescriptor(rawValue: input.fileHandleForWriting.fileDescriptor)))
            let response = try await client.listTools()
            XCTAssertTrue(response.tools.contains { $0.name == "speak" })
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
        try output.fileHandleForReading.close()
        try input.fileHandleForWriting.write(contentsOf: Data("{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"tools/list\"}\n".utf8))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(process.isRunning, "A closed output must release the helper")
        if !process.isRunning {
            XCTAssertEqual(process.terminationReason, .exit, "SIGPIPE must not terminate the helper")
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    func testStdioToolsHandshakeAndSuppressionOverPrivateSocket() async throws {
        let path = "/tmp/sidewave_mcp_\(UUID().uuidString).sock"
        let server = MCPServerManager(socketPath: path)
        let tts = TTSService()
        server.ttsService = tts
        server.speechSuppressed = true
        defer { server.stop(); tts.cleanup(); try? FileManager.default.removeItem(atPath: path) }
        await server.start()
        XCTAssertTrue(server.isRunning)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                UnsafeMutableRawPointer(destination).copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        guard connected == 0 else { return }
        let client = MCP.Client(name: "Local regression fixture", version: "1")
        do {
            _ = try await client.connect(transport: StdioTransport(input: FileDescriptor(rawValue: fd), output: FileDescriptor(rawValue: fd)))
            let tools = try await client.listTools()
            XCTAssertTrue(tools.tools.contains { $0.name == "speak" })
            XCTAssertTrue(tools.tools.contains { $0.name == "get_playback_status" })
            let status = try await client.callTool(name: "check_status")
            XCTAssertNotEqual(status.isError, true)
            let speech = try await client.callTool(name: "speak", arguments: ["text": .string("This speech must stay suppressed.")])
            guard case .text(let json, _, _) = speech.content.first else { return XCTFail("Expected a tool response") }
            let payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            XCTAssertEqual(payload?["status"] as? String, "suppressed")
            XCTAssertEqual(payload?["spoken"] as? Bool, false)
            XCTAssertFalse(tts.initializationInFlight)
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func testSecondServerCannotUnlinkTheFirstServersSocket() async throws {
        let path = "/tmp/sidewave_mcp_\(UUID().uuidString).sock"
        let first = MCPServerManager(socketPath: path)
        let second = MCPServerManager(socketPath: path)
        defer { second.stop(); first.stop(); try? FileManager.default.removeItem(atPath: path) }
        await first.start()
        XCTAssertTrue(first.isRunning, first.lastError ?? "Server did not start")
        await second.start()
        XCTAssertFalse(second.isRunning)
        XCTAssertNotNil(second.lastError)
        second.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        await second.start()
        XCTAssertTrue(second.isRunning, second.lastError ?? "Socket was not released")
    }

    func testServerNeverRemovesARegularFileAtItsSocketPath() async throws {
        let path = "/tmp/sidewave_mcp_\(UUID().uuidString).sock"
        let content = Data("preserve".utf8)
        try content.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let server = MCPServerManager(socketPath: path)
        await server.start()
        server.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), content)
    }
}
