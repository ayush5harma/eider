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
| `Diagnostics/` | why an installed app did not launch | `LaunchProbe`, `LaunchDiagnosis` |

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
- Nothing from an IPA or a source is trusted: https only (http for loopback,
  plus file URLs), archive entries may not escape the extraction directory,
  sizes are capped, encrypted binaries are refused, and no code from the IPA
  runs during install.
- Errors carry a stable code and a sentence a person can act on. Progress is
  a stream of typed events; the CLI prints them or emits JSON lines, the app
  draws them.
- No code is copied from Feather, PlayCover or PlayTools (GPL and AGPL); this
  repository is MIT.

## Reference implementation

`bin/`, `lib/` and `test/` are the shell installer this project grew from
(`ipa-install-on-mac`). They stay until the Swift engine passes the same
end-to-end checks, and are the specification for anything not written here.
