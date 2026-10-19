//
//  ControllerHIDMonitor.swift
//  DS3Activator
//
//  Watches for supported controllers and reports connections, removals,
//  and battery updates.
//

import Foundation
import IOKit.hid
import os.log

final class ControllerHIDMonitor {
    private let hidManager: IOHIDManager
    /// The run loop the manager is scheduled on. Callbacks are delivered here.
    private let runLoop: CFRunLoop
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem,
                                category: AppConstants.Logging.Category.hid)

    private var controllers: [String: ControllerDevice] = [:]
    private var lastBattery: [String: ControllerBatteryState] = [:]

    var onConnect: ((ControllerDevice) -> Void)?
    var onDisconnect: ((ControllerDevice) -> Void)?
    var onBatteryUpdate: ((String, ControllerBatteryState) -> Void)?

    init(runLoop: CFRunLoop = CFRunLoopGetMain()) throws {
        self.runLoop = runLoop
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        logger.info("IOHIDManager created")

        let criteria = ControllerType.matchingCriteria()
        IOHIDManagerSetDeviceMatchingMultiple(hidManager, criteria as CFArray)
        logger.info("Matching \(criteria.count) controller interface criteria")

        // The manager is owned by this instance, so the callbacks can use an
        // unretained reference: they are unregistered before deallocation.
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, { context, _, _, device in
            guard let context else { return }
            let instance = Unmanaged<ControllerHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            instance.handleConnect(device)
        }, opaqueSelf)

        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, { context, _, _, device in
            guard let context else { return }
            let instance = Unmanaged<ControllerHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            instance.handleDisconnect(device)
        }, opaqueSelf)

        IOHIDManagerRegisterInputReportCallback(hidManager, { context, _, sender, _, reportID, report, reportLength in
            guard let context, let sender else { return }
            let instance = Unmanaged<ControllerHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            let device = unsafeBitCast(sender, to: IOHIDDevice.self)
            instance.handleInputReport(
                device: device,
                reportID: reportID,
                report: report,
                reportLength: reportLength
            )
        }, opaqueSelf)

        IOHIDManagerScheduleWithRunLoop(hidManager, runLoop, CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            let errorMessage = String(format: "IOHIDManagerOpen failed (0x%08X)", result)
            logger.error("\(errorMessage)")
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }

        logger.info("IOHIDManager opened successfully")
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(hidManager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        logger.info("IOHIDManager closed & callbacks released")
    }

    private func handleConnect(_ device: IOHIDDevice) {
        guard let controller = ControllerDevice.make(from: device) else { return }
        guard controllers[controller.id] == nil else { return }

        controllers[controller.id] = controller
        logger.info("\(controller.type.displayName) connected over \(controller.transportDisplayName)")

        // DS4/DualSense need to stay open so we receive input reports for
        // battery status. The DS3 is opened exclusively for activation.
        if controller.type != .dualShock3 {
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess {
                logger.debug("Could not open \(controller.type.displayName) for battery monitoring: 0x\(String(format: "%08X", result))")
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.onConnect?(controller)
        }
    }

    private func handleDisconnect(_ device: IOHIDDevice) {
        // Use the tracked controller when possible; device properties may
        // already be unavailable by the time the removal callback fires.
        let controller = controllers.values.first { $0.device == device }
            ?? ControllerDevice.make(from: device)
        guard let controller,
              controllers.removeValue(forKey: controller.id) != nil else { return }

        lastBattery[controller.id] = nil

        if controller.type != .dualShock3 {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        logger.info("\(controller.type.displayName) disconnected")
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnect?(controller)
        }
    }

    private func handleInputReport(
        device: IOHIDDevice,
        reportID: UInt32,
        report: UnsafePointer<UInt8>?,
        reportLength: CFIndex
    ) {
        guard let report, reportLength > 0 else { return }
        guard let controller = controllers.values.first(where: { $0.device == device }) else { return }
        guard controller.type == .dualShock4 || controller.type == .dualSense else { return }

        let buffer = UnsafeBufferPointer(start: report, count: reportLength)
        guard let battery = ControllerBattery.parse(
            buffer,
            type: controller.type,
            isBluetooth: controller.isBluetooth
        ) else {
            return
        }

        // Input reports arrive at several hundred hertz; only surface changes.
        guard lastBattery[controller.id] != battery else { return }
        lastBattery[controller.id] = battery

        DispatchQueue.main.async { [weak self] in
            self?.onBatteryUpdate?(controller.id, battery)
        }
    }
}
