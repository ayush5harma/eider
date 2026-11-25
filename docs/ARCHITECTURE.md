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
- Catalog parsing is hot (one source in use lists 17,430 apps): dates in the
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
