# Eider for iOS

The owner's request (2026-11-28): "create ios app for eider with same functionality add ceritifcate section where i can add developer or enterprise certficates like feather also take care of ipa installation on device itself".

So: the Mac app's sources, browsing, versions, downloads, library and updates, on iPhone and iPad, plus two things only the device needs. A **Certificates** section holds the user's own signing certificates. **Install** signs an IPA with one of them and installs it on the same device.

## Scope

- **Sources.** Add, remove, refresh, import and export, with the same formats, URL policy and 64 MB cap as the Mac app (docs/SOURCES.md).
- **Browse and search.** The same merge rule as the Mac app: same bundle id AND same normalised name. App detail shows the Version History.
- **Downloads.** Resumable, with hashes checked as on the Mac.
- **Library.**
  - IPAs the user downloaded or imported, from the Files app, the share sheet or "Open in".
  - The apps Eider signed and installed, each with its origin entry (source URL, bundle id, name) so Updates can follow it.
- **Updates.** Origin entry first, then the same bundle id across sources only when that id has a single name. A tab badge, as on the Mac.
- **Certificates.**
  - Each certificate is one `.p12`, its password and one `.mobileprovision`, added together.
  - Shown: name, team, type (development, ad hoc, enterprise), expiry, whether this device is in the profile, and revocation status (OCSP).
  - The password lives in the Keychain, never in a plist or database.
  - One certificate is the default.
- **Signing options.** Bundle id, display name, version, remove `UISupportedDevices`, enable file sharing, and remove the app's URL schemes. Tweak injection is out of scope for now.
- **Install on this device.** See "Installing" below.

Out of scope: Mac-only engine features (Catalyst conversion, shims, Interface Size, diagnostics of launched apps) and tweak injection.

## Modules

All in this repository's Package.swift. iOS 17 is the minimum. Liquid Glass is used on iOS 26 and later, with fallbacks.

| Target | Platforms | What it holds |
|---|---|---|
| `EiderCore` | macOS, iOS | Platform-neutral code moved out of EiderKit: Catalog, Downloads, update matching, version compare, paths, image cache, BrowseIndex/BrowseFilter, SourceListIO. EiderKit depends on it and re-exports it, so the Mac code keeps compiling unchanged. |
| `EiderSign` | macOS, iOS | Signing: the vendored zsign C++ sources (MIT, zhlynn/zsign) built as a C++ target against OpenSSL (krzyzanowskim/OpenSSL, binary xcframework), behind a small Swift API. Also certificate import and inspection (p12, mobileprovision, OCSP). |
| `EiderInstall` | macOS, iOS | Unpack and repack IPAs (ZIPFoundation, MIT), the loopback HTTPS server, the install manifest, and the itms-services hand-off. |
| `Apps/EiderMobile` | iOS | The SwiftUI app: an Xcode project that depends on the three libraries above. |

EiderKit, the `eider` CLI and the Mac app stay macOS-only.

## Installing on the device itself

What we know as of 2026-11-28 (iOS 27.3 on the test iPhone):

- iOS installs an app from an `itms-services://?action=download-manifest&url=<https manifest>` link.
- Feather's fully local mode served the manifest from the device over HTTPS. It used a public wildcard certificate for a domain that resolves to 127.0.0.1 (backloop.dev). That certificate was revoked for key compromise, because its private key was published, and the service closed on 2026-09-04. **Eider does not ship or download anyone's published private key.**
- Feather's semi-local mode depends on a third-party manifest service, and its pairing-file mode needs a computer-made pairing file plus a VPN app. Both have open bug reports on iOS 27.

Eider's method, pending a test on the device:

1. On first use, Eider creates its own root certificate on the device. Its private key never leaves the Keychain. The root is name-constrained to `127.0.0.1` and `localhost`, so even a leaked key could not vouch for any other site.
2. The user installs that root as a profile and turns on full trust once, in Settings > General > About > Certificate Trust Settings.
3. To install an app, Eider:
   - serves the signed IPA and its manifest from `https://127.0.0.1:<port>`, with a leaf certificate issued by that root;
   - opens the itms-services link;
   - keeps the server alive until iOS has fetched the IPA.

If the device test shows that iOS will not accept a user-trusted root for itms-services, the fallback is decided then and recorded here.

## Testing

- **Mac:** `swift build`, then `swift test --filter EiderSign` and `swift test --filter EiderInstall`. Run zsign's output through `codesign -dvvv` and `codesign --verify` as a structural check.
- **iOS libraries:** `xcodebuild -scheme EiderInstall -destination 'generic/platform=iOS' build`. The same works for EiderCore and EiderSign.
- **Device:** the owner's iPhone 17 Pro "Sapphire", iOS 27.3, Developer Mode on, UDID `00008150-0004143802B8401C`.
  - Signing on the Mac uses the owner's development certificate and a wildcard development profile from team `8RA8L783G3` that includes this device.
  - Never commit a certificate, profile, p12 or password. Keep test copies outside the repository.
- **Test apps:** open-source apps from their own releases only, never cracked or paid apps.

## Rules

- **Licences:** no code from Feather, PlayCover or PlayTools (GPL/AGPL); Feather may be read for approach only. zsign (MIT) is vendored with its LICENSE and a note of the upstream commit.
- **Style:** no emojis in code, comments or docs. Comments say why and what was measured.
