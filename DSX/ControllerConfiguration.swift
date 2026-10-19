//
//  ControllerConfiguration.swift
//  DSX
//
//  Applies controller-specific setup: DS3 activation, DS4/DualSense lights,
//  and the player-number palette.
//

import Foundation
import IOKit.hid
import os.log

// MARK: - Lightbar Settings

struct ControllerLightbarSettings {
    let isEnabled: Bool
    let color: LEDColor

    static func load(from defaults: UserDefaults = .standard) -> ControllerLightbarSettings {
        let red = defaults.object(forKey: AppConstants.Preferences.dualShock4LightbarRed) as? Double ?? 0
        let green = defaults.object(forKey: AppConstants.Preferences.dualShock4LightbarGreen) as? Double ?? 0
        let blue = defaults.object(forKey: AppConstants.Preferences.dualShock4LightbarBlue) as? Double ?? 1

        return ControllerLightbarSettings(
            isEnabled: defaults.object(forKey: AppConstants.Preferences.dualShock4LightbarEnabled) as? Bool ?? true,
            color: LEDColor(red: red, green: green, blue: blue)
        )
    }
}

// MARK: - Configurator

final class ControllerConfigurator {
    static let shared = ControllerConfigurator()

    private let logger = Logger(subsystem: AppConstants.Logging.subsystem,
                                category: AppConstants.Logging.Category.activation)

    /// Serializes light writes so rapid colour changes cannot overlap.
    private let lightQueue = DispatchQueue(label: "org.jamesyoung.DS3Activator.lights")

    private init() {}

    // MARK: DualShock 3 activation

    func activateDualShock3(_ device: IOHIDDevice, named deviceName: String, playerNumber: Int) {
        NotificationManager.shared.notify(
            title: "Activation",
            body: "Starting activation for \(deviceName)",
            isDebug: true
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            self.logger.info("Beginning activation for \(deviceName)")

            // Open device with exclusive access
            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard openResult == kIOReturnSuccess else {
                self.logger.error("Failed to open device: Error 0x\(String(format: "%08X", openResult))")
                NotificationManager.shared.notify(
                    title: "Activation Failed",
                    body: "Could not exclusively access \(deviceName)"
                )
                return
            }

            defer {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                self.logger.info("Device closed after activation attempt")
            }

            // Send feature report (0xF4) - activation command
            let feature: [UInt8] = [0x42, 0x0C, 0x00, 0x00]
            let featureResult = feature.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0xF4, $0.baseAddress!, $0.count)
            }

            guard featureResult == kIOReturnSuccess else {
                self.logger.error("Feature report failed: Error 0x\(String(format: "%08X", featureResult))")
                NotificationManager.shared.notify(
                    title: "Activation Failed",
                    body: "Could not send activation command to \(deviceName)"
                )
                return
            }

            self.logger.info("Feature report sent successfully")

            // Give controller time to process
            Thread.sleep(forTimeInterval: 0.1)

            // Output report (0x01) - set the player LED
            var output = [UInt8](repeating: 0, count: 48)
            output[0] = 0x01
            output[9] = ControllerPlayerPalette.dualShock3LEDMask(for: playerNumber)

            let outputResult = output.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x01, $0.baseAddress!, $0.count)
            }

            if outputResult == kIOReturnSuccess {
                self.logger.info("Activation completed successfully")
                NotificationManager.shared.notify(
                    title: "\(deviceName) Ready",
                    body: "Controller activated and ready (player \(playerNumber))"
                )
            } else {
                self.logger.error("Output report failed: Error 0x\(String(format: "%08X", outputResult))")
                NotificationManager.shared.notify(
                    title: "Activation Issue",
                    body: "LED setup failed for \(deviceName)"
                )
            }
        }
    }

    // MARK: DualShock 4 lightbar

    /// macOS leaves a Bluetooth DualShock 4 pulsing white because it never
    /// sends the lightbar command. Set a solid colour once the pad connects.
    func applyDualShock4Lightbar(
        to device: IOHIDDevice,
        named deviceName: String,
        overBluetooth: Bool,
        playerNumber: Int,
        announce: Bool = true
    ) {
        let settings = ControllerLightbarSettings.load()
        guard settings.isEnabled else {
            logger.info("Lightbar configuration disabled; leaving \(deviceName) unchanged")
            return
        }

        let color = ControllerPlayerPalette.color(for: playerNumber, customColor: settings.color)

        lightQueue.async { [weak self] in
            guard let self else { return }

            var result: IOReturn = kIOReturnError

            // The pad can briefly refuse output reports while it finishes
            // connecting, so retry a few times.
            for attempt in 0..<3 {
                if attempt > 0 {
                    Thread.sleep(forTimeInterval: 0.25)
                }

                result = DualShock4Lightbar.apply(color, to: device, overBluetooth: overBluetooth)

                if result == kIOReturnSuccess { break }
            }

            self.finishLightUpdate(
                result: result,
                deviceName: deviceName,
                announce: announce,
                description: result == kIOReturnSuccess
                    ? "Lightbar colour applied; controller is ready to use"
                    : "Could not set the lightbar on \(deviceName)"
            )
        }
    }

    // MARK: DualSense lights

    func applyDualSenseLights(
        to device: IOHIDDevice,
        named deviceName: String,
        overBluetooth: Bool,
        playerNumber: Int,
        announce: Bool = true,
        waitForConnectionAnimation: Bool = false
    ) {
        // This also keeps Bluetooth pads reporting full input reports so the
        // menu can show battery status.
        if overBluetooth {
            DualSenseLights.enableEnhancedReports(on: device)
        }

        let settings = ControllerLightbarSettings.load()
        guard settings.isEnabled else {
            logger.info("Lightbar configuration disabled; leaving \(deviceName) lights unchanged")
            return
        }

        let color = ControllerPlayerPalette.color(for: playerNumber, customColor: settings.color)
        let repeatForAnimation = overBluetooth && waitForConnectionAnimation

        lightQueue.async { [weak self] in
            guard let self else { return }

            let attempts = repeatForAnimation ? 4 : 3
            var result: IOReturn = kIOReturnError
            var announced = false

            for attempt in 0..<attempts {
                if attempt > 0 {
                    // Bluetooth pads play a connection animation that can
                    // override early writes; space retries past it.
                    Thread.sleep(forTimeInterval: repeatForAnimation ? 1.5 : 0.25)
                }

                result = DualSenseLights.apply(
                    color,
                    player: playerNumber,
                    to: device,
                    overBluetooth: overBluetooth
                )

                if result == kIOReturnSuccess {
                    if announce && !announced {
                        announced = true
                        self.finishLightUpdate(
                            result: result,
                            deviceName: deviceName,
                            announce: true,
                            description: "Player \(playerNumber) lights applied; controller is ready to use"
                        )
                    }
                    if !repeatForAnimation { break }
                }
            }

            if !announced {
                self.finishLightUpdate(
                    result: result,
                    deviceName: deviceName,
                    announce: announce,
                    description: result == kIOReturnSuccess
                        ? "Player \(playerNumber) lights applied"
                        : "Could not set the lights on \(deviceName)"
                )
            }
        }
    }

    // MARK: Shared

    private func finishLightUpdate(
        result: IOReturn,
        deviceName: String,
        announce: Bool,
        description: String
    ) {
        if result == kIOReturnSuccess {
            logger.info("\(description)")
            if announce {
                NotificationManager.shared.notify(
                    title: "\(deviceName) Ready",
                    body: description
                )
            }
        } else {
            logger.error("Light report failed for \(deviceName): Error 0x\(String(format: "%08X", result))")
            NotificationManager.shared.notify(
                title: "Lightbar Issue",
                body: description,
                isDebug: true
            )
        }
    }
}
