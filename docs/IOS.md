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
| `EiderInstall` | macOS, iOS | Unpack and repack IPAs (ZIPFoundation, MIT), the device's own HTTPS server for the IPA, the manifest server URL, and the itms-services hand-off. |
| `Apps/EiderMobile` | iOS | The SwiftUI app: an Xcode project that depends on the three libraries above. |

EiderKit, the `eider` CLI and the Mac app stay macOS-only.

## Installing on the device itself

What we know as of 2026-11-28 (iOS 27.3 on the test iPhone):

- iOS installs an app from an `itms-services://?action=download-manifest&url=<https manifest>` link.
- Feather's fully local mode served the manifest from the device over HTTPS. It used a public wildcard certificate for a domain that resolves to 127.0.0.1 (backloop.dev). That certificate was revoked for key compromise, because its private key was published, and the service closed on 2026-09-04. **Eider does not ship or download anyone's published private key.**
- Feather's semi-local mode depends on a third-party manifest service, and its pairing-file mode needs a computer-made pairing file plus a VPN app. Both have open bug reports on iOS 27.

**Proved on 2026-11-28** on the iPhone 17 Pro, iOS 27.3: an itms-services install succeeds when the HTTPS server's certificate chains to a root the user installed as a profile and turned on in Certificate Trust Settings, even with that root name-constrained (critical nameConstraints permitting only an IP /32, `127.0.0.1/32` and `DNS:localhost`). That run served the manifest and IPA from the Mac at its LAN address 192.168.1.117; the phone fetched the manifest, then HEAD and GET of the IPA over that HTTPS, and the app installed.

**Measured on 2026-11-28, same iPhone: appstored refuses a loopback manifest URL** before it connects at all. The device syslog:

```
appstored: [48A7887] Manifest for UPP: https://127.0.0.1:62744/<token>/manifest.plist clientID: itunesstored
appstored: <ERROR> [48A7887] The manifest URL isn't external: https://127.0.0.1:62744/<token>/manifest.plist
appstored: <ERROR> Could not load download manifest with underlying error: Error Domain=ASDErrorDomain Code=850 "Invalid manifest URL" ... "The manifest URL isn't external"
appstored: alert "Cannot connect to 127.0.0.1"
```

**Measured later on 2026-11-28, same iPhone: the manifest must come from another host; the IPA may come from the iPhone.**

- appstored refuses a manifest served by the iPhone at its own Wi-Fi address too, not only at loopback: `https://192.168.1.50:<port>/...` got the same "The manifest URL isn't external" (ASDErrorDomain 850), shown as "Cannot connect to 192.168.1.50".
- It accepts a manifest from another host whose asset URL points back at the iPhone. The Mac served `https://192.168.1.117:8443/manifest-ext.plist` (certificate from a root the user trusted) with asset url `https://192.168.1.50:61901/<token>/app.ipa`; Eider's server on the iPhone served the IPA at its Wi-Fi address (a connection from the iPhone to itself, which the server accepts), and iTorrent 2.2.0, signed on the phone by Eider with the owner's certificate, installed and launched.

So the rule is: the manifest URL must be external to the device; the asset URL in it need not be. Feather moved to an external manifest host for the same reason. Eider serves only the IPA, from the iPhone's own Wi-Fi/LAN address (never loopback: a third-party report says loopback IPA URLs may stall on iOS 27.2), answered only to the iPhone itself, and takes the manifest from a **manifest server** the owner runs on another computer.

### The manifest server

An HTTPS endpoint on another host, set once in Settings > Install on this iPhone as a base URL such as `https://<host>/eider/manifest/<secret>.plist`. The path carries a secret, so the app keeps the URL in the Keychain (this device only, after first unlock) and shows it masked (`https://<host>:<port>/••••.plist`), with Paste, Save, Edit and Clear. Eider refuses a base that is not https, has a fragment, or names this iPhone (loopback, `localhost` or one of its own addresses), since appstored would refuse it.

For each install Eider opens

```
itms-services://?action=download-manifest&url=<percent-encoded manifest URL>
manifest URL = <base>?bundle=<id>&version=<v>&title=<t>&url=<ipa url>
ipa url      = https://<wifi ip>:<port>/<32 lowercase hex token>/app.ipa
```

with each query value percent-encoded (RFC 3986 unreserved characters only), and `&` instead of `?` when the base already has a query. The manifest server answers with the usual manifest plist (`InstallManifest` in `ManifestServer.swift`): one item, one `software-package` asset whose url is `url`, and metadata `bundle-identifier`, `bundle-version`, `kind` = `software`, `title`. It needs no copy of the IPA. Its certificate must be trusted by the iPhone (a public one, or a root the user installed and trusted). A manifest server that refuses anything but an IPA URL of exactly that shape, on a private address, is fine: Eider's own URLs always have it.

Readiness asks the manifest server first: a GET of the base with a made-up but valid-looking query (`bundle=dev.eider.reachability-check`, an IPA URL of the right shape). 200 or 400 counts as answering; any other status (a wrong secret gives 404 on most servers) or no connection is "Manifest Server Not Answering".

One trap: OpenSSL treats a leaf whose subject CN looks like a host or IP as a DNS name and fails the name constraints ("permitted subtree violation"). The leaf's CN is therefore "Eider local server", and the names go only in subjectAltName.

Eider's method, built in `EiderInstall`:

1. **Root.** On first use `LocalRootAuthority` creates a P-256 key in the Keychain (this device only, never exported) and a self-signed root, subject "Eider Local Install (<8 hex chars>)": CA:TRUE pathlen 0 critical, keyUsage keyCertSign + cRLSign, critical nameConstraints permitting only IP `127.0.0.1/32`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10` and DNS `localhost`. Even a leaked key could not vouch for a public site. A root without the private ranges (made before 2026-11-28 for loopback only) counts as not set up (`hasOutdatedRoot()` tells the app), and the next profile download replaces it.
2. **Trust, once.** `LocalInstaller.openProfileInstall()` serves the root as an unsigned `.mobileconfig` (`com.apple.security.root`, display name "Eider Local Install") from a plain-HTTP loopback listener at `http://127.0.0.1:<port>/root.mobileconfig`, since Safari must fetch it before the root is trusted (Safari taking a loopback profile URL is not yet verified on the device). The user installs the profile and turns on full trust in Settings > General > About > Certificate Trust Settings. `status()` reports `.notSetUp`, `.needsWiFi`, `.needsTrust`, `.unreachable` (no connection at all, most likely Local Network off) or `.ready` (the app adds the manifest server's two states in front: none set, or not answering); `.ready` means a URLSession with the default system trust (no delegate) reached the app's own HTTPS server at the Wi-Fi address, the same address and trust appstored uses. The probe is also what raises iOS's Local Network prompt (`NSLocalNetworkUsageDescription`), during setup rather than mid-install.
3. **Server certificate.** A leaf issued by the root: CN "Eider local server", SAN IP `127.0.0.1`, the current Wi-Fi address and DNS `localhost`, EKU serverAuth, 300 days (iOS refuses more than 825 for a user-trusted root), re-issued when under 30 days remain, the root changed, or the Wi-Fi address is not in its SAN. It and its key sit in the Keychain and are used as a `SecIdentity` by Network.framework TLS.
4. **Install.** `LocalInstaller.install(ipa:bundleID:version:title:manifestBase:)`:
   - picks the address with `LocalNetwork.installAddress()`: an up, non-loopback IPv4 address in one of the private ranges, en0 (Wi-Fi) first, then the hotspot bridge (172.20.10.x) and other interfaces; without one it throws "Connect to Wi-Fi to install: iOS will not take an install link served from this iPhone's internal address.";
   - serves only `/<token>/app.ipa` (GET, HEAD, single byte ranges) from an `NWListener` bound to that address, on a random port, with a random 128-bit token per install; anything else, the old `/<token>/manifest.plist` included, is a 404. Every connection whose remote address is not loopback or one of the iPhone's own interface addresses (getifaddrs, per connection) is cancelled before a byte is read, so nothing else on the Wi-Fi gets an answer;
   - opens the itms-services link to the manifest server's URL for that IPA (above);
   - keeps the app alive with a background task, reports progress ("manifest fetched" when iOS first asks for the IPA, since the manifest is no longer Eider's to see), and reports "handed to iOS" once every byte of the IPA was served; the server stops 10 s later, or after 15 minutes without that;
   - logs each accepted and refused connection and each request to the unified log (subsystem `io.github.ayush5harma.EideriOS`, category `install`; the token stays private), so the device syslog shows the flow.
5. **Signing in between.** `LocalInstaller.prepareSignedIPA(from:sign:)` unpacks the IPA, calls the signer on `Payload/<name>.app` and repacks it uncompressed, keeping permissions and symlinks. Entries with absolute paths, `..` or symlinks out of the work directory are refused. A 99.8 MB IPA packed in 0.39 s and unpacked in 0.5 s on the Mac (debug build, 2026-11-28; `EIDER_TIMING=1 swift test --filter IPAArchiveTimingTests`); the device is not measured yet.

The parts are tested on the Mac (`swift test --filter EiderInstall`), where the Mac's own LAN address stands in for the iPhone's and the test plays the manifest server's part from the URL's query; a connection from another machine is simulated by telling the server that only loopback is its own. The whole flow with the manifest server set inside the app on the device is still to be run (the measured install above used a hand-written manifest on the Mac).

The app's setup lists three steps in order: 1) add the manifest server, 2) install Eider's certificate (the profile), 3) trust it; then Check Again. Ready means all three are in place.

It opens Settings through the Settings URL scheme (Eider is sideloaded; `openSettingsURLString` only opens Eider's own page), trying candidates in order, stopping at the first `open` that returns true and logging which. Measured on iOS 27.3, 2026-11-28, by opening each URL in Settings:

| URL | Lands on |
|---|---|
| `prefs:root=General&path=About/CERT_TRUST_SETTINGS` | Certificate Trust Settings |
| `settings-navigation://com.apple.Settings.General/About/CERT_TRUST_SETTINGS` | Certificate Trust Settings |
| `App-prefs:root=General&path=About/CERT_TRUST_SETTINGS` | the Apps page (wrong) |
| `App-prefs:General&path=About/CERT_TRUST_SETTINGS` | the Apps page (wrong) |
| `App-prefs:` | the Settings root, "Profile Downloaded" at the top after Safari downloaded a profile |

So the trust step tries `prefs:root=General&path=About/CERT_TRUST_SETTINGS`, then `settings-navigation://com.apple.Settings.General/About/CERT_TRUST_SETTINGS`, then `App-prefs:`; the profile step tries `App-prefs:`, then `prefs:root=General&path=ManagedConfigurationList` (not measured). The written path stays beside each button in case a later iOS moves a page.

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
