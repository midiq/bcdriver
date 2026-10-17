# BCR2000/BCF2000 USB Fix for Apple Silicon

The BCR2000's bulk OUT endpoint declares an invalid `wMaxPacketSize=4`, which Apple's USB host stack rejects on Apple silicon. The codeless descriptor override presents a value of `8`, allowing Apple's stock USB-MIDI driver to send data.

The fix is in `Kext/BCDescriptorFix.kext` and has been verified on a BCR2000 (firmware 1.10, macOS 26.6.2). The BCF2000 has not yet been tested; the current descriptor override matches only the BCR2000 (VID `0x1397`, PID `0x00BC`).

## Requirements

- Apple silicon Mac (M1 or later), macOS 13 or later.
- BCR2000 in USB mode U-1 through U-4. BCF2000 support is not yet verified.
- Administrator password.

## Install

1. Download the [bcdriver.zip release asset](https://github.com/midiq/bcdriver/releases/latest/download/bcdriver.zip) and unpack it.
2. Allow unsigned kernel extensions once:
   1. Shut down the Mac and press and hold the power button until **Loading startup options** appears.
   2. Choose **Options → Continue**, select your user, and log in.
   3. Open **Utilities → Terminal** and run:

      ```sh
      csrutil enable --without kext
      ```

      Confirm the warning and enter your password, then restart. This relaxes only the kernel-extension signing check; the rest of System Integrity Protection remains enabled.

3. In Terminal, change to the `Kext` folder inside the extracted archive and run:

   ```sh
   ./install.sh
   ```

   The installer checks the security setting, warns about incompatible Intel-only extensions, signs and installs the kext, and asks macOS to load it. Enter your administrator password when prompted.

4. If **System Settings → Privacy & Security** says system software was blocked, click **Allow**, then restart the Mac.
5. Power-cycle the controller and verify the installation from the `Kext` folder:

   ```sh
   ./install.sh verify
   ```

   Send a request to the controller from [BCEditor](https://bceditor.com) or another MIDI editor; it should answer and its LED rings should respond to MIDI.

## Uninstall

From the `Kext` folder, run:

```sh
./install.sh uninstall
```

Restart the Mac to finish. To restore full System Integrity Protection, boot into Recovery and run `csrutil enable` in Terminal.

## Troubleshooting

| Symptom                                               | Cause / fix                                                                                                           |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `Authenticating extension failed: Bad code signature` | The Recovery step was not completed, so the kext signing check is still enabled.                                      |
| Installer reports Intel-only kexts                    | Old drivers migrated from an Intel Mac can block the install. Let the installer move them to `~/Desktop/kext-backup`. |
| `verify` says the endpoint was still rejected         | Restart after installation, then unplug and power-cycle the controller.                                               |
| No **Allow** button appears                           | This is normal if the kext was already approved. Restart the Mac.                                                     |
| Large preset sends are slow                           | Apple's SysEx sender paces transfers at about 0.6 KB/s; this is expected.                                             |

## Alternative

A class-compliant USB-MIDI interface with 5-pin DIN cables works without changing Mac security settings. A Developer ID-signed build would also remove the Recovery step.
