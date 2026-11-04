import Foundation

struct PairedDevice: Codable, Identifiable {
    let address: [UInt8]
    let name: String
    var connected = false
    var active = false
    var id: [UInt8] { address }

    var displayName: String {
        if let prefix = name.range(of: "’s ") ?? name.range(of: "'s ") {
            return String(name[prefix.upperBound...])
        }
        return name
    }

    var symbol: String {
        if name.localizedCaseInsensitiveContains("iPhone") { return "iphone" }
        if name.localizedCaseInsensitiveContains("Mac") { return "laptopcomputer" }
        if name.localizedCaseInsensitiveContains("TV") { return "appletv" }
        return "pc"
    }
}

enum ActionResult {
    case confirmed, refused, timeout
}

enum RowAction: Equatable {
    case idle
    case working(disconnecting: Bool)
    case failed(reason: String)
    case confirmed

    var working: Bool {
        if case .working = self { return true }
        return false
    }
}

struct DeviceState {
    var devices: [PairedDevice] = []
    private var updatedAt: [[UInt8]: Date] = [:]
    private var protectedUntil: [[UInt8]: Date] = [:]
    private var order: [[UInt8]] = []

    // Missing answers leave the current device alone, including its confirmed state
    mutating func merge(_ reading: DeviceReading) {
        let address = reading.device.address
        guard reading.requestedAt >= (updatedAt[address] ?? .distantPast) else { return }
        if let index = devices.firstIndex(where: { $0.address == address }) {
            if devices[index].connected != reading.device.connected,
               reading.requestedAt < (protectedUntil[address] ?? .distantPast) { return }
            devices[index] = reading.device
        } else {
            devices.append(reading.device)
        }
        updatedAt[address] = reading.requestedAt
        sort()
    }

    // Info can lag a command by two seconds, even when requested after confirmation
    mutating func confirm(_ address: [UInt8], connected: Bool, at date: Date = Date()) {
        if let index = devices.firstIndex(where: { $0.address == address }) {
            devices[index].connected = connected
            if !connected { devices[index].active = false }
        }
        updatedAt[address] = date
        protectedUntil[address] = date.addingTimeInterval(2.5)
    }

    mutating func reorder(_ addresses: [[UInt8]]) {
        order = addresses
        sort()
    }

    private mutating func sort() {
        let previous = devices.map(\.address)
        devices.sort {
            (order.firstIndex(of: $0.address) ?? order.count + (previous.firstIndex(of: $0.address) ?? 0)) <
            (order.firstIndex(of: $1.address) ?? order.count + (previous.firstIndex(of: $1.address) ?? 0))
        }
    }
}
