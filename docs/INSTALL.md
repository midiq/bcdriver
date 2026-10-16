# Installing the BCR2000 / BCF2000 USB fix on an Apple silicon Mac

## What this fixes

On Apple silicon Macs the BCR2000 and BCF2000 can be _heard_ but not _spoken to_ over USB: encoder and fader movements arrive, but presets, LED feedback and SysEx sent **to** the unit vanish. The cause is a one-byte flaw in the units' USB descriptor (`wMaxPacketSize = 4` on the bulk OUT endpoint — the USB specification only allows 8, 16, 32 or 64). Intel Macs, Windows and Linux tolerate it; Apple silicon's USB stack refuses to create the endpoint, so nothing is ever transmitted.

The codeless kernel extension included here tells macOS to read `8` instead of `4` for the BCR2000's bulk OUT endpoint. It leaves Apple's USB-MIDI driver and CoreMIDI ports unchanged. This release is verified on the BCR2000; BCF2000 support is not yet verified.

## What it costs

macOS only loads kernel extensions that are signed with a paid Apple Developer certificate. This project does not have one, so **you must relax one security protection once**, from Recovery. Everything else about System Integrity Protection stays on. If that is not acceptable to you, see [Alternatives](#alternatives).

## Requirements

- Apple silicon Mac (M1 or later), macOS 13 or later.
- A BCR2000 or BCF2000 in one of the USB modes (U‑1 … U‑4).
- Administrator password.

## Steps

### 1. One-time: allow unsigned kernel extensions

1. Shut down the Mac.
2. Press and hold the power button until **Loading startup options** appears.
3. Choose **Options → Continue**, select your user and log in.
4. In the menu bar choose **Utilities → Terminal** and type:

   ```sh
   csrutil enable --without kext
   ```

   Confirm the "unsupported configuration" warning and enter your password.

5. Choose → **Restart**.

### 2. Install

1. Download the latest release zip and unpack it, or clone this repository.
2. Open Terminal, `cd` into the `Kext` folder and run:

   ```sh
   ./install.sh
   ```

   It checks the security setting, warns about any leftover Intel-only extensions that would block the install (and offers to move them to `~/Desktop/kext-backup`), signs and copies the kext, and asks macOS to load it. You will be asked for your password once.

3. If **System Settings → Privacy & Security** shows _"System software … was blocked"_, click **Allow**.
4. **Restart** the Mac.

### 3. Verify

Switch the BCR2000/BCF2000 off and on again, then:

```sh
./install.sh verify
```

It confirms the device is present and that macOS no longer rejected the endpoint. Then try a request from your editor — the unit should answer, and its LED rings should follow MIDI you send.

## Uninstall

```sh
./install.sh uninstall
```

then restart. To restore full SIP, repeat step 1 with `csrutil enable`.

## Troubleshooting

| Symptom                                               | Cause / fix                                                                                                          |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `Authenticating extension failed: Bad code signature` | Step 1 was not done (SIP kext check still on).                                                                       |
| Install reports Intel-only kexts                      | Old drivers from a migrated Intel Mac. Let the script move them aside; nothing on an Apple silicon Mac can use them. |
| `verify` says the endpoint was still rejected         | You did not restart after installing, or the unit was not re-plugged/power-cycled after the restart.                 |
| No "Allow" button appears                             | Normal if the kext was already approved once. Just restart.                                                          |
| Device works, but a large preset send is slow         | Expected: Apple's SysEx sender paces conservatively (~0.6 KB/s). The unit itself handles ~10 KB/s.                   |

## Alternatives

- **DIN MIDI interface.** Any class-compliant USB-MIDI interface with 5-pin DIN cables to the unit works today with no changes to the Mac. Slower (31.25 kbit/s), one more box.
- **Signed build.** If someone with an Apple Developer ID signs this exact kext, step 1 disappears for everyone; users then only approve it in Privacy & Security. Contributions welcome.
