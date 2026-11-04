import Foundation
import IOBluetooth

final class FakeHeadphones: IOBluetoothDevice {
    var paired = true
    override func isPaired() -> Bool { paired }
}

final class FakeChannel: IOBluetoothRFCOMMChannel {
    var opened = true
    weak var receiver: BmapLink?
    var onWrite: (([UInt8]) -> Void)?
    var writes: [[UInt8]] = []

    override func isOpen() -> Bool { opened }
    override func close() -> IOReturn { opened = false; return kIOReturnSuccess }
    override func setDelegate(_ delegate: Any!) -> IOReturn {
        receiver = delegate as? BmapLink
        return kIOReturnSuccess
    }
    override func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn {
        guard opened else { return kIOReturnError }
        let bytes = Array(UnsafeRawBufferPointer(start: data, count: Int(length)))
        writes.append(bytes)
        onWrite?(bytes)
        return kIOReturnSuccess
    }
    func reply(_ function: UInt8, _ operation: UInt8, _ payload: [UInt8], after delay: TimeInterval = 0.005) {
        let receiver = receiver
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [self] _ in
            var bytes = [deviceManagement, function, operation, UInt8(payload.count)] + payload
            bytes.withUnsafeMutableBytes { buffer in
                receiver?.rfcommChannelData(self, data: buffer.baseAddress!, length: buffer.count)
            }
        }
    }
}

@main
struct BehaviorTests {
    static let phone: [UInt8] = [1, 2, 3, 4, 5, 6]
    static let computer: [UInt8] = [6, 5, 4, 3, 2, 1]

    static func main() {
        if CommandLine.arguments.contains("--scan-stall") { Thread.sleep(forTimeInterval: 30); return }
        if CommandLine.arguments.contains("--scan-success") { print("test-headphones"); return }
        testReplyAddresses()
        testBatteryReply()
        testConfirmedState()
        testMissingDevicesAndOrder()
        testDeviceSymbols()
        try! testCacheValidation()
        testMalformedInfo()
        testActionPriority()
        testFirstConfirmationAndFreshness()
        testAuthoritativeMembership()
        testLostInfoRecovery()
        testLateCommandReply()
        testConnectionPolling()
        testListValidationAndEarlyOrder()
        testHostDisconnectFailure()
        testEarlyPanelPlacement()
        testShadowPlacement()
        testLostConnectionPoll()
        testColdConnectionPoll()
        testReadingExpiry()
        testPowerBoundary()
        testStableRediscovery()
        testDistinctNames()
        testReplacementDiscovery()
        testScanLifetime()
        testScanActionPriority()
        testCancelledWaits()
        print("Passed 27 hardware-free behavior checks")
    }

    // Test that successful scans return output and timed-out or cancelled children are killed
    static func testScanLifetime() {
        let success = Process()
        success.arguments = ["--scan-success"]
        precondition(scanHeadphones(scan: success) == "test-headphones")
        for cancel in [false, true] {
            let child = Process()
            child.arguments = ["--scan-stall"]
            let began = Date()
            precondition(scanHeadphones(timeout: cancel ? 3 : 0.1,
                                       cancelled: { cancel && Date().timeIntervalSince(began) > 0.1 }, scan: child) == nil)
            precondition(Date().timeIntervalSince(began) < 0.5)
            child.waitUntilExit()
            precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        }
        let cancelled = Process()
        precondition(scanHeadphones(cancelled: { true }, scan: cancelled) == nil && !cancelled.isRunning)
    }

    // Test that a queued action kills the scanning child and runs without waiting for its timeout
    static func testScanActionPriority() {
        let thread = BluetoothThread()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let child = Process()
        child.arguments = ["--scan-stall"]
        thread.start()
        defer { thread.cancel(); thread.async {} }
        thread.async {
            var signalled = false
            precondition(scanHeadphones(cancelled: {
                if child.isRunning && !signalled { signalled = true; started.signal() }
                return thread.actionQueued
            }, scan: child) == nil)
        }
        precondition(started.wait(timeout: .now() + 1) == .success)
        thread.async(action: true) { finished.signal() }
        precondition(finished.wait(timeout: .now() + 0.5) == .success)
        child.waitUntilExit()
        precondition(child.terminationStatus == SIGKILL)
    }

    // Test that cancellation interrupts each command wait so shutdown can release the borrowed slot
    static func testCancelledWaits() {
        for operation in 0..<4 {
            let channel = FakeChannel()
            let link = BmapLink(channel: channel)
            let began = Date()
            let cancelled = { Date().timeIntervalSince(began) > 0.05 }
            switch operation {
            case 0: precondition(link.readDevice(phone, cancelled: cancelled) == nil)
            case 1: precondition(link.request(connect, start, [0] + phone, yielding: cancelled) == nil)
            case 2: precondition(link.disconnectHost(computer, cancelled: cancelled, isConnected: { true }) == .timeout)
            default: precondition(link.waitUntilConnected(phone, since: began, cancelled: cancelled) == .timeout)
            }
            precondition(Date().timeIntervalSince(began) < 0.3 && !link.isOpen)
        }
    }

    // Test that shadow space preserves the visible panel's size, anchor and clickable bounds
    static func testShadowPlacement() {
        let content = CGSize(width: 256, height: 347)
        let window = PanelLayout.windowSize(for: content)
        precondition(PanelLayout.contentSize(in: window) == content)
        let origin = CGPoint(x: 300, y: 1042)
        let windowOrigin = PanelLayout.windowOrigin(for: origin)
        let rectangle = PanelLayout.contentRect(in: window)
        precondition(windowOrigin.x + rectangle.minX == origin.x)
        precondition(windowOrigin.y - window.height + rectangle.maxY == origin.y)
        precondition(!rectangle.contains(CGPoint(x: 16, y: 100)))
        precondition(rectangle.contains(CGPoint(x: 50, y: 100)))
    }

    // Test that discovery replaces a forgotten pair but keeps an offline pair
    static func testReplacementDiscovery() {
        let suite = "headphone-discovery-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old", forKey: "headphones")
        let old = FakeHeadphones()
        let replacement = FakeHeadphones()
        var scans = 0
        let lookup: (String) -> IOBluetoothDevice? = { $0 == "old" ? old : replacement }
        let scan: () -> String? = { scans += 1; return "replacement" }
        precondition(findHeadphones(defaults: defaults, lookup: lookup, scan: scan) === old && scans == 0)
        old.paired = false
        precondition(findHeadphones(defaults: defaults, lookup: lookup, scan: scan) === replacement && scans == 1)
        precondition(defaults.string(forKey: "headphones") == "replacement")
        precondition(findHeadphones(defaults: defaults, lookup: lookup, scan: scan) === replacement && scans == 1)
    }

    // Test that a new channel allows time for its first reply
    static func testColdConnectionPoll() {
        let channel = FakeChannel()
        let link = BmapLink(channel: channel)
        channel.onWrite = { bytes in
            if bytes[1] == deviceInfo {
                channel.reply(deviceInfo, status, phone + [1, 0, 0] + Array("Phone".utf8), after: 2.1)
            }
        }
        precondition(link.waitUntilConnected(phone, since: Date(), timeout: 2.5) == .confirmed)
        precondition(channel.writes.count == 1)
    }

    // Test that startup anchors are rejected and valid panels remain within either screen
    static func testEarlyPanelPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 40, width: 1920, height: 1010)
        let size = CGSize(width: 256, height: 347)
        precondition(panelOrigin(anchor: .zero, screen: screen, visible: visible, size: size) == nil)
        precondition(panelOrigin(anchor: CGRect(x: 0, y: -100, width: 38, height: 24), screen: screen, visible: visible, size: size) == nil)
        for anchorHeight in [CGFloat(12), 24] {
            let point = panelOrigin(anchor: CGRect(x: 1900, y: 1053, width: 18, height: anchorHeight), screen: screen, visible: visible, size: size)!
            precondition(point == CGPoint(x: 1656, y: 1042))
        }
        let secondary = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let secondaryVisible = CGRect(x: -1920, y: -200, width: 1920, height: 1050)
        precondition(panelOrigin(anchor: CGRect(x: -300, y: 853, width: 38, height: 24), screen: secondary, visible: secondaryVisible, size: size) == CGPoint(x: -300, y: 842))
        let anchor = CGRect(x: 1700, y: 1053, width: 38, height: 24)
        precondition(panelOrigin(anchor: anchor, screen: screen, visible: screen, size: size)?.y == 1042)
        precondition(panelOrigin(anchor: anchor, screen: screen, visible: CGRect(x: 0, y: 0, width: 1920, height: 1043), size: size)?.y == 1035)
    }

    // Test that one lost poll resumes on a fresh channel without resending Connect
    static func testLostConnectionPoll() {
        let lost = FakeChannel()
        let first = BmapLink(channel: lost)
        lost.onWrite = { bytes in
            if bytes[1] == connect { lost.reply(connect, processing, phone) }
        }
        precondition(first.request(connect, start, [0] + phone)?.operation == processing)
        let replacement = FakeChannel()
        let second = BmapLink(channel: replacement)
        replacement.onWrite = { bytes in
            if bytes[1] == deviceInfo { replacement.reply(deviceInfo, status, phone + [1, 0, 0] + Array("Phone".utf8)) }
        }
        let began = Date()
        var reopenCount = 0
        let result = first.waitUntilConnected(phone, since: began, timeout: 3, reopen: {
            precondition(!first.isOpen)
            reopenCount += 1
            return second
        })
        precondition(result == .confirmed && reopenCount == 1)
        precondition(Date().timeIntervalSince(began) < 1.3)
        precondition((lost.writes + replacement.writes).filter { $0[1] == connect }.count == 1)
        print("Lost connection poll recovered seconds", Date().timeIntervalSince(began))
    }

    // Test that connection readings expire
    static func testReadingExpiry() {
        var state = DeviceState()
        let began = Date()
        state.merge(DeviceReading(device: PairedDevice(address: phone, name: "Phone", connected: true), requestedAt: began))
        precondition(state.isFresh(phone, at: began.addingTimeInterval(4)))
        precondition(!state.isFresh(phone, at: began.addingTimeInterval(6)))
        state.confirm(phone, connected: true, at: began)
        state.invalidateReadings()
        state.merge(DeviceReading(device: PairedDevice(address: phone, name: "Phone"), requestedAt: began.addingTimeInterval(1)))
        precondition(!state.devices[0].connected)
    }

    // Test that old callbacks and queued actions stay invalid after power returns
    static func testPowerBoundary() {
        let session = WorkSession()
        session.begin(available: true)
        let queued = session.current
        precondition(session.accepts(queued))
        session.begin(available: false)
        precondition(!session.accepts(queued) && !session.accepts(session.current))
        session.begin(available: true)
        precondition(!session.accepts(queued) && session.accepts(session.current))
    }

    // Test that learning television names cannot move rows on an unchanged list
    static func testStableRediscovery() {
        var state = DeviceState()
        let television: [UInt8] = [0, 1, 2, 3, 4, 5]
        state.reconcileOrder([phone, computer, television], computer: computer)
        for device in [PairedDevice(address: television, name: "TV"), PairedDevice(address: phone, name: "Phone"), PairedDevice(address: computer, name: "Computer")] {
            state.merge(DeviceReading(device: device, requestedAt: Date()))
        }
        let previous = state.devices
        state.reconcileOrder([television, phone, computer], computer: computer)
        precondition(state.devices == previous && state.devices.map(\.address) == [computer, phone, television])
    }

    // Test that colliding or empty shortened names retain their full identity
    static func testDistinctNames() {
        var state = DeviceState()
        state.devices = [PairedDevice(address: phone, name: "Alice’s iPhone"), PairedDevice(address: computer, name: "Bob's iPhone")]
        precondition(state.devices.map { state.displayName(for: $0) } == ["Alice’s iPhone", "Bob's iPhone"])
        precondition(PairedDevice(address: phone, name: "Sam’s  ").displayName == "Sam’s  ")
        precondition(PairedDevice(address: phone, name: "李’s Phone").displayName == "Phone")
    }

    // Test that processing and error prefixes do not become part of the device address
    static func testReplyAddresses() {
        let pending = Packet(function: disconnect, operation: processing, payload: [0x21] + phone)
        let refusal = Packet(function: connect, operation: failed, payload: [13] + phone)
        let completed = Packet(function: disconnect, operation: result, payload: phone)
        precondition(pending.address == phone && refusal.address == phone && completed.address == phone)
        let info = Packet(function: deviceInfo, operation: status, payload: phone + [3, 0, 0] + Array("iPhone".utf8))
        precondition(info.device?.connected == true && info.device?.active == true)
        precondition(info.device?.name == "iPhone")
        precondition(Packet(function: deviceInfo, operation: status, payload: phone).device == nil)
    }

    // Test that battery STATUS uses the first byte and ignores errors and unknown values
    static func testBatteryReply() {
        precondition(Packet(function: 2, operation: status, payload: [80, 0], block: 2).batteryLevel == 80)
        precondition(Packet(function: 2, operation: status, payload: [255], block: 2).batteryLevel == nil)
        precondition(Packet(function: 2, operation: failed, payload: [13], block: 2).batteryLevel == nil)
        precondition(Packet(function: 2, operation: status, payload: [], block: 2).batteryLevel == nil)
    }

    // Test that older and lagging Info cannot undo a confirmation, but later changes still apply
    static func testConfirmedState() {
        var state = DeviceState()
        let date = Date(timeIntervalSince1970: 100)
        let disconnected = PairedDevice(address: phone, name: "iPhone")
        state.devices = [disconnected]
        state.confirm(phone, connected: true, at: date)
        state.merge(DeviceReading(device: disconnected, requestedAt: date.addingTimeInterval(-1)))
        precondition(state.devices[0].connected)
        state.merge(DeviceReading(device: disconnected, requestedAt: date.addingTimeInterval(1)))
        precondition(state.devices[0].connected)
        state.merge(DeviceReading(device: disconnected, requestedAt: date.addingTimeInterval(3)))
        precondition(!state.devices[0].connected)
        state.merge(DeviceReading(device: PairedDevice(address: phone, name: "iPhone", connected: true), requestedAt: date))
        precondition(!state.devices[0].connected)
    }

    // Test that partial refreshes keep missing devices and use headphone order despite reply order
    static func testMissingDevicesAndOrder() {
        var state = DeviceState()
        state.devices = [PairedDevice(address: computer, name: "MacBook", connected: true)]
        state.reorder([phone, computer])
        state.merge(DeviceReading(device: PairedDevice(address: phone, name: "iPhone"), requestedAt: Date()))
        precondition(state.devices.map(\.address) == [phone, computer])
        precondition(state.devices[1].connected)
        precondition(state.devices.map(\.symbol) == ["iphone", "laptopcomputer"])
    }

    // Test that a damaged cache drops oversized and duplicate addresses
    static func testCacheValidation() throws {
        let devices = [PairedDevice(address: phone, name: "Phone"), PairedDevice(address: phone, name: "Copy"),
                       PairedDevice(address: Array(repeating: 1, count: 256), name: "Broken")]
        let cached = PairedDevice.cached(try JSONEncoder().encode(devices))
        precondition(cached.map(\.name) == ["Phone"])
        precondition(PairedDevice.cached(Data("garbage".utf8)).isEmpty)
    }

    // Test that a malformed Info reply cannot satisfy a request and retires the channel
    static func testMalformedInfo() {
        let channel = FakeChannel()
        let link = BmapLink(channel: channel)
        channel.onWrite = { bytes in
            if bytes[1] == deviceInfo { channel.reply(deviceInfo, status, Array(bytes[4...])) }
        }
        var readings = 0
        link.onDevice = { _ in readings += 1 }
        _ = link.refresh([phone], list: false, yielding: { false })
        precondition(readings == 0 && !link.isOpen)
    }

    // Test that common device names get a matching icon and unknown names fall back to a desktop
    static func testDeviceSymbols() {
        let names = ["Alice’s iPhone": "iphone", "Pixel 9": "iphone", "Galaxy Tab S9": "ipad", "iPad Air": "ipad",
                     "iMac": "pc", "Mac mini": "pc", "Bob's MacBook Air": "laptopcomputer", "Living Room TV": "appletv",
                     "Gaming Rig": "pc"]
        for (name, symbol) in names { precondition(PairedDevice(address: phone, name: name).symbol == symbol, name) }
    }

    // Test that a queued action interrupts a refresh wait without nesting any jobs
    static func testActionPriority() {
        let thread = BluetoothThread()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var events: [String] = []
        thread.start()
        thread.async {
            lock.withLock { events.append("refresh started") }
            started.signal()
            let deadline = Date(timeIntervalSinceNow: 2)
            while !thread.actionQueued && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            // Deliver queued drain selectors while this job is still busy
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            lock.withLock { events.append("refresh yielded") }
        }
        precondition(started.wait(timeout: .now() + 2) == .success)
        thread.async {
            lock.withLock { events.append("background") }
            finished.signal()
        }
        thread.async(action: true) { lock.withLock { events.append("action") } }
        precondition(finished.wait(timeout: .now() + 2) == .success)
        precondition(lock.withLock { events } == ["refresh started", "refresh yielded", "action", "background"])
        thread.cancel()
        thread.async {}
        let deadline = Date(timeIntervalSinceNow: 2)
        while !thread.isFinished && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(thread.isFinished)
    }

    // Test that a confirmed connection survives lag without refreshing cached peers
    static func testFirstConfirmationAndFreshness() {
        var state = DeviceState()
        state.devices = [PairedDevice(address: phone, name: "Phone", connected: true, active: true)]
        let date = Date()
        state.confirm(computer, connected: true, at: date)
        precondition(!state.isFresh(phone))
        state.merge(DeviceReading(device: PairedDevice(address: computer, name: "Computer"), requestedAt: date.addingTimeInterval(0.1)))
        precondition(state.devices.first { $0.address == computer }!.connected)
        state.invalidateReadings()
        precondition(!state.isFresh(computer))
    }

    // Test that a complete list removes forgotten devices and retains addresses with missing Info
    static func testAuthoritativeMembership() {
        var state = DeviceState()
        state.devices = [PairedDevice(address: phone, name: "Phone", connected: true)]
        state.reorder([computer])
        precondition(state.devices.isEmpty && state.knownAddresses == [computer])
        state.merge(DeviceReading(device: PairedDevice(address: phone, name: "Phone"), requestedAt: Date()))
        precondition(state.devices.isEmpty)
    }

    // Test that a lost Info reply retires its channel and cannot delay later successful refreshes
    static func testLostInfoRecovery() {
        let lost = FakeChannel()
        let old = BmapLink(channel: lost)
        _ = old.refresh([phone], list: false, yielding: { false })
        precondition(!old.isOpen && lost.writes.filter { $0[1] == deviceInfo && $0[0] == deviceManagement }.count == 1)
        for _ in 0..<3 {
            let channel = FakeChannel()
            let link = BmapLink(channel: channel)
            channel.onWrite = { bytes in
                if bytes[0] == deviceManagement && bytes[1] == deviceInfo {
                    channel.reply(deviceInfo, status, phone + [1, 0, 0] + Array("Phone".utf8))
                }
            }
            let began = Date()
            _ = link.refresh([phone], list: false, yielding: { false })
            let elapsed = Date().timeIntervalSince(began)
            precondition(link.isOpen && elapsed < 0.15)
            print("Recovered refresh seconds", elapsed)
        }
    }

    // Test that a timed-out action cannot deliver its error to a later channel generation
    static func testLateCommandReply() {
        let firstChannel = FakeChannel()
        let first = BmapLink(channel: firstChannel)
        firstChannel.onWrite = { _ in firstChannel.reply(connect, failed, [13] + phone, after: 0.08) }
        precondition(first.request(connect, start, [0] + phone, timeout: 0.03) == nil)
        precondition(!first.isOpen)
        let secondChannel = FakeChannel()
        let second = BmapLink(channel: secondChannel)
        secondChannel.onWrite = { _ in secondChannel.reply(connect, processing, phone, after: 0.10) }
        precondition(second.request(connect, start, [0] + phone, timeout: 0.2)?.operation == processing)
    }

    // Test that a connection reply completes without waiting for the next poll
    static func testConnectionPolling() {
        let channel = FakeChannel()
        let link = BmapLink(channel: channel)
        let began = Date()
        channel.onWrite = { bytes in
            if bytes[1] == deviceInfo {
                let connected: UInt8 = Date().timeIntervalSince(began) >= 0.05 ? 1 : 0
                channel.reply(deviceInfo, status, phone + [connected, 0, 0] + Array("Phone".utf8))
            }
        }
        precondition(link.waitUntilConnected(phone, since: began, timeout: 1) == .confirmed)
        let elapsed = Date().timeIntervalSince(began)
        precondition(elapsed < 0.3)
        print("Connection confirmation seconds", elapsed)
    }

    // Test that incomplete lists cannot prune devices and complete ordering arrives before Info
    static func testListValidationAndEarlyOrder() {
        precondition(Packet(function: listDevices, operation: status, payload: [1] + phone.dropLast()).pairedAddresses == nil)
        let channel = FakeChannel()
        let link = BmapLink(channel: channel)
        var events: [String] = []
        link.onList = { _ in events.append("list") }
        link.onDevice = { _ in events.append("device") }
        channel.onWrite = { bytes in
            if bytes[1] == listDevices { channel.reply(listDevices, status, [1] + phone) }
            if bytes[0] == deviceManagement && bytes[1] == deviceInfo {
                channel.reply(deviceInfo, status, phone + [0, 0, 0] + Array("Phone".utf8))
            }
        }
        precondition(link.refresh([], list: true, yielding: { false }) == [phone])
        precondition(events == ["list", "device"])
    }

    // Test that refusal and silence cannot report a still-connected Mac as disconnected
    static func testHostDisconnectFailure() {
        let channel = FakeChannel()
        let link = BmapLink(channel: channel)
        channel.onWrite = { _ in channel.reply(disconnect, failed, [13] + computer) }
        precondition(link.disconnectHost(computer, timeout: 0.05, isConnected: { true }) == .refused)
        channel.onWrite = nil
        precondition(link.disconnectHost(computer, timeout: 0.05, isConnected: { true }) == .timeout)
        let closedChannel = FakeChannel()
        let closed = BmapLink(channel: closedChannel)
        precondition(closed.disconnectHost(computer, timeout: 0.05, isConnected: { false }) == .confirmed)
    }
}
