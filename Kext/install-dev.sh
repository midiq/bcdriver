#!/bin/zsh
# Dev install of the codeless descriptor-override kext.
# Prereq on Apple silicon: Recovery -> Terminal -> `csrutil enable --without kext`
# (switches to Permissive Security). Revert later with `csrutil enable`.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/BCDescriptorFix.kext"
DST=/Library/Extensions/BCDescriptorFix.kext
codesign --force -s - "$SRC"
sudo rm -rf "$DST"
sudo cp -R "$SRC" "$DST"
sudo chown -R root:wheel "$DST"
sudo chmod -R 755 "$DST"
sudo kmutil load -p "$DST"
echo "If prompted, approve in System Settings > Privacy & Security, then reboot."
