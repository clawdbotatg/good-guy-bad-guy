import Foundation
import MLXLMCommon
import UIKit

/// Device-side tools for the on-device identifier. Everything runs locally —
/// tool results go into the local model's context only, never off the device.
///
/// Adding a tool: define Input/Output Codable types + a `Tool`, then list it
/// in `specs` and `dispatch`.
enum PhoneTools {

    // MARK: get_device_status

    struct DeviceStatusInput: Codable {}
    struct DeviceStatus: Codable {
        let battery_percent: Int
        let battery_state: String
        let ios_version: String
        let current_date_time: String
    }

    static let deviceStatus = Tool<DeviceStatusInput, DeviceStatus>(
        name: "get_device_status",
        description:
            "Get the phone's battery level and charging state, iOS version, and the current date and time.",
        parameters: []
    ) { _ in
        await MainActor.run {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let state: String =
                switch device.batteryState {
                case .charging: "charging"
                case .full: "full"
                case .unplugged: "on battery"
                default: "unknown"
                }
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE MMM d yyyy, h:mm a"
            return DeviceStatus(
                battery_percent: Int(device.batteryLevel * 100),
                battery_state: state,
                ios_version: device.systemVersion,
                current_date_time: formatter.string(from: Date())
            )
        }
    }

    // MARK: wiring

    static var specs: [ToolSpec] {
        [deviceStatus.schema]
    }

    /// Execute a tool call from the model, returning JSON for the tool-result
    /// message. Errors come back as `{"error": …}` so the model can explain
    /// the failure instead of the whole generation aborting.
    static func dispatch(_ call: ToolCall) async -> String {
        do {
            switch call.function.name {
            case deviceStatus.name:
                return try encode(await call.execute(with: deviceStatus))
            default:
                return #"{"error": "unknown tool '\#(call.function.name)'"}"#
            }
        } catch {
            return #"{"error": "\#(error.localizedDescription)"}"#
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
    }

    enum ToolFailure: LocalizedError {
        case denied(String)
        case bad(String)
        var errorDescription: String? {
            switch self {
            case .denied(let source):
                "The user has not granted access to \(source). They can enable it in Settings."
            case .bad(let reason):
                reason
            }
        }
    }
}
