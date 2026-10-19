//
//  ControllerLightReports.swift
//  DSX
//
//  Pure output-report builders for Sony controller lights. Kept separate from
//  the configurator so the byte layouts can be tested directly.
//

import Foundation
import IOKit.hid

// MARK: - CRC32

/// Standard reflected CRC-32 (poly 0xEDB88320), required by the DualShock 4
/// and DualSense Bluetooth output reports.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0
                ? 0xEDB88320 ^ (value >> 1)
                : value >> 1
        }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - LED Colour

struct LEDColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Components are clamped to 0...1.
    init(red: Double, green: Double, blue: Double) {
        self.init(
            red: UInt8((max(0, min(1, red)) * 255).rounded()),
            green: UInt8((max(0, min(1, green)) * 255).rounded()),
            blue: UInt8((max(0, min(1, blue)) * 255).rounded())
        )
    }

    static let blue = LEDColor(red: UInt8(0), green: UInt8(0), blue: UInt8(255))
}

/// Player colours and LED patterns. Player 1 uses the user's chosen colour;
/// additional players get distinct colours so pads are easy to tell apart.
enum ControllerPlayerPalette {
    static func color(for player: Int, customColor: LEDColor) -> LEDColor {
        switch player {
        case 1:
            return customColor
        case 2:
            return LEDColor(red: UInt8(255), green: UInt8(40), blue: UInt8(40))
        case 3:
            return LEDColor(red: UInt8(40), green: UInt8(220), blue: UInt8(80))
        case 4:
            return LEDColor(red: UInt8(255), green: UInt8(0), blue: UInt8(200))
        default:
            return LEDColor(red: UInt8(255), green: UInt8(150), blue: UInt8(0))
        }
    }

    /// DualShock 3 LEDs 1-4 live in bits 1-4 of output report byte 9.
    static func dualShock3LEDMask(for player: Int) -> UInt8 {
        let index = max(0, min(3, player - 1))
        return 0x02 << UInt8(index)
    }

    /// DualSense has five player LEDs. These are the patterns the PS5 uses;
    /// 0x20 requests an immediate change instead of a fade.
    static func dualSensePlayerLEDs(for player: Int) -> UInt8 {
        let patterns: [UInt8] = [0x04, 0x0A, 0x15, 0x1B, 0x1F]
        let index = max(0, min(patterns.count - 1, player - 1))
        return patterns[index] | 0x20
    }
}

// MARK: - DualShock 4 Lightbar

enum DualShock4Lightbar {
    /// USB output report 0x05. macOS expects the report ID as the first
    /// buffer byte for numbered reports, in addition to the reportID argument.
    static func usbReport(for color: LEDColor) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 32)
        report[0] = 0x05 // report ID
        report[1] = 0xFF // enable rumble + lightbar + flash
        report[6] = color.red
        report[7] = color.green
        report[8] = color.blue
        return report
    }

    /// Bluetooth output report 0x11. The controller validates a CRC32 over a
    /// 0xA2 prefix plus the report, and ignores reports with a bad checksum.
    static func bluetoothReport(for color: LEDColor) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 78)
        report[0] = 0x11 // report ID
        report[1] = 0xC0 // HID output + CRC enabled
        report[3] = 0x07 // rumble + lightbar + flash
        report[8] = color.red
        report[9] = color.green
        report[10] = color.blue

        let crc = CRC32.checksum([0xA2] + Array(report[0..<74]))
        report[74] = UInt8(crc & 0xFF)
        report[75] = UInt8((crc >> 8) & 0xFF)
        report[76] = UInt8((crc >> 16) & 0xFF)
        report[77] = UInt8((crc >> 24) & 0xFF)

        return report
    }

    static func apply(_ color: LEDColor, to device: IOHIDDevice, overBluetooth: Bool) -> IOReturn {
        send(
            report: overBluetooth ? bluetoothReport(for: color) : usbReport(for: color),
            reportID: overBluetooth ? 0x11 : 0x05,
            to: device
        )
    }

    fileprivate static func send(report: [UInt8], reportID: CFIndex, to device: IOHIDDevice) -> IOReturn {
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { return openResult }

        defer {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        return report.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                reportID,
                baseAddress,
                buffer.count
            )
        }
    }
}

// MARK: - DualSense Lights

enum DualSenseLights {
    /// The DS5 effects payload is 47 bytes. Lightbar control is bit 2 of the
    /// second enable byte and player LEDs are bit 4.
    private static func effectsReport(for color: LEDColor, player: Int) -> [UInt8] {
        var effects = [UInt8](repeating: 0, count: 47)
        effects[1] = 0x14 // enable lightbar + player indicator
        effects[43] = ControllerPlayerPalette.dualSensePlayerLEDs(for: player)
        effects[44] = color.red
        effects[45] = color.green
        effects[46] = color.blue
        return effects
    }

    static func usbReport(for color: LEDColor, player: Int) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 48)
        report[0] = 0x02 // report ID
        report.replaceSubrange(1..<48, with: effectsReport(for: color, player: player))
        return report
    }

    /// Bluetooth output report 0x31: report ID, sequence/tag bytes, the
    /// effects payload, and a CRC32 at the end.
    static func bluetoothReport(for color: LEDColor, player: Int) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 78)
        report[0] = 0x31 // report ID
        report[1] = 0x00 // tag/sequence
        report[2] = 0x10 // DS_OUTPUT_TAG
        report.replaceSubrange(3..<50, with: effectsReport(for: color, player: player))

        let crc = CRC32.checksum([0xA2] + Array(report[0..<74]))
        report[74] = UInt8(crc & 0xFF)
        report[75] = UInt8((crc >> 8) & 0xFF)
        report[76] = UInt8((crc >> 16) & 0xFF)
        report[77] = UInt8((crc >> 24) & 0xFF)

        return report
    }

    static func apply(_ color: LEDColor, player: Int, to device: IOHIDDevice, overBluetooth: Bool) -> IOReturn {
        DualShock4Lightbar.send(
            report: overBluetooth ? bluetoothReport(for: color, player: player) : usbReport(for: color, player: player),
            reportID: overBluetooth ? 0x31 : 0x02,
            to: device
        )
    }

    /// Reading feature report 0x05 switches a Bluetooth DualSense from the
    /// truncated 0x01 input report to the full 0x31 report (needed for
    /// battery status). It does not change the lights.
    static func enableEnhancedReports(on device: IOHIDDevice) {
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { return }
        defer {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        var report = [UInt8](repeating: 0, count: 64)
        var length = CFIndex(report.count)
        _ = report.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                0x05,
                buffer.baseAddress!,
                &length
            )
        }
    }
}
