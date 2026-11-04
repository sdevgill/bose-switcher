import AppKit
import IOBluetooth

final class BorrowedHeadphones: IOBluetoothDevice {
    var connected = false
    var closes = 0
    var onOpen: (() -> Void)?
    override var addressString: String! { "test-headphones" }
    override var name: String! { "Headphones" }
    override func isConnected() -> Bool { connected }
    override func openConnection() -> IOReturn {
        connected = true
        onOpen?()
        return kIOReturnSuccess
    }
    override func closeConnection() -> IOReturn {
        connected = false
        closes += 1
        return kIOReturnSuccess
    }
}

@main
struct CoordinatorTests {
    static func settle(_ seconds: TimeInterval = 0.05) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: deadline) }
    }

    static func main() {
        _ = NSApplication.shared
        let app = App(hostAddress: { [6, 5, 4, 3, 2, 1] },
                      discoverHeadphones: { preconditionFailure("Unexpected headphone discovery") },
                      makeStatusItem: { NSStatusItem() })
        app.bluetooth.start()
        app.session.begin(available: true)
        testCleanupOwnership(app)
        testCleanupReconciliation(app)
        testPowerCallbacks(app)
        testListCoalescing(app)
        testBatteryArtwork()
        testQuickReopen(app)
        testVisibleExpiry(app)
        testCancelledBorrow()
        app.bluetooth.cancel()
        app.bluetooth.async {}
        print("Passed 8 coordinator and artwork behavior checks")
    }

    // Test that cancellation during physical opening releases the borrowed Mac slot
    static func testCancelledBorrow() {
        let headphones = BorrowedHeadphones()
        let app = App(hostAddress: { [6, 5, 4, 3, 2, 1] },
                      discoverHeadphones: { headphones }, makeStatusItem: { NSStatusItem() })
        app.session.begin(available: true)
        headphones.onOpen = { app.session.begin(available: false) }
        app.send(PairedDevice(address: [1, 2, 3, 4, 5, 6], name: "Phone"),
                 disconnecting: false, needsReading: true, cleanupOwner: nil, generation: app.session.current)
        precondition(!headphones.connected && headphones.closes == 1 && app.temporaryMac == nil)
        settle()
    }

    // Test that a reading's expiry publishes once
    static func testVisibleExpiry(_ app: App) {
        let address: [UInt8] = [1, 2, 3, 4, 5, 6]
        app.updateState {
            $0.devices = [PairedDevice(address: address, name: "Phone")]
            $0.confirm(address, connected: true, at: Date(timeIntervalSinceNow: -4.9))
        }
        var notifications = 0
        let subscription = app.objectWillChange.sink { notifications += 1 }
        settle(0.15)
        app.updateState { _ in }
        precondition(!app.state.isFresh(address) && notifications == 1)
        app.updateState { _ in }
        precondition(notifications == 1)
        withExtendedLifetime(subscription) {}
    }

    // Test that closing the panel preserves a confirmation until it expires
    static func testQuickReopen(_ app: App) {
        let address: [UInt8] = [1, 2, 3, 4, 5, 6]
        let began = Date()
        app.updateState {
            $0.devices = [PairedDevice(address: address, name: "Phone")]
            $0.confirm(address, connected: true, at: began)
        }
        app.panelShown = true
        app.hidePanel()
        app.updateState { $0.merge(DeviceReading(device: PairedDevice(address: address, name: "Phone"), requestedAt: began.addingTimeInterval(1))) }
        precondition(app.state.devices[0].connected && app.state.isFresh(address))
        precondition(!app.state.isFresh(address, at: began.addingTimeInterval(7)))
    }

    // Test that the battery fill grows with its charge
    static func testBatteryArtwork() {
        func coverage(_ level: Int) -> Double {
            let image = referenceSymbol("battery", battery: level)
            precondition(image.isTemplate && image.size == NSSize(width: 26, height: 22))
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            return (0..<bitmap.pixelsHigh).reduce(0) { total, y in
                total + (0..<bitmap.pixelsWide).reduce(0) { $0 + Double(bitmap.colorAt(x: $1, y: y)!.alphaComponent) }
            }
        }
        let empty = coverage(0), partial = coverage(80), full = coverage(100)
        precondition(empty < partial && partial < full)
    }

    // Test that cleanup respects newer actions and clears its errors
    static func testCleanupOwnership(_ app: App) {
        let address: [UInt8] = [1, 2, 3, 4, 5, 6]
        let old = UUID()
        app.macConnected = true
        app.completedActions[address] = UUID()
        app.actions[address] = .working(disconnecting: true)
        app.actionPending = true
        app.publishCleanupFailure(address, owner: old, generation: app.session.current)
        precondition(app.actions[address] == .working(disconnecting: true) && app.actionPending)
        app.publishCleanupFailure(address, owner: app.completedActions[address], generation: app.session.current)
        precondition(app.actions[address] == .failed(reason: "Couldn't disconnect"))
        settle(3.1)
        precondition(app.actions[address] == .idle && app.actionPending)
    }

    // Test that a later physical disconnect clears cleanup failure immediately
    static func testCleanupReconciliation(_ app: App) {
        let address = app.hostAddress()
        app.macConnected = true
        app.actions[address] = .failed(reason: "Couldn't disconnect")
        app.publishConnection(nil, connected: false, generation: app.session.current)
        settle()
        precondition(!app.macConnected && app.actions[address] == .idle)
    }

    // Test that connection results queued before power-off cannot restore the old state
    static func testPowerCallbacks(_ app: App) {
        let old = app.session.current
        app.macConnected = true
        app.batteryPercent = 80
        app.publishConnection(nil, connected: true, generation: old)
        app.endSession(available: false)
        settle()
        precondition(!app.macConnected && app.batteryPercent == nil && !app.actionPending)
        app.session.begin(available: true)
        app.publishConnection(nil, connected: true, generation: old)
        settle()
        precondition(!app.macConnected)
    }

    // Test that opening and timer requests share the full list already in flight
    static func testListCoalescing(_ app: App) {
        app.bluetoothStatus = nil
        app.refreshPending = true
        app.refreshingList = true
        app.lastList = .distantPast
        app.requestRefresh(list: true)
        app.requestRefresh(list: true)
        precondition(!app.refreshAgain && !app.refreshListAgain)
        app.refreshingList = false
        app.requestRefresh(list: true)
        precondition(app.refreshAgain && app.refreshListAgain)
        app.bluetoothStatus = "Loading Bluetooth…"
    }
}
