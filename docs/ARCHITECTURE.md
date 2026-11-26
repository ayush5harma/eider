# Architecture

Eider adds sources (repository JSON), downloads IPAs from them, and installs
each one as an ordinary Mac app on Apple silicon. One Swift package, three
products.

```
Eider.app (Sources/EiderApp)      eider CLI (Sources/eider)
            \                        /
                 EiderKit (Sources/EiderKit)
```

## EiderKit modules (one directory each, one owner each)

| Directory | Holds | Key public names |
|---|---|---|
| `Support/` | paths, hashing, version, process runner | `EiderPaths`, `Hashing`, `EiderVersion` |
| `MachO/` | Mach-O reading and editing in pure Swift | thin to arm64, platform rewrite, add load command, change install name, encryption check |
| `Engine/` | IPA to installed app | `Installer`, `InstallOptions`, `InstallEvent`, `InstallFailure` |
| `Library/` | registry of installed apps, uninstall | `InstalledApp`, `LibraryStore`, `Uninstaller` |
| `Catalog/` | source formats and the source list | `CatalogSource`, `CatalogApp`, `CatalogVersion`, `SourceParser`, `SourceStore` |
| `Downloads/` | fetching IPAs | `DownloadManager`, `DownloadEvent` |
| `Updates/` | installed version against catalog version | `UpdateChecker` |
| `Diagnostics/` | why an installed app did not launch | `LaunchProbe`, `LaunchDiagnosis`, `LaunchClassifier` |

## Rules every module follows

- State lives under `EiderPaths.home`; nothing reads
  `~/Library/Application Support` directly. Tests and scripts set `EIDER_HOME`.
- The install path runs on a Mac with no Xcode and no Command Line Tools.
  Allowed external programs: `/usr/bin/codesign`, `/usr/bin/unzip`,
  `/usr/bin/ditto`, `/usr/bin/open`, `/usr/bin/log`, and `lsregister`.
  Never `lipo`, `vtool`, `otool`, `install_name_tool`, `clang`, `xcrun` or
  `python3`: on a stock Mac those are stubs that ask to install the tools.
- Shims are compiled once by `Scripts/build-shims.sh` (developer machine or
  CI) and found at run time through `EIDER_SHIMS_DIR`, else beside the
  executable (`../share/eider/shims`), else in the app bundle
  (`Contents/Resources/shims`).
- The shims are `libipakeychain` (unless `--no-keychain`), `libipagroups`
  (always), and three linked only when some binary in the bundle links the
  framework each one corrects: `libipagles` (OpenGLES), `libipacallkit`
  (CallKit) and `libipacamera` (AVFoundation). The decision is
  `ShimLinker.shimsToLink`; a dylib path read from an IPA is only compared to
  those fixed framework names, never used to build a path. `libipaneutralised`
  is the empty stand-in for a keychain-fix tweak.
- The app is signed with a fixed sandbox entitlement set plus one thing read
  from the IPA: `com.apple.security.application-groups`. `AppGroups.read`
  takes it from the main executable's own signature
  (`MachOEntitlements`, pure Swift, before conversion rewrites the binary)
  because apps such as iSH read their group id back from their own signature
  and crash on nil without it. Nothing else of the original entitlements is
  copied: `application-identifier`, the team id and keychain groups belong to
  a developer account, and an ad hoc signature that claims them is killed. Each
  group id must be plain letters, digits, `.`, `-`, `_` (at most 255 bytes, at
  most 32 groups, no `..`), because the groups shim turns it into a path; others
  are dropped with an install warning. `libipagroups` still redirects the
  container, since macOS refuses an ad hoc app the real one.
- Nothing from an IPA or a source is trusted: https only (http for loopback
  only for a source added by a loopback address and its items, never from a
  remote source, a redirect from https or an `eider://` link; plus file URLs
  for a local source), archive entries may not escape the extraction
  directory (symlinks are never extracted by unzip: they are recreated after,
  relative and without `..`), sizes are capped on bytes written, encrypted
  binaries are refused, and no code from the IPA runs during install.
- A bundle id is validated by `BundleIdentifier.isValid` wherever it becomes
  a path or a signing input, or names an installed app: an IPA's
  `CFBundleIdentifier`, `--bundle-id`, library.json, and every command whose
  id becomes a path (`uninstall`, `open`, `doctor`, `update`). A source's own
  id (`CatalogIdentifier`) is a label for showing and matching only, as other
  clients treat it: it is cleaned by `DisplayText` and capped at 255 bytes,
  never strictly checked, so it must never be used as one. It is only compared
  (with the IPA's id as `expectedBundleID`, and with installed ids for updates),
  names a download file only when it passes the strict check (otherwise a
  digest stands in, `DownloadManager.fileName`), and is never the installed
  app's id. Names and versions pass through `DisplayText` at the model boundary.
- A bundle at the install destination is replaced only if the library recorded
  it or `force` is set, and the old copy goes to the Trash, never deleted.
- Entries sharing a bundle id and a name within a source are merged into one
  `CatalogApp` (`CatalogMerge`, called by `SourceParser.parse` and when
  `SourceStore` loads a copy saved before merging); a bundle id is not an
  app's identity (tweak sources list many apps under one). `SourcedApp.id` is
  "<source url>|<bundle id>", plus "|<name>" where the source lists several
  names under that id (`SourcedApp.entries(of:)`), so it is unique per source;
  `allApps()` suffixes `#2`, `#3` should a hand-edited file still collide.
  `CatalogSource.mergeRule` records the rule a copy was merged under; one with
  another rule (or none) is refetched at launch and by `eider source refresh`. "Newest version" is one rule, `CatalogVersion.ranksAbove`, used
  by the merged order, installs and `UpdateChecker`: numeric versions by number,
  never a hash or label above a number, date only as a late tie-break
  (docs/SOURCES.md).
- Provenance and update matching. A catalog install or update records an
  optional `InstallOrigin` on the library entry: the source's address and the
  entry id and name as the source lists them. The listed id may differ from the IPA's own
  (an entry listed as "com.kdt.l!vecontainer" installs as
  "com.kdt.livecontainer"), so the origin is the only link back to the entry.
  The strings are data, compared with the catalog and never made into a path.
  The key is absent in entries written before it, and those load unchanged
  (an origin without a name matches the id's only entry, or the entry named like
  the installed app);
  a file or plain-address install has none. `UpdateChecker` takes, per
  installed app, the origin's entry if that source is still added and still
  lists it (id and name); otherwise, for an old entry, the entries with its
  bundle id in the source it recorded; otherwise the entries with its bundle id
  in any source that lists one name under that id (where several apps share an
  id, which of them this is cannot be told, so nothing is offered).
  A known origin is never widened to other sources. The offer is the
  candidate version that `ranksAbove` the rest, only if it is newer than the
  installed version (`AppVersion.isNewer`), and it names the source and entry
  it comes from. `AppOperations.update` installs exactly that version from
  there, keeps the installed options and data, and passes the installed id as
  `replacingBundleID`: an IPA whose final id differs stops before placement,
  so an update can replace the app it was asked to or nothing, never add a
  second one. The CLI (`eider list`, `eider update [--all]`) and the app use
  the same matcher. The app works the list out off the main actor at each
  reload, fetches sources older than six hours in the background at launch,
  runs Update All one app at a time through Activity, and shows the count on
  the Updates sidebar item and the Dock tile (`DockBadge`).
- Catalog parsing is hot (one source in use lists 17,430 entries): dates in the
  common shapes are read by hand (`InternetDate`) before any formatter,
  warning text is built only when a warning is written, and printable ASCII
  skips the Unicode filter. `SourceStore` writes `sources.json` compact and
  keeps the flattened catalog (`allApps()`) until the list changes.
- Errors carry a stable code and a sentence a person can act on. Progress is
  a stream of typed events; the CLI prints them or emits JSON lines, the app
  draws them.
- A launch is judged "running" only after the process has stayed up for
  `LaunchProbe.defaultSettle` (8 s; `--settle` on `open` and `doctor`). The
  `LaunchDiagnosis.Code` strings are a stable contract: add, never rename.
  `LaunchClassifier` is a pure function over log and crash-report lines and
  checks `uncaught_exception` first (an exception line proves the app ran past
  dyld and code signing); it is given the Mach-O file names in the bundle so
  the summary can name the binary whose frame threw.
- No code is copied from Feather, PlayCover or PlayTools (GPL and AGPL); this
  repository is MIT.

## Reference implementation

`legacy/` (`bin/`, `lib/`, `test/`) is the shell installer this project grew from
(`ipa-install-on-mac`). It stays until the Swift engine passes the same
end-to-end checks, and is the specification for anything not written here.
