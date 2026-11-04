import AppKit
import SwiftUI
import IOBluetooth

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate, ObservableObject {
    @Published var state = DeviceState()
    @Published var actions: [[UInt8]: RowAction] = [:]
    @Published var macConnected = false
    @Published var headphonesName = UserDefaults.standard.string(forKey: "headphonesName") ?? "Headphones"
    @Published var actionPending = false
    @Published var panelShown = false
    @Published var batteryPercent: Int?

    private let statusItem = NSStatusBar.system.statusItem(withLength: 29)
    private let popover = NSPopover()
    private let bluetooth = BluetoothThread()
    private var refreshPending = false
    private var listNeeded = true
    private var completedActions: [[UInt8]: UUID] = [:]
    // Only the Bluetooth thread touches the link
    private var link: BmapLink?
    private var temporaryMac = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = switcherIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        updateTooltip()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: SwitcherPanel(app: self))
        if let data = UserDefaults.standard.data(forKey: "devices") {
            state.devices = (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
        }
        bluetooth.start()
        requestRefresh(list: state.devices.isEmpty)
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApplication.shared.activate()
            panelShown = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            requestRefresh(list: state.devices.isEmpty)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        panelShown = false
    }

    private func updateTooltip() {
        statusItem.button?.toolTip = "Bose Switcher · \(headphonesName)"
    }

    // A cached launch starts with Info, then discovers new pairings at idle priority
    private func requestRefresh(list: Bool = false) {
        guard !refreshPending else { return }
        refreshPending = true
        let known = state.devices.map(\.address)
        bluetooth.async {
            let headphones = findHeadphones()
            let connected = headphones?.isConnected() ?? false
            self.publishConnection(headphones, connected: connected)
            var order: [[UInt8]]?
            if connected, !self.bluetooth.actionQueued, let headphones, let link = self.openLink(headphones) {
                order = link.refresh(known, list: list, yielding: { self.bluetooth.actionQueued })
            }
            let discovered = order
            DispatchQueue.main.async {
                if let discovered {
                    self.state.reorder(discovered)
                    self.listNeeded = false
                    self.saveDevices()
                }
                self.refreshPending = false
                if connected && self.listNeeded && !list && !self.actionPending {
                    self.requestRefresh(list: true)
                }
            }
        }
    }

    private func openLink(_ headphones: IOBluetoothDevice) -> BmapLink? {
        if let link, link.isOpen { return link }
        link = BmapLink(device: headphones)
        link?.onDevice = { reading in
            DispatchQueue.main.async {
                self.state.merge(reading)
                self.saveDevices()
            }
        }
        link?.onBattery = { level in
            DispatchQueue.main.async { self.batteryPercent = level }
        }
        link?.onClose = {
            let headphones = findHeadphones()
            self.publishConnection(headphones, connected: headphones?.isConnected() ?? false)
        }
        return link
    }

    // Mac connectivity does not depend on whether any Info requests answered
    private func publishConnection(_ headphones: IOBluetoothDevice?, connected: Bool) {
        let name = headphones?.name
        let address = macAddress()
        DispatchQueue.main.async {
            if let name, !name.isEmpty {
                self.headphonesName = name
                UserDefaults.standard.set(name, forKey: "headphonesName")
                self.updateTooltip()
            }
            if self.macConnected != connected {
                self.macConnected = connected
                if !connected { self.batteryPercent = nil }
                self.state.confirm(address, connected: connected)
                self.saveDevices()
            }
        }
    }

    func toggle(_ target: PairedDevice) {
        guard !actionPending else { return }
        let disconnecting = macConnected && target.connected
        actionPending = true
        completedActions[target.address] = nil
        actions[target.address] = .working(disconnecting: disconnecting)
        statusItem.button?.appearsDisabled = true
        bluetooth.async(action: true) { self.send(target, disconnecting: disconnecting) }
    }

    private func send(_ target: PairedDevice, disconnecting: Bool) {
        guard let headphones = findHeadphones() else {
            finish(target, disconnecting: disconnecting, result: .timeout)
            return
        }
        let address = macAddress()
        let isMac = target.address == address
        let macWasConnected = headphones.isConnected()
        if !macWasConnected && headphones.openConnection() != kIOReturnSuccess {
            finish(target, disconnecting: disconnecting, result: .timeout)
            return
        }
        if !macWasConnected { temporaryMac = true }
        publishConnection(headphones, connected: true)
        if isMac && !disconnecting {
            temporaryMac = false
            finish(target, disconnecting: false, result: .confirmed)
            return
        }
        guard let link = openLink(headphones) else {
            if temporaryMac { _ = headphones.closeConnection() }
            temporaryMac = false
            publishConnection(headphones, connected: findHeadphones()?.isConnected() ?? false)
            finish(target, disconnecting: disconnecting, result: .timeout)
            return
        }
        if isMac {
            // The Mac gets no reply to its own disconnect
            link.request(disconnect, start, target.address, timeout: 1)
            temporaryMac = false
            publishConnection(headphones, connected: false)
            finish(target, disconnecting: true, result: .confirmed)
            return
        }
        let began = Date()
        let reply = disconnecting
            ? link.request(disconnect, start, target.address)
            : link.request(connect, start, [0] + target.address)
        let result: ActionResult
        if reply?.operation == failed {
            result = .refused
        } else if reply == nil {
            result = .timeout
        } else {
            result = disconnecting ? .confirmed : link.waitUntilConnected(target.address, since: began)
        }
        // Publish and unlock before giving the Mac's temporary slot back
        finish(target, disconnecting: disconnecting, result: result)
        if temporaryMac && !bluetooth.actionQueued {
            // Once sent, the disconnect must settle before another action can use the link
            link.request(disconnect, start, address, timeout: 1)
            temporaryMac = false
            publishConnection(headphones, connected: findHeadphones()?.isConnected() ?? false)
        }
    }

    private func finish(_ target: PairedDevice, disconnecting: Bool, result: ActionResult) {
        DispatchQueue.main.sync {
            switch result {
            case .confirmed:
                self.state.confirm(target.address, connected: !disconnecting)
                self.actions[target.address] = .confirmed
                self.saveDevices()
            case .refused:
                self.actions[target.address] = .failed(reason: disconnecting ? "Couldn't disconnect" : "Couldn't connect")
                NSSound.beep()
            case .timeout:
                self.actions[target.address] = .failed(reason: "No answer")
            }
            self.actionPending = false
            self.statusItem.button?.appearsDisabled = false
            let completion = UUID()
            self.completedActions[target.address] = completion
            self.requestRefresh(list: self.state.devices.isEmpty)
            // Wait out the measured Info lag without occupying the Bluetooth thread
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.completedActions[target.address] == completion { self.actions[target.address] = .idle }
                self.requestRefresh(list: self.state.devices.isEmpty)
            }
        }
    }

    private func saveDevices() {
        UserDefaults.standard.set(try? JSONEncoder().encode(state.devices), forKey: "devices")
    }
}

@main
struct BoseSwitcher {
    static func main() {
        if CommandLine.arguments.contains("--scan") {
            let serviceUUID: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0xde, 0xca, 0xfa, 0xde, 0xde, 0xca, 0xde, 0xaf, 0xde, 0xca, 0xca, 0xff]
            let uuid = IOBluetoothSDPUUID(bytes: serviceUUID, length: serviceUUID.count)
            let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            print(paired.first { $0.getServiceRecord(for: uuid) != nil }?.addressString ?? "")
            return
        }
        let application = NSApplication.shared
        let delegate = App()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
