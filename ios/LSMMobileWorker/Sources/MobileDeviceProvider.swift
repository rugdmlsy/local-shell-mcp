import CoreMotion
import Foundation
import UIKit

@MainActor
final class MobileDeviceProvider {
    enum DeviceError: LocalizedError {
        case foregroundRequired
        case sensorsUnavailable

        var errorDescription: String? {
            switch self {
            case .foregroundRequired:
                return "Sensor sampling requires LSM Worker to be in the foreground."
            case .sensorsUnavailable:
                return "No supported motion sensors returned a sample."
            }
        }
    }

    private let motion = CMMotionManager()

    func status() -> [String: Any] {
        let process = ProcessInfo.processInfo
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let screen = UIScreen.main
        let fileManager = FileManager.default
        let root = MobileFileStore.root
        let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let level = device.batteryLevel

        let storageTotal: Any = values?.volumeTotalCapacity.map { NSNumber(value: $0) } ?? NSNull()
        let storageAvailable: Any = values?.volumeAvailableCapacityForImportantUsage.map { NSNumber(value: $0) } ?? NSNull()

        return [
            "battery_percent": level < 0 ? NSNull() : Int(level * 100),
            "battery_state": batteryStateName(device.batteryState),
            "low_power_mode": process.isLowPowerModeEnabled,
            "thermal_state": thermalStateName(process.thermalState),
            "system_uptime_s": process.systemUptime,
            "physical_memory_bytes": NSNumber(value: process.physicalMemory),
            "processor_count": process.processorCount,
            "active_processor_count": process.activeProcessorCount,
            "storage_total_bytes": storageTotal,
            "storage_available_bytes": storageAvailable,
            "screen_brightness": Double(screen.brightness),
            "screen_width_points": Double(screen.bounds.width),
            "screen_height_points": Double(screen.bounds.height),
            "screen_scale": Double(screen.scale),
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "preferred_languages": Locale.preferredLanguages,
            "app_state": appStateName(UIApplication.shared.applicationState),
            "files_root_exists": fileManager.fileExists(atPath: root.path),
        ]
    }

    func sensorSnapshot(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard UIApplication.shared.applicationState == .active else {
            throw DeviceError.foregroundRequired
        }
        let requestedMs = (arguments["sample_ms"] as? NSNumber)?.intValue ?? 250
        let sampleMs = min(max(requestedMs, 100), 1_500)
        let interval = max(0.02, min(Double(sampleMs) / 1000.0 / 3.0, 0.2))
        motion.deviceMotionUpdateInterval = interval
        motion.accelerometerUpdateInterval = interval
        motion.gyroUpdateInterval = interval
        motion.magnetometerUpdateInterval = interval

        var deviceMotion: CMDeviceMotion?
        var accelerometer: CMAccelerometerData?
        var gyro: CMGyroData?
        var magnetometer: CMMagnetometerData?

        if motion.isDeviceMotionAvailable {
            motion.startDeviceMotionUpdates(to: .main) { sample, _ in deviceMotion = sample }
        }
        if motion.isAccelerometerAvailable {
            motion.startAccelerometerUpdates(to: .main) { sample, _ in accelerometer = sample }
        }
        if motion.isGyroAvailable {
            motion.startGyroUpdates(to: .main) { sample, _ in gyro = sample }
        }
        if motion.isMagnetometerAvailable {
            motion.startMagnetometerUpdates(to: .main) { sample, _ in magnetometer = sample }
        }
        defer {
            motion.stopDeviceMotionUpdates()
            motion.stopAccelerometerUpdates()
            motion.stopGyroUpdates()
            motion.stopMagnetometerUpdates()
        }

        try await Task.sleep(for: .milliseconds(sampleMs))
        var result: [String: Any] = [
            "sample_ms": sampleMs,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        if let sample = accelerometer {
            result["accelerometer_g"] = vector(sample.acceleration.x, sample.acceleration.y, sample.acceleration.z)
        }
        if let sample = gyro {
            result["rotation_rate_rad_s"] = vector(sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z)
        }
        if let sample = magnetometer {
            result["magnetic_field_uT"] = vector(sample.magneticField.x, sample.magneticField.y, sample.magneticField.z)
        }
        if let sample = deviceMotion {
            result["gravity_g"] = vector(sample.gravity.x, sample.gravity.y, sample.gravity.z)
            result["user_acceleration_g"] = vector(sample.userAcceleration.x, sample.userAcceleration.y, sample.userAcceleration.z)
            result["attitude_rad"] = [
                "roll": sample.attitude.roll,
                "pitch": sample.attitude.pitch,
                "yaw": sample.attitude.yaw,
            ]
        }
        guard result.keys.count > 2 else { throw DeviceError.sensorsUnavailable }
        return result
    }

    private func vector(_ x: Double, _ y: Double, _ z: Double) -> [String: Double] {
        ["x": x, "y": y, "z": z]
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func batteryStateName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }

    private func appStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
