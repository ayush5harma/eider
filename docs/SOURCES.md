# Writing a source

A source is a JSON file at a URL. Eider reads it, lists the apps in it and
downloads the IPAs it points to. Two formats are accepted.

Eider does not decrypt anything. A source must only list IPAs you have the
right to distribute.

## AltStore-format source

An object with an `apps` array. Fields Eider reads:

- Source: `name`, `identifier`, `subtitle`, `description`, `iconURL`,
  `headerURL`, `website`, `tintColor`, `news`.
- App: `name` and `bundleIdentifier` (both required), `developerName`,
  `subtitle`, `localizedDescription`, `iconURL`, `tintColor`, `category`,
  `screenshots`, `versions`.
- Version (each entry of `versions`): `version` and `downloadURL` (both
  required), `buildVersion`, `date`, `localizedDescription`, `size`,
  `minOSVersion`, `maxOSVersion`, and the optional `sha256`.

Older sources put `version`, `versionDate`, `versionDescription`,
`downloadURL` and `size` directly on the app. Eider reads that flat form when
an app has no usable `versions`.

Dates are read fastest as `2026-01-15` (midnight UTC) or
`2026-01-15T09:30:00Z` (`.123` milliseconds and a `+05:30` offset are fine).
A zone-less timestamp, a space instead of the `T` or a `+0530` offset are
accepted too, just more slowly.

```json
{
  "name": "Example Source",
  "identifier": "com.example.source",
  "apps": [
    {
      "name": "Example",
      "bundleIdentifier": "com.example.app",
      "versions": [
        {
          "version": "1.2.0",
          "date": "2026-01-15",
          "downloadURL": "https://example.com/Example-1.2.0.ipa",
          "size": 12345678,
          "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
        }
      ]
    }
  ]
}
```

## PlayCover-style list

A JSON array, or an object `{"name": ..., "data": [...]}`, of entries:

```json
[
  {
    "bundleID": "com.example.app",
    "name": "Example",
    "version": "1.2.0",
    "itunesLookup": "https://itunes.apple.com/lookup?bundleId=com.example.app",
    "link": "https://example.com/Example-1.2.0.ipa",
    "checksum": "0000000000000000000000000000000000000000000000000000000000000000"
  }
]
```

`bundleID`, `name`, `version` and `link` are required. `itunesLookup` is
accepted and never fetched. `checksum` is optional.

## One app, several entries

Some sources list the same app once per version (one in use has 17,430
entries for 3,597 bundle ids). Eider merges entries that share a bundle id
within one source into a single app, when the source is read and again when a
saved copy is loaded, so the browse list has one row per app:

- The app's versions are the union of every entry's versions, newest first.
  The same version at the same download URL is listed once; the same version
  at another URL is kept as another download.
- Newest means the highest version number. A dotted number ("1.10", "v2.0",
  "3.8.14 (5)") is compared component by component, so 1.10 is newer than 1.9
  and 1.2 equals 1.2.0. A version that is not one ("8b6e503", "nightly",
  "beta") has no order against another such version and never outranks a
  numbered one, so a commit-hash build is not offered as an update to 3.8.14.
  Ties go to the build number (when both give one), then to the date (a version
  with no date ranks below a dated one), then to the order in the source. Dates
  decide last because sources date their versions unreliably.
- Name, developer, subtitle, description, icon, tint, category and screenshots
  come from the entry carrying the newest version; a field it leaves empty is
  taken from the first other entry that has one. Notes, size, date, sha256 and
  the download URL stay with their own version.
- Entries with different names but one bundle id are still one app.
- Different sources are never merged; the same bundle id in two sources is
  two rows. Merging is not a warning; `eider source add` prints how many
  entries were listed.

## Checksums

`sha256` (AltStore format) and `checksum` (PlayCover list) are optional. When
present and 64 hex characters, Eider compares the downloaded file against it
and refuses a mismatch. Any other value is ignored with a warning, because
lists in the wild put other digests in that field. Publish a SHA-256 whenever
you can; it is the only integrity check a source can offer.

## URL rules

- `https` only. `http` is accepted only for loopback hosts (`localhost`,
  `127.0.0.0/8`, `::1`, checked as real addresses, so `127.evil.example.com`
  is not one), and only for a source you added by a loopback address and the
  items inside it, for local testing. An `https` source cannot point at a
  loopback address, a redirect from `https` to loopback is refused, and a
  deep link never carries one.
- A relative URL (for example `"downloadURL": "ipas/Example.ipa"`) resolves
  against the URL the source was fetched from.
- `file` URLs work only when the source itself was opened from a local file.
- Redirects are held to the same rules.

An entry whose download URL breaks these rules is skipped with a warning; the
rest of the source still loads.

## Bundle ids

A source's `bundleIdentifier` (or `bundleID`) is the name Eider lists the app
under and matches updates by. Any text is accepted: control and invisible
characters are removed, and an entry with an id longer than 255 bytes is
skipped with a warning. Use the id the IPA itself ships, though. Eider installs
the app under the IPA's own `CFBundleIdentifier` and refuses an IPA whose id
differs from the one the source lists, so an id the IPA does not carry (for
example `cypwn.AppCake+.7.2.2`) installs only when the owner passes that IPA's
id with `--bundle-id` (the Bundle id field in the app). On the command line,
`eider install <id>` reads anything with a `/`, a URL scheme or an `.ipa`
ending as a file or an address, so an entry whose id looks like one installs
from the app only.

## What makes an IPA installable

Eider installs an IPA as a Mac app on Apple silicon, so the IPA must:

- be decrypted. Binaries still encrypted with FairPlay are refused; Eider
  cannot and does not decrypt them.
- contain an arm64 slice in its main executable (iOS apps are arm64; an
  x86_64-only or simulator-only build will not install).

Apps that depend on iOS-only hardware or services may install and still not
work. The app compatibility issue template collects what is needed to
investigate.

## Deep links

- `eider://source/<url>` adds the source at `<url>`.
- `eider://install/<url>` starts an install of the IPA at `<url>`.

`<url>` follows the URL rules above, except that `file` URLs and loopback
addresses are never accepted from a link. Percent-encode it if it carries a query string you want
kept.
