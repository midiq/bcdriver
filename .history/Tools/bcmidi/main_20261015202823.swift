import CoreMIDI
import Foundation

// CoreMIDI control experiment: send BCL chains to a BCR2000/BCF2000 through
// Apple's USB-MIDI driver and verify every line via the device's 0x21 reply.
// Protocol notes: docs/bc-sysex-protocol.md

// MARK: - Options

struct Options {
    var command = "help"
    var port: String?
    var deviceID: UInt8 = 0x7F
    var lines = 200
    var lineLength = 60
    var mode = "sysex"          // sysex | packets
    var chunk = 3
    var gapUs = 0
    var ack = false
    var timeoutMs = 3000
    var preset: UInt8 = 0x7F
    var bclFile: String?
    var out: String?
    var verbose = false
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func next(_ flag: String) -> String {
        guard let v = it.next() else { fatalError("\(flag) needs a value") }
        return v
    }
    func num(_ flag: String) -> Int {
        let s = next(flag)
        if let v = Int(s) { return v }
        if s.hasPrefix("0x"), let v = Int(s.dropFirst(2), radix: 16) { return v }
        fatalError("\(flag): bad number \(s)")
    }
    while let a = it.next() {
        switch a {
        case "--port": o.port = next(a)
        case "--device-id": o.deviceID = UInt8(num(a))
        case "--lines": o.lines = num(a)
        case "--len": o.lineLength = num(a)
        case "--mode": o.mode = next(a)
        case "--chunk": o.chunk = num(a)
        case "--gap-us": o.gapUs = num(a)
        case "--ack": o.ack = true
        case "--timeout-ms": o.timeoutMs = num(a)
        case "--preset": o.preset = UInt8(num(a))
        case "--bcl": o.bclFile = next(a)
        case "--out": o.out = next(a)
        case "-v", "--verbose": o.verbose = true
        default:
            if a.hasPrefix("-") { fatalError("unknown option \(a)") }
            o.command = a
        }
    }
    return o
}

let opts = parseOptions()

func usage() -> Never {
    print("""
    usage: bcmidi <command> [options]

    commands:
      list                    list CoreMIDI sources and destinations
      identity                send Behringer + universal identity requests, print replies
      stress                  send a comment-only BCL chain, verify every 0x21 reply
      send --bcl FILE         send a BCL text file as a chain (one 0x20 per line)
      dump [--preset N]       Request Data (0x40); N = 0..31, 0x7E all, 0x7F temporary (default)

    options:
      --port SUBSTR           endpoint name filter (default: BCR2000 or BCF2000)
      --device-id N           SysEx device id (default 0x7F = any)
      --lines N --len L       stress: number/length of comment lines (default 200/60)
      --mode sysex|packets    MIDISendSysex vs MIDISend with explicit packets (default sysex)
      --chunk N               packets mode: bytes per MIDIPacket (default 3)
      --gap-us N              packets mode: timestamp spacing between packets (default 0)
                              sysex mode: sleep between lines
      --ack                   wait for each line's 0x21 before sending the next
      --timeout-ms N          reply wait (default 3000)
      --out FILE              dump: write received BCL to FILE
      -v                      log every message
    """)
    exit(2)
}

// MARK: - Time helpers

var timebase = mach_timebase_info()
mach_timebase_info(&timebase)
func hostTicks(ns: UInt64) -> UInt64 { ns * UInt64(timebase.denom) / UInt64(timebase.numer) }
func nanos(ticks: UInt64) -> UInt64 { ticks * UInt64(timebase.numer) / UInt64(timebase.denom) }
func nowNs() -> UInt64 { nanos(ticks: mach_absolute_time()) }

// MARK: - CoreMIDI setup

func endpointName(_ ep: MIDIObjectRef) -> String {
    var cf: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf) == noErr, let cf else { return "?" }
    return cf.takeRetainedValue() as String
}

func check(_ status: OSStatus, _ what: String) {
    guard status == noErr else { fatalError("\(what) failed: \(status)") }
}

var client = MIDIClientRef()
check(MIDIClientCreateWithBlock("bcmidi" as CFString, &client) { _ in }, "MIDIClientCreate")

if opts.command == "list" {
    print("Destinations:")
    for i in 0..<MIDIGetNumberOfDestinations() { print("  [\(i)] \(endpointName(MIDIGetDestination(i)))") }
    print("Sources:")
    for i in 0..<MIDIGetNumberOfSources() { print("  [\(i)] \(endpointName(MIDIGetSource(i)))") }
    exit(0)
}
if opts.command == "help" { usage() }

func findEndpoint(count: Int, get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef? {
    let filters = opts.port.map { [$0] } ?? ["BCR2000", "BCF2000"]
    for i in 0..<count {
        let ep = get(i)
        let name = endpointName(ep)
        if filters.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return ep }
    }
    return nil
}

guard let dest = findEndpoint(count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination),
      let source = findEndpoint(count: MIDIGetNumberOfSources(), get: MIDIGetSource) else {
    print("No matching BCR2000/BCF2000 endpoints; run `bcmidi list` or pass --port.")
    exit(1)
}
let destName = endpointName(dest)
let modelByte: UInt8 = destName.contains("BCF") ? 0x14 : 0x15
let revLine = modelByte == 0x14 ? "$rev F1" : "$rev R1"
print("Using destination \"\(destName)\" / source \"\(endpointName(source))\" (model 0x\(String(modelByte, radix: 16)))")

// MARK: - Receiver

final class Receiver {
    let cond = NSCondition()
    var replies: [Int: UInt8] = [:]       // BCL index -> error code
    var replyOrder: [Int] = []
    var identity: String?
    var universalIdentity: [UInt8]?
    var bclLines: [(Int, String)] = []
    var otherSysex = 0
    var lastReplyNs: UInt64 = 0

    private var buf: [UInt8] = []
    private var inSysex = false

    func handle(_ list: UnsafePointer<MIDIPacketList>) {
        for pkt in list.unsafeSequence() {
            let len = Int(pkt.pointee.length)
            let base = UnsafeRawPointer(pkt) + MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
            parse(UnsafeRawBufferPointer(start: base, count: len))
        }
    }

    private func parse(_ bytes: UnsafeRawBufferPointer) {
        for b in bytes {
            if b == 0xF0 { buf = [b]; inSysex = true; continue }
            guard inSysex else { continue }
            if b >= 0xF8 { continue }                       // realtime may interleave
            if b == 0xF7 { buf.append(b); inSysex = false; complete(buf); continue }
            if b & 0x80 != 0 { inSysex = false; continue }  // interrupted SysEx
            buf.append(b)
        }
    }

    private func complete(_ m: [UInt8]) {
        cond.lock(); defer { cond.unlock() }
        lastReplyNs = nowNs()
        if m.count >= 8, m[1] == 0x00, m[2] == 0x20, m[3] == 0x32 {
            let cmd = m[6]
            switch cmd {
            case 0x02:
                identity = String(bytes: m[7..<(m.count - 1)], encoding: .ascii)
            case 0x21 where m.count == 11:
                let idx = Int(m[7]) << 7 | Int(m[8])
                replies[idx] = m[9]
                replyOrder.append(idx)
                if opts.verbose { print("  <- reply idx=\(idx) err=\(m[9])") }
            case 0x20 where m.count >= 10:
                let idx = Int(m[7]) << 7 | Int(m[8])
                let text = String(bytes: m[9..<(m.count - 1)], encoding: .ascii) ?? "<non-ascii>"
                bclLines.append((idx, text))
                if opts.verbose { print("  <- bcl idx=\(idx) \(text)") }
            default:
                otherSysex += 1
                if opts.verbose { print("  <- sysex cmd=0x\(String(cmd, radix: 16)) len=\(m.count)") }
            }
        } else if m.count >= 6, m[1] == 0x7E, m[3] == 0x06, m[4] == 0x02 {
            universalIdentity = m
        } else {
            otherSysex += 1
        }
        cond.broadcast()
    }

    func wait(timeoutMs: Int, until predicate: () -> Bool) -> Bool {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date(timeIntervalSinceNow: Double(timeoutMs) / 1000)
        while !predicate() {
            if !cond.wait(until: deadline) { return predicate() }
        }
        return true
    }
}

let receiver = Receiver()
var inPort = MIDIPortRef()
check(MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { list, _ in receiver.handle(list) }, "MIDIInputPortCreate")
check(MIDIPortConnectSource(inPort, source, nil), "MIDIPortConnectSource")
var outPort = MIDIPortRef()
check(MIDIOutputPortCreate(client, "out" as CFString, &outPort), "MIDIOutputPortCreate")

// MARK: - Sender

func sysexFrame(cmd: UInt8, _ data: [UInt8]) -> [UInt8] {
    [0xF0, 0x00, 0x20, 0x32, opts.deviceID, modelByte, cmd] + data + [0xF7]
}

func bclFrame(index: Int, _ text: String) -> [UInt8] {
    sysexFrame(cmd: 0x20, [UInt8(index >> 7 & 0x7F), UInt8(index & 0x7F)] + Array(text.utf8))
}

final class Sender {
    private let listSize = 65536
    private let listBuf: UnsafeMutableRawPointer
    private let dest: MIDIEndpointRef
    private let outPort: MIDIPortRef
    private var cursorTicks: UInt64 = 0
    var bytesSent = 0
    var messagesSent = 0

    init(dest: MIDIEndpointRef, outPort: MIDIPortRef) {
        self.dest = dest
        self.outPort = outPort
        listBuf = .allocate(byteCount: listSize, alignment: MemoryLayout<MIDIPacketList>.alignment)
    }

    func send(_ bytes: [UInt8]) {
        bytesSent += bytes.count
        messagesSent += 1
        switch opts.mode {
        case "sysex": sendSysex(bytes)
        case "packets": sendPackets(bytes)
        default: fatalError("unknown --mode \(opts.mode)")
        }
    }

    private func sendSysex(_ bytes: [UInt8]) {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        data.initialize(from: bytes, count: bytes.count)
        defer { data.deallocate() }
        let sem = DispatchSemaphore(value: 0)
        var req = MIDISysexSendRequest(
            destination: dest, data: data, bytesToSend: UInt32(bytes.count), complete: false,
            reserved: (0, 0, 0),
            completionProc: { r in Unmanaged<DispatchSemaphore>.fromOpaque(r.pointee.completionRefCon!).takeUnretainedValue().signal() },
            completionRefCon: Unmanaged.passUnretained(sem).toOpaque())
        check(MIDISendSysex(&req), "MIDISendSysex")
        sem.wait()
        if opts.gapUs > 0 { usleep(UInt32(opts.gapUs)) }
    }

    private func sendPackets(_ bytes: [UInt8]) {
        let gapTicks = hostTicks(ns: UInt64(opts.gapUs) * 1000)
        let now = mach_absolute_time()
        if cursorTicks < now { cursorTicks = now }
        // Keep the scheduled lead bounded so the driver queue cannot run arbitrarily far ahead.
        let maxLead = hostTicks(ns: 250_000_000)
        if cursorTicks > now + maxLead { usleep(UInt32(nanos(ticks: cursorTicks - now - maxLead) / 1000)) }

        let list = listBuf.assumingMemoryBound(to: MIDIPacketList.self)
        var pkt = MIDIPacketListInit(list)
        var i = 0
        bytes.withUnsafeBufferPointer { p in
            while i < bytes.count {
                let n = min(opts.chunk, bytes.count - i)
                let ts: MIDITimeStamp = gapTicks == 0 ? 0 : cursorTicks
                // MIDIPacketListAdd returns NULL (as a non-optional pointer) when the list is full.
                var added = MIDIPacketListAdd(list, listSize, pkt, ts, n, p.baseAddress! + i)
                if UInt(bitPattern: added) == 0 {
                    check(MIDISend(outPort, dest, list), "MIDISend")
                    pkt = MIDIPacketListInit(list)
                    added = MIDIPacketListAdd(list, listSize, pkt, ts, n, p.baseAddress! + i)
                }
                pkt = added
                i += n
                cursorTicks += gapTicks
            }
        }
        check(MIDISend(outPort, dest, list), "MIDISend")
    }
}

let sender = Sender(dest: dest, outPort: outPort)

// MARK: - Commands

func describeMissing(_ missing: [Int]) -> String {
    guard !missing.isEmpty else { return "none" }
    var parts: [String] = []
    var start = missing[0], prev = missing[0]
    for m in missing.dropFirst() {
        if m == prev + 1 { prev = m; continue }
        parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
        start = m; prev = m
    }
    parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
    return parts.joined(separator: ",")
}

func sendChain(_ lines: [String]) {
    let t0 = nowNs()
    print("Sending \(lines.count) BCL lines, mode=\(opts.mode) chunk=\(opts.chunk) gap-us=\(opts.gapUs) ack=\(opts.ack)")
    var firstFailure: Int?
    for (idx, line) in lines.enumerated() {
        sender.send(bclFrame(index: idx, line))
        if opts.verbose { print("  -> idx=\(idx) \(line.prefix(40))") }
        if opts.ack {
            let ok = receiver.wait(timeoutMs: opts.timeoutMs) { receiver.replies[idx] != nil }
            if !ok {
                print("  no reply for idx=\(idx) within \(opts.timeoutMs) ms; stopping")
                firstFailure = idx
                break
            }
        }
    }
    let sentCount = firstFailure ?? lines.count
    let tSend = nowNs()
    // Settle: wait until all replies arrived or the device has been silent for the timeout.
    _ = receiver.wait(timeoutMs: opts.timeoutMs * 10) {
        receiver.replies.count >= sentCount || (receiver.lastReplyNs > 0 && nowNs() - receiver.lastReplyNs > UInt64(opts.timeoutMs) * 1_000_000)
    }
    let tEnd = nowNs()

    let missing = (0..<sentCount).filter { receiver.replies[$0] == nil }
    let errors = receiver.replies.filter { $0.value != 0 }.sorted { $0.key < $1.key }
    let outOfOrder = zip(receiver.replyOrder, receiver.replyOrder.dropFirst()).filter { $0.0 + 1 != $0.1 }.count
    let sendMs = Double(tSend - t0) / 1e6
    print("""

    Result
      lines sent      : \(sentCount) (\(sender.bytesSent) bytes)
      send time       : \(String(format: "%.1f", sendMs)) ms  (\(String(format: "%.0f", Double(sender.bytesSent) / sendMs * 1000)) B/s)
      total time      : \(String(format: "%.1f", Double(tEnd - t0) / 1e6)) ms
      replies         : \(receiver.replies.count)
      missing indices : \(describeMissing(missing))
      reply errors    : \(errors.isEmpty ? "none" : errors.map { "\($0.key):\($0.value)" }.joined(separator: " "))
      out-of-order    : \(outOfOrder)
      other sysex     : \(receiver.otherSysex)
      verdict         : \(missing.isEmpty && errors.isEmpty ? "PASS" : "FAIL")
    """)
}

switch opts.command {
case "identity":
    sender.send(sysexFrame(cmd: 0x01, []))
    let gotBC = receiver.wait(timeoutMs: opts.timeoutMs) { receiver.identity != nil }
    print("Behringer identity: \(gotBC ? receiver.identity! : "no reply")")
    sender.send([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7])
    let gotUni = receiver.wait(timeoutMs: opts.timeoutMs) { receiver.universalIdentity != nil }
    print("Universal identity: \(gotUni ? receiver.universalIdentity!.map { String(format: "%02X", $0) }.joined(separator: " ") : "no reply")")

case "stress":
    var lines = [revLine]
    for i in 0..<opts.lines {
        let head = "; stress \(String(format: "%05d", i)) "
        lines.append(head + String(repeating: "x", count: max(0, opts.lineLength - head.count)))
    }
    lines.append("$end")
    sendChain(lines)

case "send":
    guard let path = opts.bclFile, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("send requires --bcl FILE"); exit(2)
    }
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    let trimmed = lines.last?.isEmpty == true ? Array(lines.dropLast()) : lines
    sendChain(trimmed)

case "dump":
    print("Request Data preset=0x\(String(opts.preset, radix: 16))")
    let t0 = nowNs()
    sender.send(sysexFrame(cmd: 0x40, [opts.preset]))
    _ = receiver.wait(timeoutMs: opts.timeoutMs * 20) {
        receiver.bclLines.last?.1.trimmingCharacters(in: .whitespaces) == "$end"
            || (receiver.lastReplyNs > 0 && nowNs() - receiver.lastReplyNs > UInt64(opts.timeoutMs) * 1_000_000)
    }
    let ms = Double(nowNs() - t0) / 1e6
    let idxGaps = zip(receiver.bclLines, receiver.bclLines.dropFirst()).filter { $0.0.0 + 1 != $0.1.0 }.count
    print("Received \(receiver.bclLines.count) BCL lines in \(String(format: "%.0f", ms)) ms; index gaps: \(idxGaps); last: \(receiver.bclLines.last?.1 ?? "-")")
    let body = receiver.bclLines.map(\.1).joined(separator: "\n") + "\n"
    if let out = opts.out {
        try? body.write(toFile: out, atomically: true, encoding: .utf8)
        print("Wrote \(out)")
    } else {
        print(body)
    }

default:
    usage()
}
