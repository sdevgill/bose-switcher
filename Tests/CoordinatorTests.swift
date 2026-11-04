import AppKit
import IOBluetooth

final class ExpandedInterfaceSession: NSStatusItemExpandedInterfaceSession {
    var onCancel: (() -> Void)?
    override func cancel() { onCancel?() }
}

final class SessionStatusItem: NSStatusItem {
    var activeSession: NSStatusItemExpandedInterfaceSession?
    override var expandedInterfaceSession: NSStatusItemExpandedInterfaceSession? { activeSession }
}

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
                      discoverHeadphones: { _ in preconditionFailure("Unexpected headphone discovery") },
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
        testDiscoveryRetry()
        testDroppedBorrow()
        testStaleBattery()
        testReplacementBattery(app)
        testRowHover()
        testTerminationCleanup()
        testTerminationDeadline()
        testPanelToggle()
        testPanelDismissal()
        testSessionDismissal()
        app.bluetooth.cancel()
        app.bluetooth.async {}
        print("Passed 18 coordinator and artwork behavior checks")
    }

    // Test that a second status item click closes the panel and a third opens it again
    static func testPanelToggle() {
        let app = App(makeStatusItem: { NSStatusItem() })
        app.panel.delegate = app
        app.togglePanel()
        precondition(app.placementTimer != nil)
        app.showPanel()
        app.togglePanel()
        precondition(!app.panelShown && app.placementTimer == nil && app.panelTimer == nil)
        app.togglePanel()
        precondition(app.placementTimer != nil)
        app.togglePanel()
        precondition(!app.panelShown && app.placementTimer == nil)
    }

    // Test that cancelling the panel and another app activating both close it, but the front app reactivating does not
    static func testPanelDismissal() {
        let app = App(makeStatusItem: { NSStatusItem() })
        app.panel.delegate = app
        app.showPanel()
        app.panel.cancelOperation(nil)
        precondition(!app.panelShown && app.panelTimer == nil)
        app.showPanel()
        app.frontApp = NSRunningApplication.current
        let activation = { (running: NSRunningApplication?) in
            Notification(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                         userInfo: running.map { [NSWorkspace.applicationUserInfoKey: $0] })
        }
        app.otherAppActivated(activation(NSRunningApplication.current))
        precondition(app.panelShown)
        app.otherAppActivated(activation(nil))
        precondition(!app.panelShown && app.panelTimer == nil)
    }

    // Test that closing the panel ends the menu bar session and a click that just closed it cannot reopen it
    static func testSessionDismissal() {
        let item = SessionStatusItem()
        let app = App(makeStatusItem: { item })
        app.panel.delegate = app
        var cancellations = 0
        func begin() -> ExpandedInterfaceSession {
            let session = ExpandedInterfaceSession()
            session.onCancel = {
                cancellations += 1
                item.activeSession = nil
                app.statusItemDidEndExpandedInterfaceSession(item, animated: false)
            }
            item.activeSession = session
            app.statusItem(item, didBegin: session)
            return session
        }
        _ = begin()
        precondition(app.placementTimer != nil)
        app.showPanel()
        app.hidePanel()
        precondition(cancellations == 1 && !app.panelShown && item.activeSession == nil && app.placementTimer == nil)
        app.ignoreSessionUntil = monotonicNow().addingTimeInterval(0.5)
        _ = begin()
        precondition(cancellations == 2 && app.placementTimer == nil && !app.panelShown)
    }

    // Test that hover draws rounded light and dark fills without changing layout or intercepting clicks
    static func testRowHover() {
        let row = RowHighlightView()
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 38)
        let frame = row.frame
        func pixel(_ x: Int, _ y: Int) -> NSColor {
            let image = NSImage(size: frame.size, flipped: false) { _ in
                row.effectiveAppearance.performAsCurrentDrawingAppearance { row.draw(row.bounds) }
                return true
            }
            return NSBitmapImageRep(data: image.tiffRepresentation!)!.colorAt(x: x, y: y)!
        }
        var fills: [NSColor] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            row.appearance = NSAppearance(named: appearance)
            precondition(pixel(120, 19).alphaComponent == 0)
            row.mouseEntered(with: NSEvent())
            let fill = pixel(120, 19)
            precondition(fill.alphaComponent > 0 && fill.alphaComponent < 0.3)
            precondition(pixel(0, 0).alphaComponent == 0)
            fills.append(fill)
            row.enabled = false
            precondition(pixel(120, 19).alphaComponent == 0)
            row.enabled = true
            row.mouseExited(with: NSEvent())
            precondition(pixel(120, 19).alphaComponent == 0)
        }
        precondition(fills[0] != fills[1] && row.frame == frame && row.hitTest(.zero) == nil)
    }

    // Test that quitting during a borrowed connection releases it before replying once
    static func testTerminationCleanup() {
        let headphones = BorrowedHeadphones()
        let opened = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let app = App(hostAddress: { [6, 5, 4, 3, 2, 1] },
                      discoverHeadphones: { _ in headphones }, makeStatusItem: { NSStatusItem() })
        app.bluetooth.start()
        defer { app.bluetooth.cancel(); app.bluetooth.async {} }
        app.session.begin(available: true)
        let generation = app.session.current
        headphones.onOpen = { opened.signal(); resume.wait() }
        app.bluetooth.async(action: true) {
            app.send(PairedDevice(address: [1, 2, 3, 4, 5, 6], name: "Phone"),
                     disconnecting: false, needsReading: true, cleanupOwner: nil, generation: generation)
        }
        precondition(opened.wait(timeout: .now() + 1) == .success)
        var replies = 0
        app.beginTermination {
            precondition(!headphones.connected && headphones.closes == 1 && app.temporaryMac == nil)
            replies += 1
        }
        resume.signal()
        settle(0.2)
        precondition(replies == 1 && !app.session.accepts(generation))
        settle(1.4)
        precondition(replies == 1)
    }

    // Test that a blocked system call cannot delay the quit reply past the cleanup deadline
    static func testTerminationDeadline() {
        let app = App(makeStatusItem: { NSStatusItem() })
        app.bluetooth.start()
        defer { app.bluetooth.cancel(); app.bluetooth.async {} }
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        app.bluetooth.async { started.signal(); resume.wait() }
        precondition(started.wait(timeout: .now() + 1) == .success)
        var replies = 0
        let began = monotonicNow()
        app.beginTermination { replies += 1 }
        while replies == 0 && monotonicNow().timeIntervalSince(began) < 1.8 { settle(0.01) }
        precondition(replies == 1 && monotonicNow().timeIntervalSince(began) < 1.7)
        resume.signal()
        settle()
        precondition(replies == 1)
    }

    // Test that unsuccessful initial discovery retries without the successful-list throttle
    static func testDiscoveryRetry() {
        let app = App(hostAddress: { [6, 5, 4, 3, 2, 1] },
                      discoverHeadphones: { _ in nil }, makeStatusItem: { NSStatusItem() })
        app.bluetooth.start()
        defer { app.bluetooth.cancel(); app.bluetooth.async {} }
        app.session.begin(available: true)
        app.bluetoothStatus = nil
        app.requestRefresh(list: true)
        settle()
        precondition(!app.refreshPending && app.lastList == .distantPast)
        precondition(!app.shouldRefreshList && app.nextListAttempt > monotonicNow())
        app.nextListAttempt = .distantPast
        precondition(app.shouldRefreshList)
        app.listNeeded = false
        app.lastList = monotonicNow()
        precondition(!app.shouldRefreshList)
    }

    // Test that a borrowed connection that already dropped is forgotten so a later user connection is kept
    static func testDroppedBorrow() {
        let headphones = BorrowedHeadphones()
        let app = App(hostAddress: { [6, 5, 4, 3, 2, 1] },
                      discoverHeadphones: { _ in headphones }, makeStatusItem: { NSStatusItem() })
        app.bluetooth.start()
        defer { app.bluetooth.cancel(); app.bluetooth.async {} }
        app.session.begin(available: true)
        app.bluetoothStatus = nil
        app.temporaryMac = headphones
        app.requestRefresh()
        settle(0.2)
        precondition(app.temporaryMac == nil && headphones.closes == 0)
    }

    // Test that a battery level the headphones stopped reporting disappears
    static func testStaleBattery() {
        let app = App(hostAddress: { [6, 5, 4, 3, 2, 1] }, discoverHeadphones: { _ in nil }, makeStatusItem: { NSStatusItem() })
        app.macConnected = true
        app.batteryPercent = 80
        app.batteryAt = monotonicNow().addingTimeInterval(-31)
        app.showPanel()
        settle(2.1)
        precondition(app.batteryPercent == nil)
        app.hidePanel()
    }

    // Test that replacing connected headphones clears the previous battery reading
    static func testReplacementBattery(_ app: App) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "deviceCacheHeadphones")
        defer { defaults.set(previous, forKey: "deviceCacheHeadphones") }
        defaults.set("previous-headphones", forKey: "deviceCacheHeadphones")
        app.macConnected = true
        app.batteryPercent = 80
        app.publishConnection(BorrowedHeadphones(), connected: true, generation: app.session.current)
        settle()
        precondition(app.macConnected && app.batteryPercent == nil)
    }

    // Test that cancellation during physical opening releases the borrowed Mac slot
    static func testCancelledBorrow() {
        let headphones = BorrowedHeadphones()
        let app = App(hostAddress: { [6, 5, 4, 3, 2, 1] },
                      discoverHeadphones: { _ in headphones }, makeStatusItem: { NSStatusItem() })
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
            $0.confirm(address, connected: true, at: monotonicNow().addingTimeInterval(-4.9))
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
        let began = monotonicNow()
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
