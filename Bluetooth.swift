import Foundation
import IOBluetooth
import Darwin

let bmapChannel: BluetoothRFCOMMChannelID = 2
let get: UInt8 = 1, start: UInt8 = 5, status: UInt8 = 3, failed: UInt8 = 4
let result: UInt8 = 6, processing: UInt8 = 7
let deviceManagement: UInt8 = 4, connect: UInt8 = 1, disconnect: UInt8 = 2, listDevices: UInt8 = 4, deviceInfo: UInt8 = 5

struct Packet {
    let block: UInt8
    let function: UInt8
    let operation: UInt8
    let payload: [UInt8]

    init(function: UInt8, operation: UInt8, payload: [UInt8], block: UInt8 = deviceManagement) {
        self.block = block
        self.function = function
        self.operation = operation
        self.payload = payload
    }

    // Disconnect PROCESSING has a 0x21 prefix, ERROR has an error code
    var address: [UInt8] {
        let prefixed = operation == failed || (function == disconnect && operation == processing && payload.count == 7 && payload.first == 0x21)
        return Array(payload.dropFirst(prefixed ? 1 : 0).prefix(6))
    }

    var device: PairedDevice? {
        guard block == deviceManagement, function == deviceInfo, operation == status, payload.count >= 9 else { return nil }
        return PairedDevice(address: address, name: String(decoding: payload[9...], as: UTF8.self),
                            connected: payload[6] & 1 != 0, active: payload[6] & 2 != 0)
    }

    // bosectl reads the first byte of the battery STATUS payload as a percentage
    var batteryLevel: Int? {
        guard block == 2, function == 2, operation == status, let level = payload.first, level <= 100 else { return nil }
        return Int(level)
    }

    var pairedAddresses: [[UInt8]]? {
        guard block == deviceManagement, function == listDevices, operation == status,
              !payload.isEmpty, (payload.count - 1) % 6 == 0 else { return nil }
        let addresses = stride(from: 1, to: payload.count, by: 6).map { Array(payload[$0 ..< $0 + 6]) }
        return Set(addresses).count == addresses.count ? addresses : nil
    }
}

struct DeviceReading {
    let device: PairedDevice
    let requestedAt: Date
}

// One RFCOMM channel, owned only by the Bluetooth thread
final class BmapLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var channel: IOBluetoothRFCOMMChannel?
    private var unread: [UInt8] = []
    private var replies: [Packet] = []
    private var infoRequests: [[UInt8]: Date] = [:]
    private var readings: [[UInt8]: DeviceReading] = [:]
    private var receivedPacket = false
    var onDevice: ((DeviceReading) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onList: (([[UInt8]]) -> Void)?

    init?(device: IOBluetoothDevice) {
        super.init()
        var opened: IOBluetoothRFCOMMChannel?
        guard device.openRFCOMMChannelSync(&opened, withChannelID: bmapChannel, delegate: self) == kIOReturnSuccess,
              let opened else { return nil }
        channel = opened
    }

    var isOpen: Bool { channel?.isOpen() ?? false }

    init(channel: IOBluetoothRFCOMMChannel) {
        self.channel = channel
        super.init()
        channel.setDelegate(self)
    }

    // Reopen after a lost reply because BMAP has no request IDs
    func close() {
        let previous = channel
        channel = nil
        previous?.setDelegate(nil)
        previous?.close()
        infoRequests.removeAll()
    }

    // The Mac gets no disconnect reply, so check its physical connection
    func disconnectHost(_ address: [UInt8], timeout: TimeInterval = 3, cancelled: () -> Bool = { false },
                        isConnected: () -> Bool) -> ActionResult {
        let began = Date()
        let reply = request(disconnect, start, address, timeout: min(1, timeout), yielding: cancelled)
        if reply?.operation == failed { return .refused }
        while !cancelled() && isConnected() && Date().timeIntervalSince(began) < timeout { pump(0.02) }
        return isConnected() ? .timeout : .confirmed
    }

    deinit { close() }

    // Clear this command's replies without discarding pending Info
    @discardableResult
    func request(_ function: UInt8, _ operation: UInt8, _ payload: [UInt8] = [], timeout: TimeInterval = 5,
                 yielding: () -> Bool = { false }) -> Packet? {
        let address = Array(payload.suffix(6))
        replies.removeAll { $0.function == function && $0.address.starts(with: address) }
        guard write(function, operation, payload) else { close(); return nil }
        let reply: Packet? = wait(timeout, yielding: yielding) {
            self.replies.first {
                $0.function == function && $0.address.starts(with: address) &&
                (function != disconnect || $0.operation == failed || ($0.operation == result && $0.payload.count == 6)) &&
                (function != connect || $0.operation == failed || $0.operation == processing)
            }
        }
        if reply == nil { close() }
        return reply
    }

    func readDevice(_ address: [UInt8], cancelled: () -> Bool = { false }) -> PairedDevice? {
        let began = Date()
        requestInfo(address)
        let reading: PairedDevice? = wait(3, yielding: cancelled) {
            guard let reading = self.readings[address], reading.requestedAt >= began else { return nil }
            return reading.device
        }
        if reading == nil { close() }
        return reading
    }

    // Read known devices together and discover pairings separately
    func refresh(_ known: [[UInt8]], list: Bool, yielding: () -> Bool) -> [[UInt8]]? {
        guard !yielding() else { return nil }
        var addresses = known
        if list {
            guard let reply = request(listDevices, get, yielding: yielding),
                  let listed = reply.pairedAddresses else { return nil }
            addresses = listed
            onList?(listed)
        }
        defer { if !infoRequests.isEmpty { close() } }
        guard !yielding() else { return nil }
        let began = Date()
        for address in addresses {
            guard !yielding() else { return nil }
            requestInfo(address)
        }
        if !yielding() { _ = write(2, get, [], block: 2) }
        _ = wait(3, yielding: yielding) {
            addresses.allSatisfy { (self.readings[$0]?.requestedAt ?? .distantPast) >= began } ? true : nil
        }
        return list ? addresses : nil
    }

    // Accept connected replies during the polling pause too
    func waitUntilConnected(_ address: [UInt8], since began: Date, timeout: TimeInterval = 20,
                            cancelled: () -> Bool = { false }, reopen: () -> BmapLink? = { nil }) -> ActionResult {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var observer = self
        while !cancelled() && Date() < deadline {
            if !observer.isOpen {
                guard let replacement = reopen(), replacement.isOpen else { return .timeout }
                observer = replacement
            }
            let requestedAt = Date()
            observer.requestInfo(address)
            let answered: Bool? = observer.wait(min(observer.receivedPacket ? 1 : 3, deadline.timeIntervalSinceNow), yielding: cancelled) {
                if observer.connectionResult(address, since: began) != nil { return true }
                return (observer.readings[address]?.requestedAt ?? .distantPast) >= requestedAt ? true : nil
            }
            if cancelled() { observer.close(); return .timeout }
            if let result = observer.connectionResult(address, since: began) { return result }
            if answered == nil { observer.close(); continue }
            if let result = observer.wait(min(0.15, deadline.timeIntervalSinceNow), yielding: cancelled, until: {
                observer.connectionResult(address, since: began)
            }) { return result }
        }
        observer.close()
        return .timeout
    }

    private func connectionResult(_ address: [UInt8], since began: Date) -> ActionResult? {
        if replies.contains(where: { $0.function == connect && $0.address == address && $0.operation == failed }) {
            return .refused
        }
        if let reading = readings[address], reading.requestedAt >= began, reading.device.connected {
            return .confirmed
        }
        return nil
    }

    private func requestInfo(_ address: [UInt8]) {
        guard infoRequests[address] == nil else { return }
        infoRequests[address] = Date()
        if !write(deviceInfo, get, address) { close() }
    }

    private func write(_ function: UInt8, _ operation: UInt8, _ payload: [UInt8], block: UInt8 = deviceManagement) -> Bool {
        var bytes = [block, function, operation, UInt8(payload.count)] + payload
        return channel?.writeSync(&bytes, length: UInt16(bytes.count)) == kIOReturnSuccess
    }

    private func wait<Result>(_ timeout: TimeInterval, yielding: () -> Bool = { false }, until result: () -> Result?) -> Result? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while isOpen && Date() < deadline {
            if let found = result() { return found }
            if yielding() { return nil }
            pump(0.02)
        }
        return result()
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: deadline) }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel === channel else { return }
        channel = nil
        onClose?()
    }

    // Timestamp Info requests so stale replies cannot undo a confirmed action
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard rfcommChannel === channel else { return }
        unread += UnsafeRawBufferPointer(start: dataPointer, count: dataLength)
        while unread.count >= 4 {
            let end = 4 + Int(unread[3])
            guard unread.count >= end else { break }
            let packet = Packet(function: unread[1], operation: unread[2] & 0x0F, payload: Array(unread[4 ..< end]), block: unread[0])
            receivedPacket = true
            if let level = packet.batteryLevel { onBattery?(level) }
            if packet.block == deviceManagement {
                if packet.function == deviceInfo {
                    if let requestedAt = infoRequests.removeValue(forKey: packet.address) {
                        if let device = packet.device {
                            let reading = DeviceReading(device: device, requestedAt: requestedAt)
                            readings[device.address] = reading
                            onDevice?(reading)
                        }
                    }
                } else {
                    replies.append(packet)
                    if replies.count > 128 { replies.removeFirst() }
                }
            }
            unread.removeFirst(end)
        }
    }
}

func findHeadphones(defaults: UserDefaults = .standard,
                    lookup: (String) -> IOBluetoothDevice? = { IOBluetoothDevice(addressString: $0) },
                    scan: () -> String? = { scanHeadphones() }) -> IOBluetoothDevice? {
    if let saved = defaults.string(forKey: "headphones"),
       let device = lookup(saved), device.isPaired() { return device }
    defaults.removeObject(forKey: "headphones")
    guard let address = scan(), let device = lookup(address) else { return nil }
    defaults.set(address, forKey: "headphones")
    return device
}

// Isolate pairedDevices because it breaks isConnected in the calling process
func scanHeadphones(timeout: TimeInterval = 3, cancelled: () -> Bool = { false }, scan: Process = Process()) -> String? {
    guard !cancelled() else { return nil }
    let output = Pipe()
    defer {
        output.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
    }
    if scan.executableURL == nil { scan.executableURL = Bundle.main.executableURL }
    if scan.arguments == nil { scan.arguments = ["--scan"] }
    scan.standardOutput = output
    let finished = DispatchSemaphore(value: 0)
    scan.terminationHandler = { _ in finished.signal() }
    guard (try? scan.run()) != nil else { return nil }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while finished.wait(timeout: .now() + 0.02) == .timedOut {
        if cancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
            // A stuck Bluetooth call may ignore SIGTERM
            if scan.isRunning { kill(scan.processIdentifier, SIGKILL) }
            return nil
        }
    }
    guard !cancelled(), scan.terminationStatus == 0 else { return nil }
    let address = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !address.isEmpty else { return nil }
    return address
}

// Skip repeated scans while no headphones are paired, since each scan starts a process
final class ScanBackoff {
    private var nextScan: TimeInterval = 0

    func run(delay: TimeInterval = 10, cancelled: () -> Bool, _ scan: () -> String?) -> String? {
        guard ProcessInfo.processInfo.systemUptime >= nextScan else { return nil }
        let address = scan()
        if address == nil && !cancelled() { nextScan = ProcessInfo.processInfo.systemUptime + delay }
        return address
    }
}

// Only the Bluetooth thread scans
let headphoneScans = ScanBackoff()

private let hostAddressLock = NSLock()
private var hostAddressCache: [UInt8] = []

// The controller address never changes, so read it once instead of on every refresh
func macAddress() -> [UInt8] {
    if let cached = hostAddressLock.withLock({ hostAddressCache.isEmpty ? nil : hostAddressCache }) { return cached }
    let text = IOBluetoothHostController.default()?.addressAsString() ?? ""
    let address = text.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    if address.count == 6 { hostAddressLock.withLock { hostAddressCache = address } }
    return address
}

// Run jobs in the default run-loop mode required by IOBluetooth callbacks
final class BluetoothThread: Thread {
    private let lock = NSLock()
    private var actions: [() -> Void] = []
    private var refreshes: [() -> Void] = []
    private var busy = false

    var actionQueued: Bool { lock.withLock { !actions.isEmpty } }

    override func main() {
        RunLoop.current.add(NSMachPort(), forMode: .default)
        while !isCancelled { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    func async(action: Bool = false, _ job: @escaping () -> Void) {
        lock.withLock {
            if action { actions.append(job) } else { refreshes.append(job) }
        }
        perform(#selector(drain), on: self, with: nil, waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue])
    }

    // Run-loop callbacks may enqueue work, but never execute it inside a running job
    @objc private func drain() {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        while let job = nextJob() { job() }
    }

    private func nextJob() -> (() -> Void)? {
        lock.withLock {
            if !actions.isEmpty { return actions.removeFirst() }
            return refreshes.isEmpty ? nil : refreshes.removeFirst()
        }
    }
}
