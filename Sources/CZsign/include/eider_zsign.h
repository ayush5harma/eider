// The whole C surface EiderSign uses: plain C so Swift imports it without
// C++ interop, on macOS and iOS alike. Everything behind it is zsign (C++)
// and OpenSSL. zsign keeps process-wide state (its log level and last error),
// so callers serialise every call; EiderSign does that through one actor.

#ifndef EIDER_ZSIGN_H
#define EIDER_ZSIGN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bytes allocated by the shim; release with eider_bytes_free.
typedef struct {
    uint8_t *bytes;
    size_t length;
} eider_bytes;

void eider_bytes_free(eider_bytes *value);
void eider_string_free(char *value);

typedef enum {
    EIDER_P12_OK = 0,
    EIDER_P12_MALFORMED = 1,
    EIDER_P12_WRONG_PASSWORD = 2,
    /// The p12 opened but holds no private key with a matching certificate.
    EIDER_P12_NO_IDENTITY = 3,
} eider_p12_status;

/// Opens a PKCS#12 with OpenSSL, the same parser zsign signs with, so a file
/// that passes here also signs. On EIDER_P12_OK, leaf_der holds the
/// certificate paired with the private key and issuer_der its issuer: the
/// Apple WWDR intermediate zsign carries, else a certificate from the p12's
/// own chain, in both cases only one whose key verifies the leaf's
/// signature; issuer_der is empty when there is none. A p12 without a MAC
/// that fails to decrypt is reported as a wrong password.
eider_p12_status eider_p12_read(const uint8_t *p12, size_t p12_length,
                                const char *password,
                                eider_bytes *leaf_der, eider_bytes *issuer_der);

/// Builds a DER OCSP request for leaf (issued by issuer) and returns the
/// responder URL from the leaf's Authority Information Access extension.
/// Returns 0 on success; on failure *error says why (free it).
int eider_ocsp_request(const uint8_t *leaf, size_t leaf_length,
                       const uint8_t *issuer, size_t issuer_length,
                       eider_bytes *request_der, char **responder_url,
                       char **error);

typedef enum {
    EIDER_OCSP_GOOD = 0,
    EIDER_OCSP_REVOKED = 1,
    EIDER_OCSP_UNKNOWN = 2,
} eider_ocsp_status;

/// Checks a DER OCSP response: it must be signed by the issuer or by a
/// responder the issuer delegated to, be current, and name leaf. Returns the
/// status, with *revoked_at (seconds since 1970) set for EIDER_OCSP_REVOKED;
/// EIDER_OCSP_UNKNOWN with *error set when the response cannot be trusted.
eider_ocsp_status eider_ocsp_check(const uint8_t *response, size_t response_length,
                                   const uint8_t *leaf, size_t leaf_length,
                                   const uint8_t *issuer, size_t issuer_length,
                                   int64_t *revoked_at, char **error);

typedef struct {
    /// The unpacked .app folder, signed in place.
    const char *app_path;
    const char *p12_path;
    const char *password;
    /// Its Entitlements are signed into every executable, with
    /// application-identifier rewritten to that bundle's own id.
    const char *profile_path;
    /// NULL or empty keeps the bundle's own value.
    const char *bundle_id;
    const char *display_name;
    const char *version;
    int enable_documents;
    int remove_supported_devices;
} eider_sign_request;

/// Signs every nested bundle inner first, then the app, with a SHA-1 and a
/// SHA-256 CodeDirectory, and writes embedded.mobileprovision. Returns 0 on
/// success; on failure *error holds zsign's last error message (free it).
int eider_sign_app(const eider_sign_request *request, char **error);

#ifdef __cplusplus
}
#endif

#endif
