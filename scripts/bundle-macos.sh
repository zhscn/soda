#!/usr/bin/env bash
# Builds soda-gui and assembles target/release/Soda.app around it, with the
# committed icon (scripts/make-icons.sh renders it). Run on macOS; copy the
# bundle to /Applications to install. Set TARGET (e.g. aarch64-apple-darwin)
# to build for another architecture.
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/Cargo.toml" | head -1)
target_args=()
out="$root/target/release"
if [[ -n "${TARGET:-}" ]]; then
  target_args=(--target "$TARGET")
  out="$root/target/$TARGET/release"
fi

cargo build --release --manifest-path "$root/Cargo.toml" --features gui --bin soda-gui ${target_args[@]+"${target_args[@]}"}

app="$out/Soda.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$out/soda-gui" "$app/Contents/MacOS/soda-gui"
cp "$root/packaging/macos/soda.icns" "$app/Contents/Resources/soda.icns"
sed "s/@VERSION@/$version/g" "$root/packaging/macos/Info.plist" >"$app/Contents/Info.plist"
# An ad-hoc signature, which Apple silicon requires to run the program.
codesign --force --sign - "$app" >/dev/null 2>&1 || echo "note: codesign failed; the bundle is unsigned"
echo "built $app"
