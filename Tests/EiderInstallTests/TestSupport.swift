import Foundation
import Security
import XCTest
@testable import EiderInstall

/// A keychain file in a temporary directory with a random password, deleted afterwards.
/// SecKeychainCreate is deprecated but is the one way to get a keychain that is neither the
/// owner's login keychain nor the data-protection keychain (which needs entitlements).
/// It is not added to the user's search list, so nothing else sees it.
final class TemporaryKeychain {
    let directory: URL
    let keychain: SecKeychain

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eider-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("test.keychain-db").path
        let password = UUID().uuidString
        var created: SecKeychain?
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &created)
        guard status == errSecSuccess, let created else {
            throw KeychainStore.Failure(operation: "test keychain create", status: status)
        }
        keychain = created
    }

    var scope: KeychainScope { .file(keychain) }

    func delete() {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Runs a command line tool and returns its combined output and exit status.
@discardableResult
func runTool(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// macOS ships LibreSSL as /usr/bin/openssl; EIDER_OPENSSL points the tests at another build.
var opensslPath: String {
    ProcessInfo.processInfo.environment["EIDER_OPENSSL"] ?? "/usr/bin/openssl"
}

func pem(_ der: Data) -> String {
    let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
}

/// A URLSession that trusts only `root` and checks the host name as usual.
final class PinnedRootDelegate: NSObject, URLSessionDelegate {
    let root: SecCertificate

    init(rootDER: Data) {
        root = SecCertificateCreateWithData(nil, rootDER as CFData)!
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString))
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    static func session(rootDER: Data) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration, delegate: PinnedRootDelegate(rootDER: rootDER),
                          delegateQueue: nil)
    }
}
