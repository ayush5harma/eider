#!/usr/bin/env bash
# Converts a pymobiledevice3 RemotePairing record (~/.pymobiledevice3/remote_<udid>.plist)
# into the RP pairing file format Eider's pairing mode reads (idevice's rp_pairing_file.rs:
# public_key, private_key, identifier, optional alt_irk).
#
#   Scripts/rppairing-from-pymobiledevice3.sh <remote_udid.plist> <out.rppairing.plist> [hostname]
#
# Run it on the computer that made the pairing. pymobiledevice3 does not store the host
# identifier: it sends uppercase UUIDv3(DNS namespace, platform.node()) at pair time
# (pair_records.generate_host_id), so the identifier is rebuilt from this computer's
# hostname, or from [hostname] if the computer was renamed since pairing. A wrong hostname
# gives a file the iPhone rejects at pair-verify (no harm done; Eider never re-pairs).
#
# The key bytes are copied, never printed. The output is written mode 600 in a directory
# that must already be mode 700 (for example ~/.cache/eider-dev/pairing), and an existing
# file is not overwritten.
set -euo pipefail

[ $# -ge 2 ] && [ $# -le 3 ] || {
  echo "usage: $0 <remote_udid.plist> <out.rppairing.plist> [hostname]" >&2
  exit 64
}
IN="$1"
OUT="$2"
HOSTNAME_ARG="${3:-}"

[ -f "$IN" ] || { echo "error: $IN not found" >&2; exit 66; }
[ ! -e "$OUT" ] || { echo "error: $OUT exists; remove it first" >&2; exit 73; }
OUT_DIR="$(dirname "$OUT")"
[ "$(stat -f %Lp "$OUT_DIR")" = 700 ] || {
  echo "error: $OUT_DIR must be mode 700 (it will hold pairing material)" >&2
  exit 77
}

umask 077
python3 -I - "$IN" "$OUT" "$HOSTNAME_ARG" <<'PY'
import os, platform, plistlib, sys, uuid

source, target, hostname = sys.argv[1], sys.argv[2], sys.argv[3] or platform.node()
with open(source, "rb") as handle:
    record = plistlib.load(handle)

for key in ("private_key", "public_key"):
    value = record.get(key)
    if not isinstance(value, bytes) or len(value) != 32:
        sys.exit(f"error: {key} is missing or not 32 bytes; not a pymobiledevice3 remote record")
if "identifier" in record:
    sys.exit("error: this file already has an identifier; it is an RP pairing file already")

converted = {
    "public_key": record["public_key"],
    "private_key": record["private_key"],
    # Same derivation as pymobiledevice3.pair_records.generate_host_id.
    "identifier": str(uuid.uuid3(uuid.NAMESPACE_DNS, hostname)).upper(),
}
if isinstance(record.get("peer_alt_irk"), bytes):
    # pymobiledevice3's peer_alt_irk is the device's alt IRK, which idevice stores as alt_irk.
    converted["alt_irk"] = record["peer_alt_irk"]

fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as handle:
    plistlib.dump(converted, handle, fmt=plistlib.FMT_XML)
print(f"wrote {target} (identifier derived from hostname {hostname!r})")
PY
