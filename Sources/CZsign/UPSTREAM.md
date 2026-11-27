# zsign, vendored

- Upstream: https://github.com/zhlynn/zsign (MIT, see `LICENSE` beside this file)
- Commit: `9299685bab7ef99827e06e5dfda93af747386590` (2026-10-20, "fix: fail
  instead of sealing an unreadable file as empty (#413)")
- Vendored on 2026-11-28 for EiderSign (docs/IOS.md).

## What is here

`zsign/` holds only the signing core, copied from upstream `src/`:
`archo`, `bundle`, `macho`, `openssl`, `signing` (`.cpp` and `.h`) and from
`src/common/`: `common.h`, `fs`, `json`, `log`, `mach-o.h`, `sha`, `util`.

Left out, because Eider does not use them:

- `src/zsign.cpp` (the CLI `main`), `src/common/timer.*`
- `src/common/archive.*` and `src/third-party/` (zlib, minizip): EiderInstall
  unpacks and repacks IPAs with ZIPFoundation.
- `src/metadata.*` (icon and metadata extraction)
- `src/certcheck.*` (blocking-socket OCSP and file sniffing): EiderSign builds
  the OCSP request and checks the response in `shim/eider_zsign.cpp` and does
  the HTTP in Swift with URLSession, so the call is asynchronous.
- `build/`, `test/` and the READMEs.

`shim/eider_zsign.cpp` and `include/eider_zsign.h` are Eider's own code (the
C surface Swift calls), not upstream.

## Local changes to upstream files

1. `openssl.cpp`, `signing.cpp`, `common/sha.cpp`: `#include <openssl/...>`
   became `#include <OpenSSL/...>`, the header path of the OpenSSL.xcframework
   (krzyzanowskim/OpenSSL) this package links. The lowercase form only worked
   on a case-insensitive file system.
2. `common/log.h`, `common/log.cpp`: `ZLog::Error` and `ZLog::ErrorV` also keep
   the message in `ZLog::LastError()`, even when printing is off, so the shim
   can return zsign's reason for a failure as a user-facing error.
3. `archo.cpp` (`ZArchO::BuildCodeSignature`): each executable is signed with
   `application-identifier` set to `<prefix>.<its own bundle id>`, where
   `<prefix>` is what precedes the first dot in the profile's value. Upstream
   signs the profile's value verbatim, so a wildcard profile put `TEAM.*` in
   every signature; Xcode writes the concrete identifier, and an app with
   extensions needs one per bundle.

## Known upstream behaviour kept as is

- `ZSignAsset` has no destructor, so each signing leaks its private key and
  certificate (a few KB per call).
- zsign's process-wide state (log level, last error) is why EiderSign
  serialises every call through one actor.
- Change 3 applies to every executable zsign signs with a bundle id,
  including any inside `.xpc` bundles or frameworks; EiderSign's
  explicit-profile check only covers `.app` and `.appex` bundles, the ones
  zsign renames. Executables outside any bundle are signed with an empty
  bundle id and keep the profile's value. Both are rare in iOS apps.

## Updating

Copy the same files from a newer upstream commit, re-apply the three changes
above (each is marked with an `Eider:` comment or is the include path), run
`swift test --filter EiderSign` and the iOS build in docs/IOS.md, and update
the commit line here.
