# Contributing to Eider

## Build and test

Requires macOS 14 or later, Apple silicon, and a Swift toolchain (Xcode or
the Command Line Tools).

```
swift build
swift test
Scripts/build-shims.sh      # compiles the shims into build/shims, when present
Scripts/make-app.sh         # assembles and ad hoc signs build/Eider.app
```

`Scripts/make-app.sh --configuration debug` builds a debug bundle.
`Scripts/release.sh <version>` builds release archives locally; it never
tags, pushes or publishes. Tests and scripts set `EIDER_HOME` so nothing
touches your real `~/Library/Application Support/Eider`.

## Where code goes

Each EiderKit module is one directory with one owner. The table is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), together with the rules every
module follows (allowed external programs, untrusted input, typed errors).
Read it before adding a file. Changes that cross modules belong in one pull
request only when they must.

## No code from GPL or AGPL projects

Eider is MIT licensed. Do not copy, translate or closely paraphrase code from
Feather, PlayCover, PlayTools, AltStore or SideStore, or from anything
derived from them. Their licences (GPL and AGPL) are incompatible with this
repository. Public file formats and documented behaviour are fine to
implement from the specification; say in the pull request where your
understanding came from.

## Commits and pull requests

- Commit message: `<type>: <why>`, with types such as `feat`, `fix`,
  `refactor`, `test`, `docs`, `chore`, `ci`. The subject says why the change
  exists, not what the diff shows.
- Small commits that each leave `swift build` and `swift test` passing.
- No emojis in code, comments or documentation. Comments record why, and what
  was measured.
- Never commit an IPA, an installed `.app`, or credentials.

## Reporting problems

Bugs and app compatibility reports use the issue templates. Security
problems go through the process in [SECURITY.md](SECURITY.md), not a public
issue.
