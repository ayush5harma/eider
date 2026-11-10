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
rest of the source still loads. An entry whose bundle id is not a plain
reverse-DNS name (dot-separated letters, digits, `-` and `_`) is skipped the
same way.

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
