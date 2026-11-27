import CZsign
import Foundation

/// What the certificate authority's OCSP responder says about a certificate.
public enum RevocationStatus: Sendable, Equatable {
    case good
    case revoked(Date)
    /// No trustworthy answer: offline, no responder, or a response that did
    /// not verify. The reason is worded for the person using the app.
    case unknown(String)
}

extension SigningCertificate {
    /// Asks the OCSP responder named in the certificate. Network-bound and
    /// asynchronous; it never blocks the caller's actor.
    ///
    /// Apple's responders are plain HTTP (http://ocsp.apple.com/...), so on
    /// iOS the app's Info.plist needs an App Transport Security exception
    /// for ocsp.apple.com (NSExceptionAllowsInsecureHTTPLoads); without it
    /// this returns `.unknown`. The response is signature-checked either way.
    public func revocationStatus() async -> RevocationStatus {
        await revocationStatus { url, request in
            var urlRequest = URLRequest(url: url, timeoutInterval: 15)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/ocsp-request", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = request
            let (body, response) = try await URLSession.shared.data(for: urlRequest)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw OCSPHTTPError(statusCode: http.statusCode)
            }
            return body
        }
    }

    /// `send` posts a DER OCSP request to the responder and returns the DER
    /// response; tests pass one that answers without a network.
    func revocationStatus(
        send: @Sendable (_ responder: URL, _ request: Data) async throws -> Data
    ) async -> RevocationStatus {
        guard let issuer = issuerCertificateDER else {
            return .unknown("The certificate's issuer is not known, so its status cannot be checked.")
        }
        let prepared: (url: URL, request: Data)
        switch OCSP.request(leaf: leafCertificateDER, issuer: issuer) {
        case .success(let value): prepared = value
        case .failure(let reason): return .unknown(reason.message)
        }
        let response: Data
        do {
            response = try await send(prepared.url, prepared.request)
        } catch {
            return .unknown("The OCSP responder could not be reached: \(error.localizedDescription)")
        }
        return OCSP.check(response: response, leaf: leafCertificateDER, issuer: issuer)
    }
}

struct OCSPHTTPError: LocalizedError {
    let statusCode: Int
    var errorDescription: String? { "the responder answered HTTP \(statusCode)." }
}

/// Thin wrappers over the shim's OCSP functions, which touch no zsign state
/// and so need not go through the signing actor.
enum OCSP {
    struct Failure: Error {
        let message: String
    }

    static func request(leaf: Data, issuer: Data) -> Result<(url: URL, request: Data), Failure> {
        var requestDER = eider_bytes(bytes: nil, length: 0)
        var urlPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        defer {
            eider_bytes_free(&requestDER)
            eider_string_free(urlPointer)
            eider_string_free(errorPointer)
        }
        let result = leaf.withUnsafeBytes { leafRaw in
            issuer.withUnsafeBytes { issuerRaw in
                eider_ocsp_request(
                    leafRaw.bindMemory(to: UInt8.self).baseAddress, leafRaw.count,
                    issuerRaw.bindMemory(to: UInt8.self).baseAddress, issuerRaw.count,
                    &requestDER, &urlPointer, &errorPointer)
            }
        }
        guard result == 0, let urlPointer else {
            return .failure(Failure(message: errorPointer.map { String(cString: $0) } ?? "The OCSP request could not be built."))
        }
        let urlString = String(cString: urlPointer)
        guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else {
            return .failure(Failure(message: "The certificate names an OCSP responder that is not a web address: \(urlString)"))
        }
        return .success((url, Data(bytes: requestDER.bytes, count: requestDER.length)))
    }

    static func check(response: Data, leaf: Data, issuer: Data) -> RevocationStatus {
        var revokedAt: Int64 = 0
        var errorPointer: UnsafeMutablePointer<CChar>?
        defer { eider_string_free(errorPointer) }
        let status = response.withUnsafeBytes { responseRaw in
            leaf.withUnsafeBytes { leafRaw in
                issuer.withUnsafeBytes { issuerRaw in
                    eider_ocsp_check(
                        responseRaw.bindMemory(to: UInt8.self).baseAddress, responseRaw.count,
                        leafRaw.bindMemory(to: UInt8.self).baseAddress, leafRaw.count,
                        issuerRaw.bindMemory(to: UInt8.self).baseAddress, issuerRaw.count,
                        &revokedAt, &errorPointer)
                }
            }
        }
        switch status {
        case EIDER_OCSP_GOOD:
            return .good
        case EIDER_OCSP_REVOKED:
            return .revoked(Date(timeIntervalSince1970: TimeInterval(revokedAt)))
        default:
            return .unknown(errorPointer.map { String(cString: $0) } ?? "The OCSP response could not be read.")
        }
    }
}
