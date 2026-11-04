import Foundation

@main
struct BehaviorTests {
    static let phone: [UInt8] = [1, 2, 3, 4, 5, 6]
    static let computer: [UInt8] = [6, 5, 4, 3, 2, 1]

    static func main() {
        testReplyAddresses()
        testBatteryReply()
        testConfirmedState()
        testMissingDevicesAndOrder()
        testActionPriority()
        print("Passed 5 hardware-free behavior checks")
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
}
