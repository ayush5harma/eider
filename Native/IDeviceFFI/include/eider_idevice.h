// Eider's pairing-mode installer: a small C API over idevice (jkcoxson/idevice, MIT),
// implemented in Native/IDeviceFFI/src/lib.rs and shipped as IDeviceFFI.xcframework.
//
// Every call opens its own RemotePairing connection: TCP to host:port, pair-verify with the
// RP pairing file (never pair-setup, so the iPhone never shows a Trust dialog), a TLS-PSK
// tunnel and an RSD handshake. Calls block; run them off the main thread. Each runs on a
// thread of its own with a 16 MB stack, so the caller's stack size does not matter.
//
// On failure a call returns a non-zero EIDER_IDEVICE_ERR_* code and, when out_message is not
// NULL, a message the caller frees with eider_idevice_free_string. Messages never contain
// pairing key material.

#ifndef EIDER_IDEVICE_H
#define EIDER_IDEVICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    EIDER_IDEVICE_OK = 0,
    EIDER_IDEVICE_ERR_INVALID_ARGUMENT = 1,
    /// The pairing file is not an RP pairing file (missing or malformed keys or identifier).
    EIDER_IDEVICE_ERR_PAIRING_FILE = 2,
    /// No TCP connection to host:port (VPN off, wrong address, device asleep or away).
    EIDER_IDEVICE_ERR_UNREACHABLE = 3,
    EIDER_IDEVICE_ERR_TIMEOUT = 4,
    /// The device answered but did not accept the pairing file.
    EIDER_IDEVICE_ERR_PAIRING_REJECTED = 5,
    /// Pairing succeeded but the tunnel or the RSD handshake through it failed.
    EIDER_IDEVICE_ERR_TUNNEL = 6,
    /// AFC or installation_proxy is not offered or did not answer.
    EIDER_IDEVICE_ERR_SERVICE = 7,
    /// The local IPA could not be read.
    EIDER_IDEVICE_ERR_LOCAL_FILE = 8,
    EIDER_IDEVICE_ERR_UPLOAD = 9,
    EIDER_IDEVICE_ERR_INSTALL = 10,
    EIDER_IDEVICE_ERR_UNINSTALL = 11,
    EIDER_IDEVICE_ERR_INTERNAL = 12,
};

enum {
    EIDER_IDEVICE_PHASE_CONNECTING = 0,
    /// done and total are bytes of the IPA sent to PublicStaging.
    EIDER_IDEVICE_PHASE_UPLOADING = 1,
    /// done is installation_proxy's percent complete; total is 100.
    EIDER_IDEVICE_PHASE_INSTALLING = 2,
    EIDER_IDEVICE_PHASE_FINISHED = 3,
};

/// Called on the library's own operation thread while the call blocks.
typedef void (*eider_idevice_progress_cb)(void *context, int32_t phase, int64_t done, int64_t total);

/// Connects, verifies the pairing, opens the tunnel, does the RSD handshake and checks that
/// AFC and installation_proxy are offered. host is an IPv4 or IPv6 literal.
int32_t eider_idevice_check(const char *host, uint16_t port,
                            const uint8_t *pairing, size_t pairing_len,
                            uint32_t timeout_ms, char **out_message);

/// Uploads the IPA to PublicStaging/<bundle_id>.ipa over AFC and installs it with
/// installation_proxy. connect_timeout_ms bounds the TCP connect (then the result is
/// UNREACHABLE) and, separately, pairing, tunnel and RSD (then TIMEOUT). The upload is
/// bounded by 60 s plus 1 s per 256 KiB, the install by 300 s plus 1 s per MiB, so a phone
/// that stops answering ends the call with TIMEOUT instead of blocking it.
int32_t eider_idevice_install(const char *host, uint16_t port,
                              const uint8_t *pairing, size_t pairing_len,
                              uint32_t connect_timeout_ms,
                              const char *ipa_path, const char *bundle_id,
                              eider_idevice_progress_cb progress, void *context,
                              char **out_message);

/// Uninstalls the app with this bundle id through installation_proxy (bounded at 120 s after
/// the tunnel is up).
int32_t eider_idevice_uninstall(const char *host, uint16_t port,
                                const uint8_t *pairing, size_t pairing_len,
                                uint32_t connect_timeout_ms,
                                const char *bundle_id, char **out_message);

void eider_idevice_free_string(char *message);

/// A static string naming this library, the Eider commit its source came from (with
/// "-dirty" if Native/IDeviceFFI had local changes) and the idevice commit.
const char *eider_idevice_version(void);

#ifdef __cplusplus
}
#endif

#endif
