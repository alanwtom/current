import Foundation
import IOKit.ps
import CurrentCore

/// Watches power state and exposes it to automation. Uses the IOKit power
/// sources API; on desktops without a battery it simply reports "on AC".
@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var isOnBattery = false
    @Published private(set) var isLowPowerMode = false

    nonisolated(unsafe) private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        isOnBattery = Self.queryIsOnBattery() ?? false
    }

    nonisolated private static func queryIsOnBattery() -> Bool? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                  as? [CFTypeRef]
        else { return nil }

        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
               let state = description[kIOPSPowerSourceStateKey] as? String {
                switch state {
                case kIOPSBatteryPowerValue:
                    return true
                case kIOPSACPowerValue:
                    return false
                default:
                    continue
                }
            }
        }
        return nil
    }
}
