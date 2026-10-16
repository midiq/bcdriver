# Architecture and Feasibility Gates

**Status (2026-10-16): Candidate C works.** With `Kext/BCDescriptorFix.kext` loaded, the BCR2000 answers identity requests, moves LED rings, accepts a 202-line / 14 KB SysEx chain with zero loss through Apple's stock `MIDISendSysex`, and a temporary-preset write + read-back is byte-identical. Root cause: Apple's USB host stack rejects the BCR2000's bulk OUT endpoint because `wMaxPacketSize=4` is illegal; the kext overrides that one byte. Remaining: BCF2000 descriptor + personality, signing/distribution.

## Problem boundary

The failure described for Apple silicon is outgoing USB SysEx: preset data sent to a BCR2000 or BCF2000 can be dropped or corrupted, while receiving MIDI works. The experiment must control the host-to-device USB transfer path, not just add waits between calls made through the existing MIDI API.

The working hypothesis is that a bridge which owns the USB-MIDI interface and submits one transfer at a time can provide meaningful backpressure. This is unproven. The USB descriptors, endpoint layout, achievable transfer cadence, and device firmware behavior must be measured on hardware.

## Candidate A: app-hosted USB-MIDI bridge

This is the first path to test because the Eleven Rack project demonstrates a user-space IOKit/IOUSBLib engine without a DriverKit system extension. That project claims its audio interfaces, though, and leaves MIDI attached to Apple's USB-MIDI driver; it is not evidence that the BCR/BCF MIDI interface can be seized.

Proposed data flow if ownership succeeds:

```text
MIDI apps / Web MIDI
        | CoreMIDI virtual destination
        v
bridge process -> ordered SysEx queue -> USB-MIDI event packets -> USB bulk OUT -> BCR2000 / BCF2000
bridge process <- USB-MIDI bulk IN <- MIDI bytes              <- CoreMIDI virtual source
```

The process would publish a virtual CoreMIDI destination for sends and a virtual source for received MIDI. Those ports exist while the bridge runs; this is an app-hosted bridge, not a transparent system driver. It must preserve message order, forward non-SysEx MIDI, and avoid unbounded buffering. USB-MIDI 1.0 packetization and SysEx reassembly must follow the descriptors actually reported by each device.

The pacing point must be the USB OUT transfer submission/completion path. Sending delays through the existing CoreMIDI USB endpoint would not test whether bypassing Apple's transport scheduling helps. The pacing interval and transfer size remain experimental parameters; BCL replies and a read-back are the correctness checks.

### Gate A: device ownership

On a target Apple silicon Mac, capture each device's VID/PID, configurations, MIDI interface numbers, endpoint directions, transfer type, and maximum packet sizes. Then test whether a small IOKit process can open the USB device and claim the MIDI interface without disrupting other interfaces or leaving the device wedged.

`USBDeviceOpenSeize` is a possibility to test, not a guaranteed API contract for these devices. The reference project uses it as a fallback for the Eleven Rack audio device; that does not establish that it can replace Apple's class driver for a BCR/BCF.

Stop here if ownership cannot be acquired and released cleanly. Do not attempt preset writes during this gate.

#### Gate A result (BCR2000, U-1 mode, macOS 26.6.2, M-series)

Captured with `Tools/bcprobe`; raw output in `docs/captures/`.

- VID `0x1397`, PID `0x00BC`, bcdDevice `0x0100`, full-speed (12 Mb/s), one configuration, two interfaces.
- Interface 0: Audio Control, no endpoints. Interface 1: MIDIStreaming, bulk IN `0x81` `wMaxPacketSize=64`, bulk OUT `0x02` **`wMaxPacketSize=4`**. One embedded IN jack (1) and one embedded OUT jack (3), each with one external counterpart.
- `USBInterfaceOpen` and `USBInterfaceOpenSeize` on interface 1 both return `kIOReturnExclusiveAccess`. The registry shows `UsbExclusiveOwner = MIDIServer`; Apple's class driver holds the interface and cannot be displaced from user space. **Candidate A is closed.**

The 4-byte OUT max packet size is the main lead. Every host-to-device bulk transfer carries exactly one USB-MIDI event packet, so a long SysEx becomes a stream of back-to-back 4-byte transactions. A full-speed bus can deliver one such packet per frame slot with no gap; the device firmware must drain each 4-byte packet before the next arrives, and the host controller decides that cadence, not the MIDI API caller.

### Control experiment: CoreMIDI pacing

Before committing to a DriverKit extension, measure what the existing Apple USB-MIDI path actually does. `Tools/bcmidi` sends BCL lines through CoreMIDI to the BCR2000 destination and tracks the `0x21` reply per line (index + error code), so dropped or corrupted lines are visible without a read-back. Variables:

- transfer mode: `MIDISendSysex` (driver-chunked) versus `MIDISend` with explicit packets of `--chunk` bytes and per-packet timestamps `--gap-us` apart;
- `--ack`: wait for each `0x21` before sending the next line (upper bound on reliability, lower bound on speed).

Outcomes:

- If `--ack` is reliable but unpaced sends drop lines, the problem is host cadence and a user-space bridge publishing a virtual CoreMIDI destination (Candidate A without USB ownership) is a viable product even though it cannot own the interface.
- If even `--ack` single-line sends fail, the fault is inside a single transfer and only a transport below CoreMIDI (Candidate B) can address it.
- If timestamped 4-byte packet pacing fixes it, the same virtual-destination bridge can apply that pacing.

#### Control experiment result (BCR2000, U-1, macOS 26.6.2, M-series)

Tools: `Tools/bcmidi` plus the independent `sendmidi` CLI as a cross-check.

- Receive path works: turning an encoder delivers `B0 46 xx` on "BCR2000 Port 1" (`bcmidi monitor`).
- Behringer identity request (`0x01`) gets **no reply**. A universal identity request also gets no reply, but the BC spec does not list that message, so it is not evidence either way.
- A slow CC 70 sweep (3-byte channel messages, 150 ms apart) produces **no LED-ring movement** on Port 1, Port 2 or Port 3, from `bcmidi` and from `sendmidi`. Power-cycling the unit changes nothing.
- CoreMIDI's `SysExSender` logs the bytes as sent (`sent 8 bytes to destination ... (0 remain)`); MIDIServer and `com.apple.iousbhost` log no errors. The failure is silent below CoreMIDI.

The pacing experiment is therefore moot on this host: there is nothing to pace. **Every host-to-device message is lost, not just long SysEx.**

#### Root-cause hypothesis: illegal `wMaxPacketSize=4` on the bulk OUT endpoint

USB 2.0 §5.8.3 only permits 8, 16, 32 or 64 bytes for a full-speed bulk endpoint. The BCR2000 declares 4. The Linux xHCI driver works around this explicitly (`xhci_endpoint_init`: "FS bulk supports 8, 16, 32 or 64", `clamp_val(max_packet, 8, 64)`), and ALSA's USB-MIDI driver then sends 4-byte URBs so the device never sees more than one event per packet. Pre-xHCI Intel Macs (EHCI/UHCI) did not validate the value. Apple's xHCI stack on M-series is the odd one out: either the OUT endpoint is never configured, or packets are built against a size the firmware rejects. Both outcomes look identical from CoreMIDI — writes "succeed", nothing arrives — and both are consistent with the community report that input works while output fails.

This also predicts that the same unit will work on the same Mac through a class-compliant USB-MIDI interface with legal endpoint sizes via DIN (the known workaround), and that a BCF2000 shows the identical descriptor and symptom. **DIN confirmed 2026-10-16:** the same BCR2000 responds normally on this Mac through a DIN interface, so the unit, the BCL protocol and the host's MIDI stack are all fine; the defect is specific to the BCR2000's own USB path. The BCF2000 check is still open.

#### Kernel-log confirmation (2026-10-16, after a power-cycle re-enumeration)

```text
IOUSBHostFamily::validateEndpointMaxPacketSize: USB 2.0 5.[5-8].3: endpoint 0x02 invalid wMaxPacketSize 0x0004
AppleUSBXHCICommandRing::addEndpoint: completed with result code 17
```

xHCI completion code 17 is _Parameter Error_: the controller refused to configure the bulk OUT endpoint. Apple's stack validates the descriptor, logs the violation at debug level, and does **not** clamp to a legal size the way Linux does. The IN endpoint (64 bytes) is created normally, which is why input works. CoreMIDI's writes complete because `AppleUSBMIDI` accepts them, but there is no pipe underneath. This is no longer a hypothesis.

It also means **Candidate B is dead on arrival**: a DriverKit extension would ask the same `IOUSBHostFamily` to open the same endpoint and get the same code 17.

## Candidate C: codeless descriptor-override kext

`IOUSBHostFamilyDefinitions.h` exposes `kUSBDescriptorOverride` (and `kUSBConfigurationDescriptorOverride`). Apple uses it in its own kexts (`IOBluetoothFamily`, `AppleUSBiBridge`, `AppleEmbeddedUSBHost`) via a codeless personality of class `AppleUSBHostMergeProperties`, which merges `IOProviderMergeProperties` into the matched `IOUSBHostDevice` before the composite driver parses the configuration. The override value is a dict `{descriptor: <raw bytes>, index: 0, languageID: 0}`.

`Kext/BCDescriptorFix.kext` is exactly that: it matches `idVendor=0x1397 idProduct=0x00BC` and supplies the BCR2000's own 101-byte configuration descriptor with byte 91 changed from `0x04` to `0x08`. Nothing else is altered, so `AppleUSBMIDI` still binds and CoreMIDI still shows "BCR2000 Port 1/2/3". The device never sees the change; it only affects what the host believes the endpoint's max packet size is, and USB-MIDI OUT packets are 4 bytes, so an 8-byte host-side maximum is always satisfied.

Setting the property from user space (`Tools/bcoverride`) returns `kIOReturnUnsupported` — **also when run as root** — so `IOUSBHostDevice::setProperties` does not accept the key from any client and a matching personality is the only delivery path. On Apple silicon a kext needs either a Developer ID signature or Permissive Security; there is no third option, and no user-space (Eleven-Rack-style) design can reach a fault that lives in endpoint creation.

### Gate C: does the override take effect

1. After reboot, `kmutil showloaded | grep BCDescriptorFix` lists the bundle and `ioreg -l -r -n BCR2000 | grep kUSBDescriptorOverride` shows the property on the device node.
2. `log show --predicate 'process == "kernel"' | grep validateEndpointMaxPacketSize` shows **no** new violation for endpoint 0x02 after replugging the unit.
3. `bcmidi cc` moves the LED ring; `bcmidi identity` gets a `BCR2000 1.xx` reply.
4. Then proceed to Gate B as written (identity, read-only BCL, temporary-preset write + read-back, both models).

#### Gate C result (BCR2000, 2026-10-16) — PASS

Install notes: on macOS 26 even a codeless kext must carry a code signature (`kmutil load` fails with "Bad code signature" otherwise); ad-hoc signing is accepted once SIP's kext check is relaxed (`csrutil enable --without kext` from Recovery, which puts Apple silicon in Permissive Security). Separately, any stale third-party kext in `/Library/Extensions` that cannot be loaded (unapproved HoRNDIS; seven x86_64-only kexts) aborts the whole auxiliary-collection rebuild with no reference to our bundle — they had to be moved aside first. `kmutil showloaded` does not list a codeless kext; the proof it is active is the device node and behaviour.

- `bcprobe --descriptors-only` now reports `ENDPOINT 0x02 OUT bulk wMaxPacketSize=8` — the host sees the overridden descriptor.
- `bcmidi identity` → **`BCR2000 1.10`**. First reply ever received over USB on this Mac.
- `bcmidi cc` → LED ring sweeps.
- `bcmidi stress --lines 200 --len 60` (14 031 bytes, `MIDISendSysex`, unpaced): **202/202 replies, 0 errors, in order.** 22.5 s (624 B/s) — CoreMIDI's SysEx sender throttles conservatively.
- Raw `MIDISend` packets, 3 bytes each, timestamped `--gap-us`:
  - 1000 µs (3.1 KB/s): PASS
  - 320 µs (10.9 KB/s): PASS
  - 100 µs (60 KB/s): FAIL from index 106 onward — every second line missing, the rest return BCL error 22. Same pattern with no gap at all.
- Gate B round trip: `dump --preset 0x7F` → 16 BCL lines; `send` the same file back at 320 µs → 16/16 acked; `dump` again → **`diff` identical**.

So the device's real SysEx intake limit is somewhere between 11 KB/s and 60 KB/s, i.e. far above anything CoreMIDI's default path produces. The original community report ("M-series sends too fast") was a misdiagnosis of this endpoint rejection: on Apple silicon no bytes were leaving the host at all. A ~10 KB/s ceiling is a sensible default for any tool that bypasses `MIDISendSysex`.

### Gate B: safe transport proof

With the interface claimed:

1. Send a non-destructive universal MIDI identity request and verify the device's reply.
2. Receive and forward ordinary MIDI input.
3. Send a BCL request that only reads device state; compare the complete response with a known-good transfer.
4. Only then test a preset write, starting with a temporary preset and verifying by reading it back.
5. Repeat on both BCR2000 and BCF2000, disconnect/reconnect, and confirm the built-in CoreMIDI endpoint is restored when the bridge exits.

Record raw USB-MIDI packets, timestamps, BCL replies, and read-back results for each run. A successful write without a matching read-back is not a pass.

## Candidate B: DriverKit system extension

If app-hosted ownership fails, evaluate a hardware-backed MIDI driver using `IOUserMIDIDriver`/`IOUserMIDIDevice` from MIDIDriverKit together with USBDriverKit transport. This can publish CoreMIDI ports as a driver extension rather than as a running app.

Apple's current documentation lists MIDIDriverKit for macOS 15 and later. Development and distribution require DriverKit, MIDI-family, and USB-transport entitlements/provisioning. Apple's MIDI sample demonstrates a virtual device and the system-extension lifecycle, but does not implement USB device transport. Entitlement approval and matching the class-compliant interfaces are early gates, not implementation details to postpone.

## Decision rule

- ~~If direct app-hosted ownership works and transport tests pass, implement the bridge and its launch/permission UX.~~ Ownership failed (Gate A result above).
- ~~If the CoreMIDI control experiment shows that per-line acknowledgement or packet pacing is sufficient, implement a virtual-destination bridge on top of CoreMIDI.~~ Not applicable: no output reaches the device at all, so a CoreMIDI-level bridge cannot help.
- ~~The remaining software route is a DriverKit extension (Candidate B) that owns the MIDIStreaming interface and opens the bulk OUT pipe itself.~~ Closed by the kernel log: the host controller rejects the endpoint before any driver can open it.
- **Candidate C is the solution.** Gate C and the Gate B round trip pass on the BCR2000. The deliverable is the codeless kext plus `Kext/install.sh` and `docs/INSTALL.md`.
- Distribution decision: the maintainer has no Apple Developer account and does not want one, so the shipped path is ad-hoc signing + a one-time `csrutil enable --without kext` per user, documented honestly, with DIN as the zero-install alternative. A Developer-ID-signed build from a contributor would remove the Recovery step; the kext itself would not change.
- Open items: capture a BCF2000 descriptor and add its personality (verify PID and bytes, do not assume); file Feedback with Apple asking for the Linux-style clamp in `IOUSBHostFamily`.
