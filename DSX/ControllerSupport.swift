//
//  ControllerSupport.swift
//  DS3Activator
//
//  Shared controller model. Add a case here (plus a configurator) to support
//  another Sony controller.
//

import Foundation
import IOKit.hid

// MARK: - Controller Types

enum ControllerType: String, CaseIterable {
    case dualShock3
    case dualShock4
    case dualSense

    /// Sony Interactive Entertainment
    static let sonyVendorID = 0x054C

    var displayName: String {
        switch self {
        case .dualShock3: return "DualShock 3"
        case .dualShock4: return "DualShock 4"
        case .dualSense: return "DualSense"
        }
    }

    var productIDs: [Int] {
        switch self {
        case .dualShock3:
            return [0x0268]
        case .dualShock4:
            // v1 USB, v2 USB, Bluetooth
            return [0x05C4, 0x09CC, 0x081F]
        case .dualSense:
            // DualSense and DualSense Edge, USB and Bluetooth
            return [0x0CE6, 0x0DF2]
        }
    }

    /// Whether the controller needs the DS3 activation feature report.
    var requiresActivation: Bool {
        self == .dualShock3
    }

    /// Whether we can set an LED colour on the controller.
    var supportsLightbar: Bool {
        self == .dualShock4 || self == .dualSense
    }

    static func type(vendorID: Int, productID: Int) -> ControllerType? {
        guard vendorID == sonyVendorID else { return nil }
        return allCases.first { $0.productIDs.contains(productID) }
    }

    static func matchingCriteria() -> [[String: Any]] {
        allCases.flatMap { type in
            type.productIDs.map { productID in
                [
                    kIOHIDVendorIDKey as String: sonyVendorID,
                    kIOHIDProductIDKey as String: productID
                ]
            }
        }
    }
}

// MARK: - Connected Device

/// A physical controller discovered by the HID manager.
struct ControllerDevice: Identifiable {
    /// Stable identity for a physical controller. A single controller can
    /// publish more than one HID interface, so we deduplicate using the
    /// serial number (Bluetooth) or location ID (USB).
    let id: String
    let type: ControllerType
    let device: IOHIDDevice
    let productName: String
    let transport: String
    let isBluetooth: Bool
    let vendorID: Int
    let productID: Int

    static func make(from device: IOHIDDevice) -> ControllerDevice? {
        guard
            let vendorID = integerProperty(device, kIOHIDVendorIDKey),
            let productID = integerProperty(device, kIOHIDProductIDKey),
            let type = ControllerType.type(vendorID: vendorID, productID: productID)
        else {
            return nil
        }

        let transport = stringProperty(device, kIOHIDTransportKey) ?? "Unknown"
        let productName = stringProperty(device, kIOHIDProductKey) ?? type.displayName
        let serial = stringProperty(device, kIOHIDSerialNumberKey)
        let location = integerProperty(device, kIOHIDLocationIDKey)

        let identity = serial ?? location.map(String.init) ?? "\(productID)"
        let isBluetooth = transport.localizedCaseInsensitiveContains("bluetooth")
            || productID == 0x081F

        return ControllerDevice(
            id: "\(type.rawValue):\(identity)",
            type: type,
            device: device,
            productName: productName,
            transport: transport,
            isBluetooth: isBluetooth,
            vendorID: vendorID,
            productID: productID
        )
    }

    var transportDisplayName: String {
        if isBluetooth { return "Bluetooth" }
        if transport.isEmpty || transport == "Unknown" { return "USB" }
        return transport
    }
}

// MARK: - HID Property Helpers

private func integerProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
}

private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(device, key as CFString) as? String
}
