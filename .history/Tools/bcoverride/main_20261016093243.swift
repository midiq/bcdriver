import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

// Experiment: inject a corrected configuration descriptor via kUSBDescriptorOverride
// on the live IOUSBHostDevice, then re-enumerate so the host re-reads it.
// Patch: bulk OUT 0x02 wMaxPacketSize 4 -> 8 (USB 2.0 §5.8.3 minimum for FS bulk).

let behringerVendorID = 0x1397
let args = CommandLine.arguments.dropFirst()
let dryRun = args.contains("--dry-run")
let noReenumerate = args.contains("--no-reenumerate")
let newMaxPacket: UInt8 = args.contains("--mps64") ? 64 : args.contains("--mps16") ? 16 : 8

func ioReturnString(_ kr: IOReturn) -> String {
    switch UInt32(bitPattern: kr) {
    case 0: return "kIOReturnSuccess"
    case 0xe00002c5: return "kIOReturnExclusiveAccess"
    case 0xe00002c7: return "kIOReturnUnsupported"
    case 0xe00002e2: return "kIOReturnNotPermitted"
    case 0xe00002cd: return "kIOReturnNotOpen"
    default: return String(format: "0x%08x", UInt32(bitPattern: kr))
    }
}

func findDevice() -> io_service_t? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == kIOReturnSuccess else { return nil }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
        let vid = IORegistryEntryCreateCFProperty(svc, kUSBVendorID as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        if vid == behringerVendorID { return svc }
        IOObjectRelease(svc)
    }
    return nil
}

func readConfigDescriptor(_ svc: io_service_t) -> [UInt8]? {
    let cfPlugIn = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)!
    let devClient = CFUUIDCreateFromString(nil, "9DC7B780-9EC0-11D4-A54F-000A27052861" as CFString)!
    let devIntf187 = CFUUIDGetUUIDBytes(CFUUIDCreateFromString(nil, "3C9EE1EB-2402-11B2-8E7E-000A27801E86" as CFString))
    var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    guard IOCreatePlugInInterfaceForService(svc, devClient, cfPlugIn, &plugin, &score) == kIOReturnSuccess, let plugin else { return nil }
    defer { IODestroyPlugInInterface(plugin) }
    var raw: LPVOID?
    guard plugin.pointee!.pointee.QueryInterface(plugin, devIntf187, &raw) == S_OK, let raw else { return nil }
    let dev = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface187>?.self)
    defer { _ = dev.pointee!.pointee.Release(dev) }
    var desc: IOUSBConfigurationDescriptorPtr?
    guard dev.pointee!.pointee.GetConfigurationDescriptorPtr(dev, 0, &desc) == kIOReturnSuccess, let desc else { return nil }
    let total = Int(UInt16(littleEndian: desc.pointee.wTotalLength))
    return Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(desc), count: total))
}

func patch(_ cfg: [UInt8]) -> (bytes: [UInt8], changed: [String]) {
    var b = cfg
    var changed: [String] = []
    var i = 0
    while i + 1 < b.count {
        let len = Int(b[i]), type = b[i + 1]
        guard len >= 2 else { break }
        if type == 0x05, len >= 7 {
            let addr = b[i + 2], attr = b[i + 3] & 3
            let mps = UInt16(b[i + 4]) | UInt16(b[i + 5]) << 8
            if attr == 2, mps < 8 {
                b[i + 4] = newMaxPacket; b[i + 5] = 0
                changed.append(String(format: "endpoint 0x%02x bulk wMaxPacketSize %d -> %d (offset %d)", addr, mps, newMaxPacket, i + 4))
            }
        }
        i += len
    }
    return (b, changed)
}

func reenumerate(_ svc: io_service_t) -> IOReturn {
    let cfPlugIn = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)!
    let devClient = CFUUIDCreateFromString(nil, "9DC7B780-9EC0-11D4-A54F-000A27052861" as CFString)!
    let devIntf187 = CFUUIDGetUUIDBytes(CFUUIDCreateFromString(nil, "3C9EE1EB-2402-11B2-8E7E-000A27801E86" as CFString))
    var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    let kr0 = IOCreatePlugInInterfaceForService(svc, devClient, cfPlugIn, &plugin, &score)
    guard kr0 == kIOReturnSuccess, let plugin else { return kr0 }
    defer { IODestroyPlugInInterface(plugin) }
    var raw: LPVOID?
    guard plugin.pointee!.pointee.QueryInterface(plugin, devIntf187, &raw) == S_OK, let raw else { return kIOReturnError }
    let dev = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface187>?.self)
    defer { _ = dev.pointee!.pointee.Release(dev) }
    let v = dev.pointee!.pointee
    var kr = v.USBDeviceOpen(dev)
    print("USBDeviceOpen       -> \(ioReturnString(kr))")
    if kr != kIOReturnSuccess {
        kr = v.USBDeviceOpenSeize(dev)
        print("USBDeviceOpenSeize  -> \(ioReturnString(kr))")
    }
    guard kr == kIOReturnSuccess else { return kr }
    kr = v.USBDeviceReEnumerate(dev, 0)
    print("USBDeviceReEnumerate-> \(ioReturnString(kr))")
    _ = v.USBDeviceClose(dev)
    return kr
}

guard let svc = findDevice() else { print("No Behringer USB device found."); exit(1) }
defer { IOObjectRelease(svc) }
var entryID: UInt64 = 0
IORegistryEntryGetRegistryEntryID(svc, &entryID)
print("IOUSBHostDevice entry id 0x\(String(entryID, radix: 16))")

guard let cfg = readConfigDescriptor(svc) else { print("Could not read configuration descriptor."); exit(1) }
let (patched, changed) = patch(cfg)
print("Configuration descriptor: \(cfg.count) bytes")
for c in changed { print("  patch: \(c)") }
if changed.isEmpty { print("  nothing to patch (already >= 8?)") }
print("  patched hex: " + patched.map { String(format: "%02x", $0) }.joined(separator: " "))

if dryRun { exit(0) }

let override: [String: Any] = [
    "descriptor": Data(patched),
    "index": 0,
    "languageID": 0,
]
let kr = IORegistryEntrySetCFProperty(svc, "kUSBDescriptorOverride" as CFString, override as CFDictionary)
print("IORegistryEntrySetCFProperty(kUSBDescriptorOverride) -> \(ioReturnString(kr))")
let readBack = IORegistryEntryCreateCFProperty(svc, "kUSBDescriptorOverride" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
print("read back: \(readBack == nil ? "absent" : "present")")

guard kr == kIOReturnSuccess, readBack != nil else {
    print("Property injection from user space is not accepted; a kext/dext personality with IOProviderMergeProperties is required.")
    exit(2)
}
if noReenumerate { exit(0) }
let kr2 = reenumerate(svc)
exit(kr2 == kIOReturnSuccess ? 0 : 3)
