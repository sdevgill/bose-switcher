import AppKit
import IOBluetooth

final class ExpandedInterfaceSession: NSStatusItemExpandedInterfaceSession {
    var onCancel: (() -> Void)?
    override func cancel() { onCancel?() }
}

final class SessionStatusButton: NSStatusBarButton {
    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

final class SessionStatusItem: NSStatusItem {
    let statusButton = SessionStatusButton(frame: .zero)
    var statusWindow: NSWindow?
    var activeSession: NSStatusItemExpandedInterfaceSession?
    override var button: NSStatusBarButton? { statusButton }
    override var expandedInterfaceSession: NSStatusItemExpandedInterfaceSession? { activeSession }

    func placeButton(at frame: NSRect) {
        if statusWindow == nil {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(statusButton)
            statusWindow = window
        }
        statusWindow?.setFrame(frame, display: false)
        statusButton.frame = NSRect(origin: .zero, size: frame.size)
    }
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

// A channel that hands writes to the test and can answer like the headphones
final class ScriptedChannel: IOBluetoothRFCOMMChannel {
    var opened = true
    weak var receiver: BmapLink?
    var onWrite: ((ScriptedChannel, [UInt8]) -> Void)?

    override func isOpen() -> Bool { opened }
    override func close() -> IOReturn { opened = false; return kIOReturnSuccess }
    override func setDelegate(_ delegate: Any!) -> IOReturn {
        receiver = delegate as? BmapLink
        return kIOReturnSuccess
    }
    override func writeSync(_ data: UnsafeMutableRawPointer!, length: UInt16) -> IOReturn {
        guard opened else { return kIOReturnError }
        onWrite?(self, Array(UnsafeRawBufferPointer(start: data, count: Int(length))))
        return kIOReturnSuccess
    }

    func reply(_ function: UInt8, _ payload: [UInt8]) {
        Timer.scheduledTimer(withTimeInterval: 0.005, repeats: false) { [self] _ in
            var bytes = [deviceManagement, function, status, UInt8(payload.count)] + payload
            bytes.withUnsafeMutableBytes { buffer in
                receiver?.rfcommChannelData(self, data: buffer.baseAddress!, length: buffer.count)
            }
        }
    }
}

// Connected headphones whose control channels the test scripts one by one
final class ScriptedHeadphones: IOBluetoothDevice {
    var opens = 0
    var makeChannel: (Int) -> ScriptedChannel = { _ in ScriptedChannel() }
    override var addressString: String! { "test-headphones" }
    override var name: String! { "Headphones" }
    override func isConnected() -> Bool { true }
    override func openRFCOMMChannelSync(_ rfcommChannel: AutoreleasingUnsafeMutablePointer<IOBluetoothRFCOMMChannel?>!,
                                        withChannelID channelID: BluetoothRFCOMMChannelID, delegate: Any!) -> IOReturn {
        let channel = makeChannel(opens)
        opens += 1
        channel.receiver = delegate as? BmapLink
        rfcommChannel.pointee = channel
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
        testLateActionConfirmation()
        testActionConfirmationBeforeCompletion()
        testRefusalStays()
        testUnansweredDisconnectSend()
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
        testPanelActionMask()
        testSecondaryItemClick()
        testMonitorEventLocation()
        testMovedItemFrame()
        testControlClick()
        testOutsideClickDismissal()
        testPrimaryItemClick()
        testAccessibilityAfterSessionDismissal()
        app.bluetooth.cancel()
        app.bluetooth.async {}
        print("Passed 29 coordinator and artwork behavior checks")
    }

    // Test that a second panel action closes the panel and a third opens it again
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

    // Test that launch setup sends only right mouse down through the button action
    static func testPanelActionMask() {
        let item = SessionStatusItem()
        let app = App(makeStatusItem: { item })
        app.configureStatusItem()
        let mask = item.statusButton.sendAction(on: [])
        precondition(mask == Int(NSEvent.EventTypeMask.rightMouseDown.rawValue))
        precondition(item.statusButton.target === app && item.statusButton.action == #selector(App.togglePanel))
        precondition(item.expandedInterfaceDelegate === app)
    }

    static func mouseEvent(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [],
                           location: NSPoint, timestamp: TimeInterval = uptime()) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: timestamp,
                          windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    // Test that right clicks on the item and within its slack leave dismissal to the button action
    static func testSecondaryItemClick() {
        let frame = NSRect(x: 100, y: 100, width: 24, height: 24)
        let locations = [NSPoint(x: frame.midX, y: frame.midY),
                         NSPoint(x: frame.minX - 1.5, y: frame.midY), NSPoint(x: frame.maxX + 1.5, y: frame.midY),
                         NSPoint(x: frame.midX, y: frame.minY - 1.5), NSPoint(x: frame.midX, y: frame.maxY + 1.5)]
        for location in locations {
            let item = SessionStatusItem()
            item.placeButton(at: frame)
            defer { item.statusWindow?.close() }
            let app = App(makeStatusItem: { item })
            app.togglePanel()
            app.showPanel()
            app.dismissPanelForOutsideClick(mouseEvent(.rightMouseDown, location: location))
            precondition(app.panelShown && app.placementTimer != nil && app.ignoreSessionUntil == .distantPast,
                         "item \(String(describing: app.itemFrame)), event \(location)")
            app.togglePanel()
            precondition(!app.panelShown && app.placementTimer == nil)
        }
    }

    // Test that the monitor uses the recorded screen location even when the cursor has moved elsewhere
    static func testMonitorEventLocation() {
        let cursor = NSEvent.mouseLocation
        let frame = NSRect(x: (cursor.x - 200).rounded(), y: (cursor.y - 200).rounded(), width: 24, height: 24)
        let item = SessionStatusItem()
        item.placeButton(at: frame)
        defer { item.statusWindow?.close() }
        let app = App(makeStatusItem: { item })
        app.togglePanel()
        app.showPanel()
        let event = mouseEvent(.rightMouseDown, location: NSPoint(x: frame.midX, y: frame.midY))
        precondition(event.window == nil && app.itemFrame == frame && !frame.contains(cursor),
                     "window \(String(describing: event.window)), item \(String(describing: app.itemFrame)), frame \(frame), event \(event.locationInWindow)")
        app.dismissPanelForOutsideClick(event)
        precondition(app.panelShown && app.placementTimer != nil)
        app.hidePanel()
    }

    // Test that hit testing follows a moved status item without moving the panel or accepting the old frame
    static func testMovedItemFrame() {
        for atNewFrame in [true, false] {
            let item = SessionStatusItem()
            let oldFrame = NSRect(x: 100, y: 100, width: 24, height: 24)
            let newFrame = NSRect(x: -240, y: 200, width: 24, height: 24)
            item.placeButton(at: oldFrame)
            defer { item.statusWindow?.close() }
            let app = App(makeStatusItem: { item })
            app.togglePanel()
            app.showPanel()
            let panelFrame = app.panel.frame
            precondition(app.itemFrame == oldFrame)
            item.placeButton(at: newFrame)
            let target = atNewFrame ? newFrame : oldFrame
            app.dismissPanelForOutsideClick(mouseEvent(.rightMouseDown, location: NSPoint(x: target.midX, y: target.midY)))
            precondition(app.panelShown == atNewFrame && app.panel.frame == panelFrame)
            app.hidePanel()
        }
    }

    // Test that a control-click on the item leaves the toggle to the button action, which macOS sends as a right click
    static func testControlClick() {
        for sessionOpen in [true, false] {
            let item = SessionStatusItem()
            item.placeButton(at: NSRect(x: 100, y: 100, width: 24, height: 24))
            defer { item.statusWindow?.close() }
            let app = App(makeStatusItem: { item })
            if sessionOpen {
                let session = ExpandedInterfaceSession()
                session.onCancel = {
                    item.activeSession = nil
                    app.statusItemDidEndExpandedInterfaceSession(item, animated: false)
                }
                item.activeSession = session
                app.statusItem(item, didBegin: session)
            } else {
                app.togglePanel()
            }
            app.showPanel()
            app.dismissPanelForOutsideClick(mouseEvent(.leftMouseDown, modifiers: .control, location: NSPoint(x: 112, y: 112)))
            precondition(app.panelShown && app.ignoreSessionUntil == .distantPast)
            app.togglePanel()
            precondition(!app.panelShown && app.placementTimer == nil && item.activeSession == nil)
            app.togglePanel()
            precondition(app.placementTimer != nil)
            app.hidePanel()
        }
    }

    // Test that secondary clicks beyond the item slack and other buttons still dismiss the panel
    static func testOutsideClickDismissal() {
        let clicks: [(NSEvent.EventType, NSEvent.ModifierFlags, NSPoint)] = [
            (.rightMouseDown, [], NSPoint(x: 97, y: 112)),
            (.leftMouseDown, .control, NSPoint(x: 127, y: 112)),
            (.otherMouseDown, [], NSPoint(x: 112, y: 112)),
            (.leftMouseDown, .shift, NSPoint(x: 112, y: 112))
        ]
        for (type, modifiers, location) in clicks {
            let item = SessionStatusItem()
            item.placeButton(at: NSRect(x: 100, y: 100, width: 24, height: 24))
            defer { item.statusWindow?.close() }
            let app = App(makeStatusItem: { item })
            app.togglePanel()
            app.showPanel()
            app.dismissPanelForOutsideClick(mouseEvent(type, modifiers: modifiers, location: location))
            precondition(!app.panelShown && app.placementTimer == nil && app.ignoreSessionUntil > monotonicNow())
        }
    }

    // Test that a primary item click closes an action-opened panel and suppresses its session without blocking AXPress
    static func testPrimaryItemClick() {
        let item = SessionStatusItem()
        item.placeButton(at: NSRect(x: 100, y: 100, width: 24, height: 24))
        defer { item.statusWindow?.close() }
        let app = App(makeStatusItem: { item })
        app.togglePanel()
        app.showPanel()
        app.dismissPanelForOutsideClick(mouseEvent(.leftMouseDown, location: NSPoint(x: 112, y: 112)))
        precondition(!app.panelShown && app.placementTimer == nil && app.ignoreSessionUntil > monotonicNow())
        let session = ExpandedInterfaceSession()
        var cancellations = 0
        session.onCancel = { cancellations += 1 }
        app.statusItem(item, didBegin: session)
        precondition(cancellations == 1 && !app.panelShown && app.placementTimer == nil)
        app.togglePanel()
        precondition(app.placementTimer != nil)
        app.hidePanel()
    }

    // Test that session-backed dismissal ends the session and allows AXPress to reopen at once
    static func testAccessibilityAfterSessionDismissal() {
        let item = SessionStatusItem()
        let app = App(makeStatusItem: { item })
        app.panel.delegate = app
        var cancellations = 0
        let session = ExpandedInterfaceSession()
        session.onCancel = {
            cancellations += 1
            item.activeSession = nil
            app.statusItemDidEndExpandedInterfaceSession(item, animated: false)
        }
        item.activeSession = session
        app.statusItem(item, didBegin: session)
        precondition(app.placementTimer != nil)
        app.showPanel()
        app.dismissPanelForOutsideClick(mouseEvent(.leftMouseDown, location: .zero))
        precondition(cancellations == 1 && !app.panelShown && item.activeSession == nil && app.placementTimer == nil)
        precondition(app.ignoreSessionUntil == .distantPast)
        app.togglePanel()
        precondition(app.placementTimer != nil)
        app.togglePanel()
        precondition(!app.panelShown && app.placementTimer == nil)
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

    // Test that only a fresh reading matching the failed command clears its error
    static func testLateActionConfirmation() {
        let address: [UInt8] = [1, 2, 3, 4, 5, 6]
        let other: [UInt8] = [6, 5, 4, 3, 2, 1]
        for disconnecting in [false, true] {
            let app = App(makeStatusItem: { NSStatusItem() })
            app.bluetooth.start()
            defer { app.bluetooth.cancel(); app.bluetooth.async {} }
            app.session.begin(available: true)
            let target = PairedDevice(address: address, name: "Phone", connected: disconnecting)
            app.updateState { $0.devices = [target] }
            app.actionPending = true
            let began = monotonicNow()
            let generation = app.session.current
            app.bluetooth.async {
                app.finish(target, disconnecting: disconnecting, result: .timeout, generation: generation, since: began)
            }
            let deadline = uptime() + 1
            while app.actionPending && uptime() < deadline { settle(0.01) }
            precondition(!app.actionPending && app.actions[address] == .failed(reason: "No answer"))
            app.receive(DeviceReading(device: PairedDevice(address: other, name: "Other", connected: !disconnecting), requestedAt: monotonicNow()))
            precondition(app.actions[address] == .failed(reason: "No answer"))
            let connected = PairedDevice(address: address, name: "Phone", connected: !disconnecting)
            app.receive(DeviceReading(device: connected, requestedAt: began.addingTimeInterval(-1)))
            precondition(app.actions[address] == .failed(reason: "No answer"))
            app.receive(DeviceReading(device: target, requestedAt: monotonicNow()))
            precondition(app.actions[address] == .failed(reason: "No answer"))
            app.receive(DeviceReading(device: connected, requestedAt: monotonicNow()))
            precondition(app.actions[address] == .idle && app.unconfirmedActions[address] == nil)
            precondition(app.state.devices.first { $0.address == address }?.connected == !disconnecting)
        }
    }

    // Test that a timeout cannot overwrite a reading that already confirmed the action
    static func testActionConfirmationBeforeCompletion() {
        let address: [UInt8] = [1, 2, 3, 4, 5, 6]
        for disconnecting in [false, true] {
            for fresh in [false, true] {
                let app = App(makeStatusItem: { NSStatusItem() })
                app.bluetooth.start()
                defer { app.bluetooth.cancel(); app.bluetooth.async {} }
                app.session.begin(available: true)
                let target = PairedDevice(address: address, name: "Phone", connected: disconnecting)
                app.updateState { $0.devices = [target] }
                app.actionPending = true
                let began = monotonicNow()
                app.receive(DeviceReading(device: PairedDevice(address: address, name: "Phone", connected: !disconnecting),
                                          requestedAt: fresh ? monotonicNow() : began.addingTimeInterval(-1)))
                let generation = app.session.current
                app.bluetooth.async {
                    app.finish(target, disconnecting: disconnecting, result: .timeout, generation: generation, since: began)
                }
                let deadline = uptime() + 1
                while app.actionPending && uptime() < deadline { settle(0.01) }
                precondition(!app.actionPending)
                precondition(app.actions[address] == (fresh ? .idle : .failed(reason: "No answer")))
                precondition((app.unconfirmedActions[address] == nil) == fresh)
            }
        }
    }

    // Test that a disconnect whose reply never comes is confirmed by the next reading instead of failing
    static func testUnansweredDisconnectSend() {
        let address: [UInt8] = [1, 2, 3, 4, 5, 6]
        let headphones = ScriptedHeadphones()
        headphones.makeChannel = { index in
            let channel = ScriptedChannel()
            channel.onWrite = { channel, bytes in
                // The first channel drops while the headphones switch, the next one reports the device gone
                if index == 0 && bytes[1] == disconnect { channel.opened = false; channel.receiver?.rfcommChannelClosed(channel) }
                if index > 0 && bytes[1] == deviceInfo { channel.reply(deviceInfo, address + [0, 0, 0] + Array("Phone".utf8)) }
            }
            return channel
        }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "deviceCacheHeadphones")
        defer { defaults.set(previous, forKey: "deviceCacheHeadphones") }
        defaults.set("test-headphones", forKey: "deviceCacheHeadphones")
        let app = App(hostAddress: { [6, 5, 4, 3, 2, 1] }, discoverHeadphones: { _ in headphones }, makeStatusItem: { NSStatusItem() })
        app.bluetooth.start()
        defer { app.bluetooth.cancel(); app.bluetooth.async {} }
        app.session.begin(available: true)
        let target = PairedDevice(address: address, name: "Phone", connected: true)
        // Already connected, so the fresh reading below is not invalidated by a new Mac connection
        app.macConnected = true
        app.updateState {
            $0.devices = [target]
            $0.confirm(address, connected: true)
        }
        app.actionPending = true
        let generation = app.session.current
        app.bluetooth.async(action: true) {
            app.send(target, disconnecting: true, needsReading: false, cleanupOwner: nil, generation: generation)
        }
        let deadline = uptime() + 5
        while app.actionPending && uptime() < deadline { settle(0.01) }
        precondition(!app.actionPending && headphones.opens >= 2)
        precondition(app.actions[address] != .failed(reason: "No answer"))
        precondition(app.state.devices.first { $0.address == address }?.connected == false)
    }

    // Test that an explicit refusal stays even when a reading before or after it shows the wanted state
    static func testRefusalStays() {
        let address: [UInt8] = [1, 2, 3, 4, 5, 6]
        for readingFirst in [false, true] {
            let app = App(makeStatusItem: { NSStatusItem() })
            app.bluetooth.start()
            defer { app.bluetooth.cancel(); app.bluetooth.async {} }
            app.session.begin(available: true)
            let target = PairedDevice(address: address, name: "Phone")
            app.updateState { $0.devices = [target] }
            app.actionPending = true
            let began = monotonicNow()
            let connected = PairedDevice(address: address, name: "Phone", connected: true)
            if readingFirst { app.receive(DeviceReading(device: connected, requestedAt: monotonicNow())) }
            let generation = app.session.current
            app.bluetooth.async {
                app.finish(target, disconnecting: false, result: .refused, generation: generation, since: began)
            }
            let deadline = uptime() + 1
            while app.actionPending && uptime() < deadline { settle(0.01) }
            if !readingFirst { app.receive(DeviceReading(device: connected, requestedAt: monotonicNow())) }
            precondition(app.actions[address] == .failed(reason: "Couldn't connect") && app.unconfirmedActions[address] == nil)
        }
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
