# BCDescriptorFix — BCR2000 / BCF2000 USB output on Apple silicon

Behringer's BCR2000 and BCF2000 are class-compliant USB-MIDI controllers that work out of the box on Linux, Windows and Intel Macs. On **Apple silicon** Macs they are receive-only: knob and fader movements arrive, but nothing the Mac sends — presets, SysEx, LED feedback — ever reaches the unit.

**Root cause (found 2026-10-16, see [docs/architecture.md](docs/architecture.md)):** the units declare an illegal `wMaxPacketSize = 4` on their bulk OUT endpoint (USB 2.0 §5.8.3 allows 8/16/32/64). Linux clamps it; Apple's USB host stack on M-series rejects the endpoint outright (`AppleUSBXHCICommandRing::addEndpoint` → code 17), so the OUT pipe is never created. Writes "succeed" at the CoreMIDI layer and go nowhere. The widely repeated explanation — "M-series sends too fast" — is wrong; no bytes were leaving the host.

**The fix:** `Kext/BCDescriptorFix.kext`, a *codeless* kernel extension (a plist, no executable) that uses Apple's own `kUSBDescriptorOverride` mechanism to present the device's descriptor with that one byte changed, 4 → 8. Apple's stock USB-MIDI driver then works normally. Verified on a BCR2000 (firmware 1.10, macOS 26.6.2): identity replies, LED feedback, a 14 KB / 202-line SysEx chain with zero loss, and a preset write + read-back that is byte-identical.

## Install

→ **[docs/INSTALL.md](docs/INSTALL.md)**

Short version: this kext is not signed with a paid Apple Developer certificate, so each user must once run `csrutil enable --without kext` from Recovery, then `./Kext/install.sh`, approve in Privacy & Security, and restart. The script also detects the common trap of leftover Intel-only kexts that silently block the install. A DIN MIDI interface remains the zero-install alternative.

## Repository layout

| Path | Purpose |
|---|---|
| `Kext/BCDescriptorFix.kext` | The fix. Matches VID `0x1397` PID `0x00BC` (BCR2000). |
| `Kext/install.sh` | User installer: `install` / `verify` / `uninstall`. |
| `Tools/bcprobe` | IOKit probe: dumps USB descriptors as the host sees them, tests interface ownership. |
| `Tools/bcmidi` | CoreMIDI test tool: `identity`, `cc`, `monitor`, `stress`, `send`, `dump` with per-line BCL acknowledgement checking. |
| `Tools/bcoverride` | Negative result: proves the override cannot be set from user space (even as root). |
| `docs/architecture.md` | Investigation log: gates, kernel evidence, throughput measurements, decisions. |
| `docs/bc-sysex-protocol.md` | BCL / SysEx protocol notes used by the tools. |
| `docs/captures/` | Raw descriptor dumps, kernel logs, test outputs. |

Build the tools with `swift build` (Command Line Tools are enough; no Xcode needed).

## Status and open items

- BCR2000: **fixed and verified.**
- BCF2000: not yet captured. It very likely has the same flaw; it needs its own personality once a unit's descriptor is dumped with `bcprobe --descriptors-only` (PID and exact descriptor bytes must be verified, not assumed).
- Distribution without the Recovery step requires a Developer ID signature. This project's maintainer does not hold one; a signed build from a contributor would remove step 1 of the install for everyone.
- Apple Feedback: ask for the Linux-style clamp in `IOUSBHostFamily::validateEndpointMaxPacketSize`.

## Measured limits

Through Apple's `MIDISendSysex` the transfer is lossless but paced at ~0.6 KB/s. Driving raw packets, the BCR2000 accepts ~11 KB/s cleanly and starts dropping alternate BCL lines (error 22) at ~60 KB/s. Tools that bypass `MIDISendSysex` should stay around 10 KB/s.

## References

- [BC MIDI Implementation (Mark van den Berg)](https://mountainutilities.eu/) — BCL/SysEx reference
- [Linux `xhci_endpoint_init` clamp](https://github.com/torvalds/linux/blob/master/drivers/usb/host/xhci-mem.c) — the behaviour Apple lacks
- [Eleven Rack Driver](https://github.com/Matt-Housley/eleven-rack-driver) — inspiration for the user-first install experience
