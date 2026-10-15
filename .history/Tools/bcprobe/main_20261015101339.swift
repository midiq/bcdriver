import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

// Gate A probe: capture descriptors and test whether a user-space process can
// open the BCR2000/BCF2000 USB-MIDI interface while MIDIServer holds it.
// Performs no transfers.

let behringerVendorID: UInt16 = 0x1397

// IOUSBLib UUID macros are not importable from Swift; literal values from IOUSBLib.h.
func uuidBytes(_ s: String) -> CFUUIDBytes {
    CFUUIDGetUUIDBytes(CFUUIDCreateFromString(nil, s as CFString))
}
let cfPlugInInterfaceID = uuidBytes("C244E858-109C-11D4-91D4-0050E4C6426F")
let usbDeviceUserClientTypeID = CFUUIDCreateFromString(nil, "9DC7B780-9EC0-11D4-A54F-000A27052861" as CFString)!
let usbInterfaceUserClientTypeID = CFUUIDCreateFromString(nil, "2D9786C6-9EF3-11D4-AD51-000A27052861" as CFString)!
let usbDeviceInterfaceID187 = uuidBytes("3C9EE1EB-2402-11B2-8E7E-000A27801E86")
let usbInterfaceInterfaceID190 = uuidBytes("8FDB8455-74A6-11D6-97B1-003065D3608E")
let cfPlugInInterfaceCFUUID = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)!

typealias DeviceInterface = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface187>?>
typealias InterfaceInterface = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface190>?>

let kIOReturnExclusiveAccessValue: IOReturn = IOReturn(bitPattern: 0xe00002c5)
let kIOReturnNotPermittedValue: IOReturn = IOReturn(bitPattern: 0xe00002e2)

func ioReturnString(_ kr: IOReturn) -> String {
    switch kr {
    case kIOReturnSuccess: return "kIOReturnSuccess"
    case kIOReturnExclusiveAccessValue: return "kIOReturnExclusiveAccess"
    case kIOReturnNotPermittedValue: return "kIOReturnNotPermitted"
    default: return String(format: "0x%08x", UInt32(bitPattern: kr))
    }
}

func hex(_ v: UInt16) -> String { String(format: "0x%04x", v) }
func hex(_ v: UInt8) -> String { String(format: "0x%02x", v) }

let args = CommandLine.arguments.dropFirst()
let trySeize = args.contains("--seize")
let tryOpen = !args.contains("--descriptors-only")

// MARK: - Plugin helpers

func queryInterface<T>(service: io_service_t, clientType: CFUUID, interfaceID: CFUUIDBytes, as _: T.Type)
    -> UnsafeMutablePointer<UnsafeMutablePointer<T>?>? {
    var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    let kr = IOCreatePlugInInterfaceForService(service, clientType, cfPlugInInterfaceCFUUID, &plugin, &score)
    guard kr == kIOReturnSuccess, let plugin else {
        print("  IOCreatePlugInInterfaceForService failed: \(ioReturnString(kr))")
        return nil
    }
    defer { IODestroyPlugInInterface(plugin) }
    var raw: LPVOID?
    let hr = plugin.pointee!.pointee.QueryInterface(plugin, interfaceID, &raw)
    guard hr == S_OK, let raw else {
        print("  QueryInterface failed: \(hr)")
        return nil
    }
    return raw.assumingMemoryBound(to: UnsafeMutablePointer<T>?.self)
}

// MARK: - Descriptor parsing

func dumpConfigDescriptor(_ bytes: UnsafeRawBufferPointer) {
    var i = 0
    var inMIDIStreaming = false
    while i + 1 < bytes.count {
        let len = Int(bytes[i]), type = bytes[i + 1]
        guard len >= 2, i + len <= bytes.count else { print("  malformed descriptor at \(i)"); return }
        let d = UnsafeRawBufferPointer(rebasing: bytes[i..<i + len])
        switch type {
        case 0x02:
            let total = UInt16(d[2]) | UInt16(d[3]) << 8
            print("  CONFIG: wTotalLength=\(total) bNumInterfaces=\(d[4]) bConfigurationValue=\(d[5]) bmAttributes=\(hex(d[7])) bMaxPower=\(Int(d[8]) * 2)mA")
        case 0x04:
            inMIDIStreaming = d[5] == 1 && d[6] == 3
            print("  INTERFACE \(d[2]) alt=\(d[3]): class=\(hex(d[5])) subclass=\(hex(d[6])) protocol=\(hex(d[7])) numEndpoints=\(d[4])\(inMIDIStreaming ? "  [MIDIStreaming]" : "")")
        case 0x05:
            let addr = d[2], attr = d[3]
            let mps = UInt16(d[4]) | UInt16(d[5]) << 8
            let dir = addr & 0x80 != 0 ? "IN " : "OUT"
            let xfer = ["control", "isochronous", "bulk", "interrupt"][Int(attr & 3)]
            print("    ENDPOINT \(hex(addr)) \(dir) \(xfer) wMaxPacketSize=\(mps) bInterval=\(d[6])")
        case 0x24 where inMIDIStreaming:
            switch d[2] {
            case 0x01:
                let bcd = UInt16(d[3]) | UInt16(d[4]) << 8
                let total = UInt16(d[5]) | UInt16(d[6]) << 8
                print("    MS_HEADER bcdMSC=\(hex(bcd)) wTotalLength=\(total)")
            case 0x02:
                print("    MIDI_IN_JACK id=\(d[4]) type=\(d[3] == 1 ? "embedded" : "external")")
            case 0x03:
                let pins = Int(d[5])
                var src: [String] = []
                for p in 0..<pins where 6 + p * 2 + 1 < len { src.append("\(d[6 + p * 2]).\(d[7 + p * 2])") }
                print("    MIDI_OUT_JACK id=\(d[4]) type=\(d[3] == 1 ? "embedded" : "external") sources=[\(src.joined(separator: ", "))]")
            default:
                print("    CS_INTERFACE subtype=\(hex(d[2])) len=\(len)")
            }
        case 0x24:
            print("    CS_INTERFACE (audio) subtype=\(hex(d[2])) len=\(len)")
        case 0x25:
            let n = Int(d[3])
            var jacks: [String] = []
            for j in 0..<n where 4 + j < len { jacks.append("\(d[4 + j])") }
            print("      MS_GENERAL bNumEmbMIDIJack=\(n) jacks=[\(jacks.joined(separator: ", "))]")
        default:
            print("  descriptor type=\(hex(type)) len=\(len)")
        }
        i += len
    }
}

func hexDump(_ bytes: UnsafeRawBufferPointer) {
    for row in stride(from: 0, to: bytes.count, by: 16) {
        let slice = bytes[row..<min(row + 16, bytes.count)]
        let hexes = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        print(String(format: "    %04x  %@", row, hexes))
    }
}

// MARK: - Interface ownership test

func probeInterfaces(_ dev: DeviceInterface) {
    var req = IOUSBFindInterfaceRequest(
        bInterfaceClass: UInt16(kIOUSBFindInterfaceDontCare),
        bInterfaceSubClass: UInt16(kIOUSBFindInterfaceDontCare),
        bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
        bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))
    var iter: io_iterator_t = 0
    let kr = dev.pointee!.pointee.CreateInterfaceIterator(dev, &req, &iter)
    guard kr == kIOReturnSuccess else { print("  CreateInterfaceIterator failed: \(ioReturnString(kr))"); return }
    defer { IOObjectRelease(iter) }

    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        guard let intf = queryInterface(service: svc, clientType: usbInterfaceUserClientTypeID,
                                        interfaceID: usbInterfaceInterfaceID190, as: IOUSBInterfaceInterface190.self)
        else { continue }
        defer { _ = intf.pointee!.pointee.Release(intf) }
        let v = intf.pointee!.pointee

        var num: UInt8 = 0, cls: UInt8 = 0, sub: UInt8 = 0, eps: UInt8 = 0
        _ = v.GetInterfaceNumber(intf, &num)
        _ = v.GetInterfaceClass(intf, &cls)
        _ = v.GetInterfaceSubClass(intf, &sub)
        _ = v.GetNumEndpoints(intf, &eps)
        let isMIDI = cls == 1 && sub == 3
        print("\nInterface \(num): class=\(hex(cls)) subclass=\(hex(sub)) endpoints=\(eps)\(isMIDI ? "  [MIDIStreaming]" : "")")
        guard isMIDI, tryOpen else { continue }

        var opened = false
        let krOpen = v.USBInterfaceOpen(intf)
        print("  USBInterfaceOpen      -> \(ioReturnString(krOpen))")
        opened = krOpen == kIOReturnSuccess
        if !opened, trySeize {
            let krSeize = v.USBInterfaceOpenSeize(intf)
            print("  USBInterfaceOpenSeize -> \(ioReturnString(krSeize))")
            opened = krSeize == kIOReturnSuccess
        }
        guard opened else { continue }

        for pipe in 1...UInt8(max(eps, 1)) {
            var dir: UInt8 = 0, no: UInt8 = 0, xfer: UInt8 = 0, interval: UInt8 = 0
            var mps: UInt16 = 0
            let krPipe = v.GetPipeProperties(intf, pipe, &dir, &no, &xfer, &mps, &interval)
            guard krPipe == kIOReturnSuccess else { print("  pipe \(pipe): GetPipeProperties \(ioReturnString(krPipe))"); continue }
            let dirS = ["OUT", "IN", "none", "any"][Int(min(dir, 3))]
            let xferS = ["control", "isochronous", "bulk", "interrupt", "any"][Int(min(xfer, 4))]
            print("  pipe \(pipe): ep=\(no) \(dirS) \(xferS) maxPacket=\(mps) interval=\(interval)")
        }
        let krClose = v.USBInterfaceClose(intf)
        print("  USBInterfaceClose     -> \(ioReturnString(krClose))")
    }
}

// MARK: - Device enumeration

func probeDevice(_ svc: io_service_t) {
    guard let dev = queryInterface(service: svc, clientType: usbDeviceUserClientTypeID,
                                   interfaceID: usbDeviceInterfaceID187, as: IOUSBDeviceInterface187.self)
    else { return }
    defer { _ = dev.pointee!.pointee.Release(dev) }
    let v = dev.pointee!.pointee

    var vid: UInt16 = 0, pid: UInt16 = 0, rel: UInt16 = 0
    var numConf: UInt8 = 0, speed: UInt8 = 0
    var addr: USBDeviceAddress = 0
    _ = v.GetDeviceVendor(dev, &vid)
    _ = v.GetDeviceProduct(dev, &pid)
    _ = v.GetDeviceReleaseNumber(dev, &rel)
    _ = v.GetNumberOfConfigurations(dev, &numConf)
    _ = v.GetDeviceSpeed(dev, &speed)
    _ = v.GetDeviceAddress(dev, &addr)
    let speedS = ["low", "full", "high", "super"][Int(min(speed, 3))]
    print("Device VID=\(hex(vid)) PID=\(hex(pid)) bcdDevice=\(hex(rel)) speed=\(speedS) address=\(addr) configurations=\(numConf)")

    for c in 0..<numConf {
        var desc: IOUSBConfigurationDescriptorPtr?
        let kr = v.GetConfigurationDescriptorPtr(dev, c, &desc)
        guard kr == kIOReturnSuccess, let desc else { print("  GetConfigurationDescriptorPtr(\(c)): \(ioReturnString(kr))"); continue }
        let total = Int(UInt16(littleEndian: desc.pointee.wTotalLength))
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(desc), count: total)
        print("\nConfiguration descriptor \(c) (\(total) bytes):")
        dumpConfigDescriptor(bytes)
        print("  raw:")
        hexDump(bytes)
    }

    probeInterfaces(dev)
}

func findDevices() -> [io_service_t] {
    for className in ["IOUSBHostDevice", "IOUSBDevice"] {
        let matching = IOServiceMatching(className)! as NSMutableDictionary
        if !args.contains("--all") { matching[kUSBVendorID] = NSNumber(value: behringerVendorID) }
        if args.contains("--debug") { print("matching(\(className)): \(matching)") }
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard kr == kIOReturnSuccess else {
            print("IOServiceGetMatchingServices(\(className)) failed: \(ioReturnString(kr))")
            continue
        }
        defer { IOObjectRelease(iter) }
        var found: [io_service_t] = []
        while case let svc = IOIteratorNext(iter), svc != 0 { found.append(svc) }
        if !found.isEmpty { return found }
    }
    return []
}

print("bcprobe: Behringer USB-MIDI Gate A probe (open test: \(tryOpen ? "yes" : "no"), seize: \(trySeize ? "yes" : "no"))")
let devices = findDevices()
guard !devices.isEmpty else {
    print("No Behringer (VID 0x1397) USB devices found.")
    exit(1)
}
for svc in devices {
    probeDevice(svc)
    IOObjectRelease(svc)
}
print("\n\(devices.count) device(s) probed.")
