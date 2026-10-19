//
//  ControllerBattery.swift
//  DS3Activator
//
//  Parses battery status from Sony controller input reports.
//

import Foundation

struct ControllerBatteryState: Equatable {
    enum PowerState: String {
        case discharging
        case charging
        case full
    }

    let percent: Int
    let powerState: PowerState

    var isCharging: Bool { powerState == .charging }
    var isFull: Bool { powerState == .full }
}

enum ControllerBattery {
    /// Input report buffers include the report ID as their first byte.
    static func parse(
        _ report: UnsafeBufferPointer<UInt8>,
        type: ControllerType,
        isBluetooth: Bool
    ) -> ControllerBatteryState? {
        guard let reportID = report.first else { return nil }

        switch type {
        case .dualShock3:
            return nil
        case .dualShock4:
            return parseDualShock4(report, reportID: reportID, isBluetooth: isBluetooth)
        case .dualSense:
            return parseDualSense(report, reportID: reportID, isBluetooth: isBluetooth)
        }
    }

    /// Convenience overload for tests and callers with an array.
    static func parse(
        _ report: [UInt8],
        type: ControllerType,
        isBluetooth: Bool
    ) -> ControllerBatteryState? {
        report.withUnsafeBufferPointer {
            parse($0, type: type, isBluetooth: isBluetooth)
        }
    }

    // MARK: - DualShock 4

    private static func parseDualShock4(
        _ report: UnsafeBufferPointer<UInt8>,
        reportID: UInt8,
        isBluetooth: Bool
    ) -> ControllerBatteryState? {
        let expectedReportID: UInt8 = isBluetooth ? 0x11 : 0x01
        guard reportID == expectedReportID else { return nil }

        // The Bluetooth report has two extra bytes before the state payload.
        let offset = 30 + (isBluetooth ? 2 : 0)
        guard report.count > offset else { return nil }

        let status = report[offset]
        var level = Int(status & 0x0F)
        let cableConnected = (status & 0x10) != 0

        // Bluetooth reports 0...9; USB reports 0...10.
        if isBluetooth && !cableConnected && level < 10 {
            level += 1
        }

        let powerState: ControllerBatteryState.PowerState
        if cableConnected {
            powerState = level >= 10 ? .full : .charging
        } else {
            powerState = .discharging
        }

        return ControllerBatteryState(
            percent: min(level * 10, 100),
            powerState: powerState
        )
    }

    // MARK: - DualSense

    private static func parseDualSense(
        _ report: UnsafeBufferPointer<UInt8>,
        reportID: UInt8,
        isBluetooth: Bool
    ) -> ControllerBatteryState? {
        let expectedReportID: UInt8 = isBluetooth ? 0x31 : 0x01
        guard reportID == expectedReportID else { return nil }

        // Byte 53 in the USB report; the Bluetooth report has one extra
        // header byte before the state payload.
        let offset = 53 + (isBluetooth ? 1 : 0)
        guard report.count > offset else { return nil }

        let status = report[offset]
        let level = UInt8(status & 0x0F)
        // 0x0C means the controller is not reporting a battery level.
        guard level != 0x0C else { return nil }

        let percent: Int
        let powerState: ControllerBatteryState.PowerState

        switch (status >> 4) & 0x0F {
        case 0:
            percent = min(Int(level) * 10 + 5, 100)
            powerState = .discharging
        case 1:
            percent = min(Int(level) * 10 + 5, 100)
            powerState = .charging
        case 2:
            percent = 100
            powerState = .full
        default:
            return nil
        }

        return ControllerBatteryState(percent: percent, powerState: powerState)
    }
}
