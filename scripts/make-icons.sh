#!/usr/bin/env bash
# Renders assets/icon.svg into packaging/macos/soda.icns. The .icns is
# committed, so bundling on macOS needs neither librsvg nor this script;
# rerun it after changing the icon. Linux installs the SVG itself.
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for size in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$size" -h "$size" "$root/assets/icon.svg" -o "$work/$size.png"
done

# An .icns is a header and PNG entries, each tagged with its pixel size;
# the retina tags reuse the larger renderings.
python3 -I - "$work" "$root/packaging/macos/soda.icns" <<'PY'
import struct, sys, os
work, out = sys.argv[1], sys.argv[2]
entries = [
    (b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128),
    (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
    (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
]
body = b""
for tag, size in entries:
    data = open(os.path.join(work, f"{size}.png"), "rb").read()
    body += tag + struct.pack(">I", len(data) + 8) + data
open(out, "wb").write(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
echo "wrote $root/packaging/macos/soda.icns"
