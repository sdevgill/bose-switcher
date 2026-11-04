import AppKit
import IOBluetooth

// UUID of the BMAP control service that Bose headphones advertise
let bmapServiceUUID: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0xde, 0xca, 0xfa, 0xde, 0xde, 0xca, 0xde, 0xaf, 0xde, 0xca, 0xca, 0xff]
let bmapChannel: BluetoothRFCOMMChannelID = 2

// BMAP operators and the DeviceManagement [4.x] functions this app uses
let get: UInt8 = 1, start: UInt8 = 5, status: UInt8 = 3, failed: UInt8 = 4
let deviceManagement: UInt8 = 4, connect: UInt8 = 1, disconnect: UInt8 = 2, listDevices: UInt8 = 4, deviceInfo: UInt8 = 5

struct Packet {
    let function: UInt8
    let op: UInt8
    let payload: [UInt8]

    // The device a reply is about, since error replies put a one-byte code in front of the address
    var address: [UInt8] { Array((op == failed ? payload.dropFirst() : payload[...]).prefix(6)) }
}

struct PairedDevice: Codable {
    let address: [UInt8]
    let name: String
    var connected = false
    var active = false
}

// One RFCOMM session with the headphones, speaking Bose's BMAP protocol
final class BmapLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var channel: IOBluetoothRFCOMMChannel?
    private var unread: [UInt8] = []
    private var replies: [Packet] = []

    init?(device: IOBluetoothDevice) {
        super.init()
        var opened: IOBluetoothRFCOMMChannel?
        guard device.openRFCOMMChannelSync(&opened, withChannelID: bmapChannel, delegate: self) == kIOReturnSuccess,
              let opened else { return nil }
        channel = opened
        pump(0.5)
        replies.removeAll()
    }

    var isOpen: Bool { channel?.isOpen() ?? false }

    // Sends a packet and waits for its reply, skipping stray packets the headphones push on their own
    @discardableResult
    func request(_ function: UInt8, _ op: UInt8, _ payload: [UInt8] = [], timeout: TimeInterval = 5) -> Packet? {
        replies.removeAll()
        guard write(function, op, payload) else { return nil }
        // Replies that concern a device start with its address, which is the end of the request payload
        let address = Array(payload.suffix(6))
        return wait(timeout) { reply(function, address) }
    }

    // Listing devices takes the headphones seconds while info replies are instant, so known devices skip the list
    func devices(_ cached: [PairedDevice], list: Bool) -> [PairedDevice] {
        var addresses = cached.map(\.address)
        if list || addresses.isEmpty {
            guard let reply = request(listDevices, get), reply.op == status else { return [] }
            addresses = stride(from: 1, to: reply.payload.count - 5, by: 6).map { Array(reply.payload[$0 ..< $0 + 6]) }
        }
        replies.removeAll()
        guard addresses.allSatisfy({ write(deviceInfo, get, $0) }) else { return [] }
        _ = wait(3) { addresses.allSatisfy { reply(deviceInfo, $0) != nil } ? true : nil }
        let answered = addresses.compactMap { reply(deviceInfo, $0).flatMap(device) }
        guard !answered.isEmpty else { return [] }
        // A device that missed this round keeps its last known state instead of vanishing from the menu
        return addresses.compactMap { address in
            answered.first { $0.address == address } ?? cached.first { $0.address == address }
        }
    }

    // Phones take up to about 17 seconds to join
    func waitUntilConnected(_ address: [UInt8], timeout: TimeInterval = 20) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while isOpen && Date() < deadline {
            if request(deviceInfo, get, address, timeout: 1).flatMap(device)?.connected == true { return true }
            pump(0.5)
        }
        return false
    }

    func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // Info reply: address (6 bytes), state (bit 0 connected, bit 1 active), 2 unknown bytes, then the name
    private func device(_ reply: Packet) -> PairedDevice? {
        guard reply.op == status, reply.payload.count >= 9 else { return nil }
        let state = reply.payload[6]
        let name = String(decoding: reply.payload[9...], as: UTF8.self)
        return PairedDevice(address: Array(reply.payload[0 ..< 6]), name: name, connected: state & 1 != 0, active: state & 2 != 0)
    }

    private func reply(_ function: UInt8, _ address: [UInt8]) -> Packet? {
        replies.first { $0.function == function && $0.address.starts(with: address) }
    }

    private func write(_ function: UInt8, _ op: UInt8, _ payload: [UInt8]) -> Bool {
        var bytes = [deviceManagement, function, op, UInt8(payload.count)] + payload
        return channel?.writeSync(&bytes, length: UInt16(bytes.count)) == kIOReturnSuccess
    }

    // Stops early when the link closes, because no reply can arrive after that
    private func wait<Result>(_ timeout: TimeInterval, until result: () -> Result?) -> Result? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while isOpen && Date() < deadline {
            if let found = result() { return found }
            pump(0.02)
        }
        return result()
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channel = nil
    }

    // Cuts the byte stream into packets and keeps the DeviceManagement ones
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        unread += UnsafeRawBufferPointer(start: dataPointer, count: dataLength)
        while unread.count >= 4 && unread.count >= 4 + Int(unread[3]) {
            let end = 4 + Int(unread[3])
            if unread[0] == deviceManagement {
                replies.append(Packet(function: unread[1], op: unread[2] & 0x0F, payload: Array(unread[4 ..< end])))
            }
            unread.removeFirst(end)
        }
    }
}

// Listing paired devices breaks isConnected() for the rest of the process, so the scan runs in a child process once
func findHeadphones() -> IOBluetoothDevice? {
    if let saved = UserDefaults.standard.string(forKey: "headphones") { return IOBluetoothDevice(addressString: saved) }
    let scan = Process()
    let output = Pipe()
    scan.executableURL = Bundle.main.executableURL
    scan.arguments = ["--scan"]
    scan.standardOutput = output
    guard (try? scan.run()) != nil else { return nil }
    scan.waitUntilExit()
    let address = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !address.isEmpty else { return nil }
    UserDefaults.standard.set(address, forKey: "headphones")
    return IOBluetoothDevice(addressString: address)
}

// Prints the address of the first paired device that offers the BMAP service
func scan() {
    let uuid = IOBluetoothSDPUUID(bytes: bmapServiceUUID, length: bmapServiceUUID.count)
    let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    print(paired.first { $0.getServiceRecord(for: uuid) != nil }?.addressString ?? "")
}

// This Mac's Bluetooth address as bytes, from a string like "00:11:22:33:44:55"
func macAddress() -> [UInt8] {
    let text = IOBluetoothHostController.default()?.addressAsString() ?? ""
    return text.split(separator: ":").compactMap { UInt8($0, radix: 16) }
}

// Runs Bluetooth work one job at a time on its own run loop, so the menu never waits on the headphones
final class BluetoothThread: Thread {
    private var jobs: [() -> Void] = []
    private var busy = false

    override func main() {
        RunLoop.current.add(NSMachPort(), forMode: .default)
        while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    func async(_ job: @escaping () -> Void) {
        perform(#selector(enqueue), on: self, with: Job(job), waitUntilDone: false)
    }

    // A job pumps the run loop while it waits for replies, so later jobs wait in line instead of running inside it
    @objc private func enqueue(_ job: Job) {
        jobs.append(job.run)
        guard !busy else { return }
        busy = true
        while !jobs.isEmpty { jobs.removeFirst()() }
        busy = false
    }
}

final class Job: NSObject {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let bluetooth = BluetoothThread()
    // Everything but link belongs to the main thread, link belongs to the Bluetooth thread
    var devices: [PairedDevice] = []
    var live = false
    var refreshPending = false
    var actionPending = false
    var link: BmapLink?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Bose Switcher")
        menu.delegate = self
        statusItem.menu = menu
        if let data = UserDefaults.standard.data(forKey: "devices") {
            devices = (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
        }
        bluetooth.start()
        // Lists devices once per launch to pick up new pairings
        requestRefresh(list: true)
    }

    // Shows the last known state at once and fills in fresh state when the headphones answer
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
        requestRefresh()
    }

    // macOS asks for menu updates often, so a refresh that is already waiting covers the new request too
    func requestRefresh(list: Bool = false) {
        guard !refreshPending else { return }
        refreshPending = true
        let cached = devices
        bluetooth.async {
            self.refresh(cached, list: list)
            DispatchQueue.main.async { self.refreshPending = false }
        }
    }

    // Reads live states only when the headphones already talk to this Mac, so a refresh never bumps a device
    func refresh(_ cached: [PairedDevice], list: Bool) {
        let connected = findHeadphones()?.isConnected() ?? false
        var fresh: [PairedDevice] = []
        if connected, let headphones = findHeadphones(), let link = openLink(headphones) {
            fresh = link.devices(cached, list: list)
        }
        DispatchQueue.main.async {
            // A missed reply keeps the last known devices instead of claiming the Mac is not connected
            if !fresh.isEmpty {
                self.devices = fresh
                UserDefaults.standard.set(try? JSONEncoder().encode(fresh), forKey: "devices")
            }
            self.live = connected && !self.devices.isEmpty
            self.rebuild()
        }
    }

    // Keeps one link open while the headphones talk to this Mac, because the first reply on a new link takes seconds
    func openLink(_ headphones: IOBluetoothDevice) -> BmapLink? {
        if let link, link.isOpen { return link }
        link = BmapLink(device: headphones)
        return link
    }

    // Updates rows in place when the layout is unchanged, so a refresh never swallows a click
    func rebuild() {
        let offset = live ? 0 : 2
        let layoutMatches = menu.items.count == offset + devices.count + 2 && (menu.items.first?.action != nil) == live
        if !layoutMatches {
            menu.removeAllItems()
            if !live {
                menu.addItem(withTitle: devices.isEmpty ? "Connect the headphones to this Mac once" : "Not connected to this Mac", action: nil, keyEquivalent: "")
                menu.addItem(.separator())
            }
            for index in devices.indices {
                let item = menu.addItem(withTitle: "", action: #selector(toggle), keyEquivalent: "")
                item.target = self
                item.tag = index
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        }
        for (index, device) in devices.enumerated() {
            let item = menu.items[offset + index]
            item.title = device.name + (device.active ? " — playing" : "")
            item.state = live && device.connected ? .on : .off
        }
    }

    // Clicking a connected device disconnects it, clicking any other device connects it
    @objc func toggle(_ item: NSMenuItem) {
        // One action at a time, because a second click would act on the state from before the first one
        guard !actionPending else { return }
        actionPending = true
        let target = devices[item.tag]
        let disconnecting = live && target.connected
        let cached = devices
        statusItem.button?.appearsDisabled = true
        bluetooth.async {
            if self.send(target, disconnecting: disconnecting) {
                DispatchQueue.main.async { self.mark(target, connected: !disconnecting) }
            }
            self.refresh(cached, list: false)
            DispatchQueue.main.async {
                self.actionPending = false
                self.statusItem.button?.appearsDisabled = false
            }
        }
    }

    // Shows a confirmed change at once, because the headphones answer the next refresh slowly
    func mark(_ target: PairedDevice, connected: Bool) {
        guard let index = devices.firstIndex(where: { $0.address == target.address }) else { return }
        devices[index].connected = connected
        rebuild()
    }

    // Returns whether the headphones confirmed the change
    func send(_ target: PairedDevice, disconnecting: Bool) -> Bool {
        guard let headphones = findHeadphones() else { return false }
        let isMac = target.address == macAddress()
        let macWasConnected = headphones.isConnected()
        if !macWasConnected && headphones.openConnection() != kIOReturnSuccess { return false }
        // Joining is the whole job when the target is this Mac
        if isMac && !disconnecting { return true }
        guard let link = openLink(headphones) else {
            if !macWasConnected { _ = headphones.closeConnection() }
            return false
        }
        if isMac {
            // The link drops as the Mac leaves, so no reply comes back
            link.request(disconnect, start, target.address, timeout: 1)
            return true
        }
        // A Mac that only joined to send the command gives its slot back, even when the command fails
        defer {
            if !macWasConnected { link.request(disconnect, start, macAddress(), timeout: 1) }
        }
        if disconnecting {
            return confirmed(link.request(disconnect, start, target.address))
        }
        guard confirmed(link.request(connect, start, [0] + target.address)) else { return false }
        return link.waitUntilConnected(target.address)
    }

    // The headphones refuse some requests, for example a phone they can't reach right now
    func confirmed(_ reply: Packet?) -> Bool {
        guard let reply else { return false }
        if reply.op == failed { DispatchQueue.main.async { NSSound.beep() } }
        return reply.op != failed
    }
}

if CommandLine.arguments.contains("--scan") {
    scan()
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
