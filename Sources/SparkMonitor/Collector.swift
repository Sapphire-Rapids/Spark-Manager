import Foundation
import Citadel
import NIO
import NIOSSH
import Crypto

protocol MetricsCollecting: AnyObject {
    @MainActor func start(profile: HostProfile, secret: String?, trust: @escaping @MainActor (String) -> Bool,
                          receive: @escaping @MainActor (CollectorMessage) -> Void) async throws
    @MainActor func stop() async
}

final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let trust: @MainActor (String) -> Bool
    init(_ trust: @escaping @MainActor (String) -> Bool) { self.trust = trust }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let publicString = String(openSSHPublicKey: hostKey)
        let raw = Data(base64Encoded: String(publicString.split(separator: " ")[1]))!
        let fingerprint = Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        Task { @MainActor in
            if trust(fingerprint) { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(MonitorError.message("SSH host key not trusted")) }
        }
    }
}

@MainActor final class SSHPerformanceCollector: MetricsCollecting {
    private var client: SSHClient?
    private var stopped = false
    func start(profile: HostProfile, secret: String?, trust: @escaping @MainActor (String) -> Bool,
               receive: @escaping @MainActor (CollectorMessage) -> Void) async throws {
        let authentication: @Sendable () -> SSHAuthenticationMethod
        if profile.authentication == "password" {
            guard let secret, !secret.isEmpty else { throw MonitorError.message(tr("请输入 SSH 密码。", "Enter the SSH password.")) }
            authentication = { .passwordBased(username: profile.username, password: secret) }
        } else {
            let path = (profile.keyPath as NSString).expandingTildeInPath
            let keyData = try String(contentsOfFile: path, encoding: .utf8)
            let decryption = secret.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            let type = try SSHKeyDetection.detectPrivateKeyType(from: keyData)
            if type == .ed25519 {
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: decryption)
                authentication = { .ed25519(username: profile.username, privateKey: key) }
            } else if type == .rsa {
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyData, decryptionKey: decryption)
                authentication = { .rsa(username: profile.username, privateKey: key) }
            } else {
                throw MonitorError.message(tr("首版支持 OpenSSH Ed25519 和 RSA 私钥。", "This preview supports OpenSSH Ed25519 and RSA private keys."))
            }
        }
        var settings = SSHClientSettings(host: profile.host, port: profile.port, authenticationMethod: authentication,
                                         hostKeyValidator: .custom(HostKeyCheck(trust)))
        settings.connectTimeout = .seconds(15)
        let connection: SSHClient
        do { connection = try await SSHClient.connect(to: settings) }
        catch let error as SSHClientError {
            switch error {
            case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication, .unsupportedPrivateKeyAuthentication:
                throw MonitorError.message(tr("SSH 认证失败。请检查用户名、密码或私钥及其口令。", "SSH authentication failed. Check the username, password, private key and passphrase."))
            default: throw error
            }
        }
        client = connection
        if stopped || Task.isCancelled { await stop(); return }
        do {
            let command: String
            if profile.platform == "windows" {
                let native = try resource("windows-native", extension: "cs")
                let sampler = try resource("windows-collector", extension: "ps1")
                let script = "$ProgressPreference='SilentlyContinue'\nAdd-Type -TypeDefinition @'\n" + native + "\n'@\n" + sampler
                let output = try await connection.executeCommand(Self.powershell("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); [Console]::Write([IO.Path]::GetTempPath())"))
                let directory = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
                let path = directory + "SparkManager-" + UUID().uuidString + ".ps1"
                let sftp = try await connection.openSFTP()
                try await sftp.withFile(filePath: path, flags: [.write, .create, .forceCreate]) { file in
                    try await file.write(ByteBuffer(string: script))
                }
                try await sftp.close()
                let quotedPath = path.replacingOccurrences(of: "'", with: "''")
                // Windows' command-line limit is too short for the sampler.
                // Read the temporary upload into memory and delete it before running.
                command = Self.powershell("$ErrorActionPreference='Stop'; $p='\(quotedPath)'; $s=[IO.File]::ReadAllText($p); Remove-Item -LiteralPath $p; & ([scriptblock]::Create($s))")
            } else {
                let script = try resource("collector", extension: "py")
                let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
                command = "exec python3 -u -c " + quoted
            }
            let stream = try await connection.executeCommandStream(command)
            var buffer = Data()
            var remoteError = ""
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .stdout(let output):
                    buffer.append(contentsOf: output.readableBytesView)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = buffer[..<end]
                        if !line.isEmpty { receive(try JSONDecoder().decode(CollectorMessage.self, from: line)) }
                        buffer.removeSubrange(...end)
                    }
                case .stderr(let output):
                    remoteError += String(decoding: output.readableBytesView, as: UTF8.self)
                    remoteError = String(remoteError.suffix(2048))
                }
            }
            if !remoteError.isEmpty { throw MonitorError.message(remoteError) }
            await stop()
        } catch {
            let requestedStop = stopped || Task.isCancelled
            await stop()
            if !requestedStop { throw error }
        }
    }
    private func resource(_ name: String, extension ext: String) throws -> String {
        let url = Bundle.main.url(forResource: name, withExtension: ext) ?? Bundle.module.url(forResource: name, withExtension: ext)!
        return try String(contentsOf: url, encoding: .utf8)
    }
    static func powershell(_ script: String) -> String {
        "cmd.exe /d /c powershell.exe -NoLogo -NoProfile -NonInteractive -OutputFormat Text -InputFormat Text -EncodedCommand " + ("$global:ProgressPreference='SilentlyContinue'; " + script).data(using: .utf16LittleEndian)!.base64EncodedString()
    }
    func stop() async {
        stopped = true
        if let client { try? await client.close() }
        client = nil
    }
    static func isNetworkError(_ error: Error) -> Bool {
        if error is SSHClientError { return false }
        let text = String(describing: error).lowercased()
        return text.contains("connectionreset") || text.contains("connection reset") || text.contains("connection refused") || text.contains("connecttimeout") || text.contains("ioerror") || text.contains("tcpshutdown") || text.contains("ioonclosedchannel") || text.contains("ssh stream closed")
    }
}
