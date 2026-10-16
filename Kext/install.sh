#!/bin/zsh
# BCR2000/BCF2000 USB fix installer for Apple silicon Macs.
# Usage: ./install.sh [install|verify|uninstall]
set -euo pipefail

KEXT_NAME=BCDescriptorFix.kext
SRC="$(cd "$(dirname "$0")" && pwd)/$KEXT_NAME"
DST=/Library/Extensions/$KEXT_NAME
BACKUP=~/Desktop/kext-backup

say()  { print -P "%F{cyan}==>%f $*"; }
ok()   { print -P "%F{green}  ✓%f $*"; }
warn() { print -P "%F{yellow}  !%f $*"; }
die()  { print -P "%F{red}  ✗%f $*"; exit 1; }

need_arm64() {
  [[ "$(uname -m)" == arm64 ]] || die "This fix is for Apple silicon Macs only (Intel Macs do not have this bug)."
}

check_security() {
  # Permissive Security (csrutil enable --without kext) shows as "unknown (Custom Configuration)".
  local st; st=$(csrutil status 2>/dev/null | head -1)
  if [[ "$st" == *"Custom Configuration"* ]] || [[ "$st" == *"disabled"* ]]; then
    ok "Kernel-extension signing check is relaxed ($st)"
    return 0
  fi
  warn "System Integrity Protection is fully enabled."
  cat <<'EOF'

  This kext is not signed with a paid Apple Developer certificate, so macOS will
  refuse to load it until you relax ONE protection. This is a one-time step:

    1. Shut down the Mac.
    2. Press and hold the power button until "Loading startup options" appears.
    3. Choose Options -> Continue, log in, then Utilities -> Terminal.
    4. Type:   csrutil enable --without kext
       Confirm the warning and enter your password.
    5. Restart, then run this installer again.

  (Undo later with  csrutil enable  in the same place.)
EOF
  exit 1
}

check_stale_kexts() {
  # Any kext in /Library/Extensions that cannot load (wrong arch, unapproved) aborts
  # the whole auxiliary-collection rebuild, which silently blocks ours.
  local bad=()
  for k in /Library/Extensions/*.kext(N); do
    [[ "$k" == "$DST" ]] && continue
    local exe; exe=$(defaults read "$k/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)
    [[ -z "$exe" ]] && continue
    local bin="$k/Contents/MacOS/$exe"
    if ! lipo -archs "$bin" 2>/dev/null | grep -q arm64; then bad+=("$k"); fi
  done
  (( ${#bad} == 0 )) && { ok "No incompatible kexts in /Library/Extensions"; return; }
  warn "These kernel extensions are Intel-only and can never load on this Mac:"
  for k in "${bad[@]}"; do echo "      $(basename "$k")"; done
  echo "  They block macOS from installing any other extension. Move them to $BACKUP ? [y/N]"
  read -r ans
  [[ "$ans" == [yY]* ]] || die "Cannot continue while incompatible kexts are present."
  mkdir -p "$BACKUP"
  for k in "${bad[@]}"; do sudo mv "$k" "$BACKUP/"; done
  ok "Moved aside (restore by moving them back)."
}

do_install() {
  need_arm64
  say "Checking security configuration"; check_security
  say "Checking for incompatible kernel extensions"; check_stale_kexts
  say "Signing and installing $KEXT_NAME (administrator password required)"
  codesign --force -s - "$SRC"
  sudo rm -rf "$DST"
  sudo cp -R "$SRC" "$DST"
  sudo chown -R root:wheel "$DST"
  sudo chmod -R 755 "$DST"
  sudo kmutil load -p "$DST"
  ok "Staged for loading."
  cat <<'EOF'

  If System Settings > Privacy & Security shows a message about blocked system
  software, click "Allow". Then RESTART the Mac, switch the BCR2000/BCF2000 off
  and on again, and run:   ./install.sh verify
EOF
}

do_verify() {
  say "Looking for the device"
  if ! ioreg -p IOUSB -l -w0 | grep -q '"idVendor" = 5015'; then
    die "No Behringer USB device found. Connect the BCR2000/BCF2000 (USB mode U-1..U-4) and power-cycle it."
  fi
  say "Checking the last 30 minutes of kernel log for the endpoint rejection"
  if log show --last 30m --style compact --predicate 'process == "kernel" AND eventMessage CONTAINS "validateEndpointMaxPacketSize"' 2>/dev/null | grep -q 'endpoint 0x02'; then
    die "macOS still rejected endpoint 0x02 at the last plug-in. The fix is not active: reboot, or re-run ./install.sh"
  fi
  ok "No endpoint rejection logged."
  if ioreg -p IOUSB -l -w0 | grep -q 'kUSBDescriptorOverride'; then ok "Descriptor override present on the device node."; fi
  cat <<'EOF'

  Final check: in your editor (or Audio MIDI Setup), send a request to the
  device. The BCR/BCF should now answer and its LED rings should follow
  incoming MIDI.
EOF
}

do_uninstall() {
  say "Removing $DST (administrator password required)"
  sudo rm -rf "$DST"
  sudo kmutil install --volume-root / --update-all 2>/dev/null || true
  ok "Removed. Restart to finish. (To restore full SIP: Recovery -> Terminal -> csrutil enable)"
}

case "${1:-install}" in
  install)   do_install ;;
  verify)    do_verify ;;
  uninstall) do_uninstall ;;
  *) echo "usage: $0 [install|verify|uninstall]"; exit 2 ;;
esac
