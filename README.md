# BCR2000/BCF2000 USB Fix for Apple Silicon

The BCR2000's bulk OUT endpoint declares an invalid `wMaxPacketSize=4`, which Apple's USB host stack rejects on Apple silicon. The codeless descriptor override presents a value of `8`, allowing Apple's stock USB-MIDI driver to send data.

The fix is in `Kext/BCDescriptorFix.kext` and has been verified on a BCR2000 (firmware 1.10, macOS 26.6.2). The BCF2000 has not yet been tested; the current descriptor override matches only the BCR2000 (VID `0x1397`, PID `0x00BC`).

## Install

See [docs/INSTALL.md](docs/INSTALL.md) for requirements, installation, verification, removal, and troubleshooting.

Installation requires a one-time Recovery policy change because the extension is ad hoc signed. A DIN MIDI interface remains an alternative that does not require changing that policy.

## Included

- `Kext/BCDescriptorFix.kext`: the descriptor override.
- `Kext/install.sh`: install, verify, and uninstall commands.
- `docs/INSTALL.md`: end-user instructions.
