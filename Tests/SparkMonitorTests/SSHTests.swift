import Testing
import Foundation
import Citadel
import Crypto
import NIO
import NIOSSH
@testable import SparkMonitor

private struct TestAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let key: NIOSSHPublicKey
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.password, .publicKey] }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        switch request.request {
        case .password(let password): responsePromise.succeed(password.password == "test-only-secret" ? .success : .failure)
        case .publicKey(let offered): responsePromise.succeed(offered.publicKey == key ? .success : .failure)
        default: responsePromise.succeed(.failure)
        }
    }
}
private struct TestCommand: ExecCommandContext { func terminate() async throws {} }
private final class TestExec: ExecDelegate, @unchecked Sendable {
    func setEnvironmentValue(_ value: String, forKey key: String) async throws {}
    func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext {
        let wire = #"{"inventory":{"hostname":"test","devices":[]}}"# + "\n"
        try outputHandler.stdoutPipe.fileHandleForWriting.write(contentsOf: Data(wire.utf8))
        Task {
            try await Task.sleep(for: .milliseconds(200))
            outputHandler.succeed(exitCode: 0)
        }
        return TestCommand()
    }
}

struct SSHTests {
    @Test @MainActor func realSSHPasswordKeyAndTrust() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyPath = directory.appendingPathComponent("test-key").path
        let keygen = Process(); keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "test-passphrase", "-f", keyPath]
        try keygen.run(); keygen.waitUntilExit(); #expect(keygen.terminationStatus == 0)
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: String(contentsOfFile: keyPath + ".pub"))
        let port = Int.random(in: 42000...58000)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await SSHServer.host(host: "127.0.0.1", port: port, hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
                                              authenticationDelegate: TestAuthentication(key: publicKey), group: group)
        server.enableExec(withDelegate: TestExec())
        var profile = HostProfile(name: "Test", host: "127.0.0.1", port: port, username: "test", authentication: "password")
        var received = false; var fingerprint = ""
        let password = DGXSparkCollector()
        try await password.start(profile: profile, secret: "test-only-secret", trust: { fingerprint = $0; return true }, receive: { received = $0.inventory?.hostname == "test" })
        #expect(received); #expect(fingerprint.count == 43)
        for (secret, accept) in [("wrong-password", true), ("test-only-secret", false)] {
            let invalid = DGXSparkCollector()
            do {
                try await invalid.start(profile: profile, secret: secret, trust: { _ in accept }, receive: { _ in Issue.record("Unauthenticated data accepted") })
                Issue.record("Invalid credential or host key accepted")
            } catch { #expect(!DGXSparkCollector.isNetworkError(error)) }
            await invalid.stop()
        }
        profile.authentication = "key"; profile.keyPath = keyPath
        let key = DGXSparkCollector(); received = false
        try await key.start(profile: profile, secret: "test-passphrase", trust: { $0 == fingerprint }, receive: { received = $0.inventory != nil })
        #expect(received)
        try await server.close(); try await group.shutdownGracefully()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPARK_TEST_HOST"] != nil))
    @MainActor func remoteSparkWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SPARK_TEST_HOST"], let user = env["SPARK_TEST_USER"], let fingerprint = env["SPARK_TEST_FINGERPRINT"] else {
            Issue.record("Real-machine test requires explicit local environment variables."); return
        }
        let profile = HostProfile(name: "Integration", host: host, username: user, keyPath: env["SPARK_TEST_KEY"] ?? "~/.ssh/id_ed25519")
        let collector = DGXSparkCollector()
        var sampleCount = 0
        var coreCount = 0
        try await collector.start(profile: profile, secret: nil, trust: { $0 == fingerprint }, receive: { msg in
            if let snapshot = msg.snapshot {
                sampleCount += 1; coreCount = snapshot.devices["cpu"]?.cores?.count ?? 0
                if sampleCount == 2 { Task { await collector.stop() } }
            }
        })
        #expect(sampleCount == 2); #expect(coreCount == 20)
    }
}
