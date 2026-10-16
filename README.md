# MidiQ BCR/BCF USB-MIDI Bridge

An experimental macOS Apple silicon project to make outgoing USB SysEx transfers reliable with the Behringer BCR2000 and BCF2000. Normal MIDI input works; the reported failure is during preset sends to the device.

**Status: root cause found and fixed on a BCR2000 (2026-10-16).** The BCR2000 declares an illegal `wMaxPacketSize=4` on its bulk OUT endpoint; Apple's USB host stack on Apple silicon rejects the endpoint (`AppleUSBXHCICommandRing::addEndpoint` code 17), so *nothing* the host sends ever reaches the unit while input keeps working. `Kext/BCDescriptorFix.kext` is a codeless kext that overrides that one byte (4 → 8). With it loaded, identity requests are answered, a 14 KB SysEx chain transfers with zero loss through the stock CoreMIDI driver, and a preset write + read-back is byte-identical. Details and measurements in [docs/architecture.md](docs/architecture.md).

## Why this is a separate project

The MidiQ editor currently uses Web MIDI/CoreMIDI. This project explores a macOS USB transport layer that could expose virtual CoreMIDI ports to the editor and other MIDI applications, while forwarding incoming MIDI and pacing outgoing SysEx at the USB transfer boundary.

The [Eleven Rack Driver](https://github.com/Matt-Housley/eleven-rack-driver) is useful precedent for an app-hosted USB engine, but it is not a MIDI-driver implementation. Its `erengine` process uses IOKit/IOUSBLib for the audio interfaces and explicitly leaves the class-compliant MIDI interface to Apple's `AppleMIDIUSBDriver`. It does not establish that a process can take over the BCR2000/BCF2000 MIDI interface.

## First milestone

See [the architecture and feasibility gates](docs/architecture.md). In brief:

1. Record the BCR2000 and BCF2000 USB vendor/product IDs, interface descriptors, endpoint directions, and packet sizes from a target Mac.
2. Test whether a user-space process can safely open/seize each USB-MIDI interface while CoreMIDI is using the built-in driver.
3. If ownership works, prove bidirectional USB-MIDI transfer with a non-destructive identity request before implementing preset writes.
4. Measure and validate a serialized USB OUT queue against BCL replies and a preset read-back.
5. If direct ownership is unavailable or unstable, evaluate a DriverKit system extension instead.

The correct transfer pacing is not known yet; it must be measured at the USB transport layer. Do not treat a delay value as a fix until repeated send/read-back tests pass on both models.

## Platform and signing

The current workspace is macOS on Apple silicon, so the host-specific toolchain path can be exercised here. The BCR2000/BCF2000 are not yet confirmed attached, so USB descriptor capture and hardware transfer tests remain pending.

A DriverKit route is viable in principle, but Apple documents MIDIDriverKit for macOS 15 and later and requires DriverKit/MIDI entitlements; USB transport also requires a device-matching entitlement. The Apple MIDI-driver sample demonstrates CoreMIDI endpoints and driver lifecycle, but its device is virtual, so USB transport and hardware matching remain project work.

## References

- [Apple: Creating a MIDI device driver](https://developer.apple.com/documentation/mididriverkit/creating-a-midi-device-driver)
- [Apple: MIDIDriverKit](https://developer.apple.com/documentation/mididriverkit)
- [Apple: USBDriverKit](https://developer.apple.com/documentation/usbdriverkit)
- [Apple: Requesting entitlements for DriverKit development](https://developer.apple.com/documentation/driverkit/requesting_entitlements_for_driverkit_development)
- [Eleven Rack Driver](https://github.com/Matt-Housley/eleven-rack-driver)
