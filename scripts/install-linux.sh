#!/usr/bin/env bash
# Builds soda and soda-gui and installs them with the desktop entry and the
# icon under PREFIX (default ~/.local), where desktop environments look for
# a user's applications. Run with PREFIX=/usr/local under sudo for everyone.
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${PREFIX:-$HOME/.local}
id=io.github.zhscn.soda

cargo build --release --manifest-path "$root/Cargo.toml" --features gui --bins
install -Dm755 "$root/target/release/soda" "$prefix/bin/soda"
install -Dm755 "$root/target/release/soda-gui" "$prefix/bin/soda-gui"
install -Dm644 "$root/packaging/linux/$id.desktop" "$prefix/share/applications/$id.desktop"
install -Dm644 "$root/assets/icon.svg" "$prefix/share/icons/hicolor/scalable/apps/$id.svg"

# The MIME cache lets file managers offer Soda for the entry's types. No
# icon cache is written: one left in a user's hicolor goes stale and hides
# icons installed after it, and desktops find the SVG without one.
command -v update-desktop-database >/dev/null &&
  update-desktop-database -q "$prefix/share/applications" || true

echo "installed into $prefix"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "note: $prefix/bin is not on PATH; the desktop entry runs soda-gui from there" ;;
esac
