import Foundation
import IOKit

@MainActor
final class EOS1VDeviceMonitor {
    nonisolated private static let vendorID = 0x04A9
    nonisolated private static let productID = 0x3040

    var onPresenceChanged: ((Bool) -> Void)?
    private var timer: Timer?
    private var lastPresence: Bool?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let present = Self.isCablePresent()
        guard present != lastPresence else { return }
        lastPresence = present
        onPresenceChanged?(present)
    }

    private nonisolated static func isCablePresent() -> Bool {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else {
            return false
        }
        matching["idVendor"] = vendorID
        matching["idProduct"] = productID
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }
}
