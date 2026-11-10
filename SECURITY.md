# Security policy

## Reporting a vulnerability

Use GitHub private vulnerability reporting: open the repository's Security
tab and choose "Report a vulnerability"
(https://github.com/ayush5harma/eider/security/advisories/new). Do not open a
public issue for a vulnerability. Include the Eider version, macOS version,
and the smallest input that reproduces the problem.

## Scope

In scope:

- Archive extraction: an IPA entry that writes outside the extraction
  directory, exhausts disk or memory, or otherwise escapes the size caps.
- Downloads: bypassing the https-only rule (http is allowed to loopback only),
  a redirect that leaves the policy, a checksum mismatch that is accepted.
- Source parsing: a source or deep link (`eider://source/...`,
  `eider://install/...`) that crashes Eider, reads local files, or makes
  Eider fetch something it should not.
- Signing and installation: anything that makes Eider run code from an IPA
  during install, sign or place files outside its own state directory, or
  install an app whose binary was meant to be refused (for example one that is
  still encrypted).

Out of scope: vulnerabilities in an app you chose to install, and the fact that
Eider's own releases are ad hoc signed and not notarized (documented in the
cask caveats).

## Stance

Sources and IPAs are untrusted input. Eider does not trust a source's
contents, an IPA's contents, or a server's redirects. A source can only make
Eider download a file; installing it is a separate step that never executes
anything from the IPA. A checksum in a source is checked when present but a
source without one is not a verified source. Install only from sources and
IPAs you trust.

## Response

This is a small, volunteer-run project. Reports are acknowledged as soon as
practical; fixes ship in the next release and are credited in the advisory
unless you ask otherwise.
