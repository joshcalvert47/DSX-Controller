//
//  DS3ActivatorApp.swift
//  DS3Activator
//
//  Created by James Young on 25/4/2025.
//

import SwiftUI
import IOKit.hid
import UserNotifications
import ServiceManagement
import os.log

// MARK: - Global Constants

/// App constants including identifiers and values
enum AppConstants {
    /// UserDefaults keys
    enum Preferences {
        static let showNotifications = "showNotifications"
        static let verboseNotifications = "verboseNotifications"

        // DualShock 4 lightbar
        static let dualShock4LightbarEnabled = "dualShock4LightbarEnabled"
        static let dualShock4LightbarRed = "dualShock4LightbarRed"
        static let dualShock4LightbarGreen = "dualShock4LightbarGreen"
        static let dualShock4LightbarBlue = "dualShock4LightbarBlue"
    }
    
    /// Logger subsystem and categories
    enum Logging {
        static let subsystem = "org.jamesyoung.DS3Activator"
        
        enum Category {
            static let app = "Application"
            static let hid = "HID"
            static let device = "Device"
            static let activation = "Activation"
            static let notification = "Notification"
            static let settings = "Settings"
            static let launchAtLogin = "LaunchAtLogin"
        }
    }
}

// MARK: - Launch at Login Manager

/// Dedicated manager for handling Launch at Login functionality
final class LaunchAtLoginManager {
    // Singleton instance for app-wide access
    static let shared = LaunchAtLoginManager()
    
    // Logger for improved diagnostics
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem, category: AppConstants.Logging.Category.launchAtLogin)
    
    // Private init for singleton pattern
    private init() {}
    
    /// Current status of Launch at Login. A registered service that is still
    /// waiting for the user's approval is treated as enabled so the toggle
    /// matches what the user asked for.
    var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
    
    /// Set Launch at Login status
    /// - Parameter enabled: Whether to enable Launch at Login
    /// - Returns: Result with void on success or error on failure
    func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        let service = SMAppService.mainApp
        
        logger.info("Setting Launch at Login to \(enabled ? "enabled" : "disabled"), current status: \(service.status.description)")
        
        do {
            if enabled {
                // Do not register again while approval is pending.
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                    logger.info("Successfully registered for Launch at Login")
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
                logger.info("Successfully unregistered from Launch at Login")
            }
            return .success(())
        } catch {
            logger.error("Failed to \(enabled ? "register" : "unregister") for Launch at Login: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}

// MARK: - Notification Manager

/// Manages all app notifications
final class NotificationManager {
    static let shared = NotificationManager()
    
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem, category: AppConstants.Logging.Category.notification)
    private let notificationCenter = UNUserNotificationCenter.current()
    
    private init() {}
    
    /// Request notification permissions from the user
    /// - Parameter completion: Called when permission request completes
    func requestPermissions(completion: ((Bool, Error?) -> Void)? = nil) {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.logger.error("Authorization error: \(error.localizedDescription)")
                } else {
                    self?.logger.info("Notification permission \(granted ? "granted" : "denied")")
                }
                completion?(granted, error)
            }
        }
    }
    
    /// Send a notification to the user
    /// - Parameters:
    ///   - title: Notification title
    ///   - body: Notification body text
    ///   - isDebug: Whether this is a debug notification (subject to verbose setting)
    func notify(title: String, body: String, isDebug: Bool = false) {
        // Always log regardless of notification settings
        logger.info("\(isDebug ? "[DEBUG] " : "")\(title): \(body)")
        
        // Only send user notification if enabled
        let shouldShowNotification: Bool
        
        if isDebug {
            shouldShowNotification = UserDefaults.standard.bool(forKey: AppConstants.Preferences.verboseNotifications)
        } else {
            shouldShowNotification = UserDefaults.standard.bool(forKey: AppConstants.Preferences.showNotifications)
        }
        
        guard shouldShowNotification else { return }
        
        let content = UNMutableNotificationContent()
        content.title = isDebug ? "[Debug] \(title)" : title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }
    
    /// Present a critical alert modal to the user
    /// - Parameters:
    ///   - title: Alert title
    ///   - message: Alert message
    ///   - completion: Called when alert is dismissed
    func presentCriticalAlert(title: String, message: String, completion: (() -> Void)? = nil) {
        logger.error("Critical alert: \(title) - \(message)")
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completion?()
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var hidMonitor: ControllerHIDMonitor?
    private var connectedControllers: [String: ControllerDevice] = [:]
    private var playerNumbers: [String: Int] = [:]
    private var batteryStates: [String: ControllerBatteryState] = [:]
    private var settingsWindowController: NSWindowController?
    
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem, category: AppConstants.Logging.Category.app)
    
    // Set default values for user preferences if not already set
    private func registerDefaultPreferences() {
        UserDefaults.standard.register(defaults: [
            AppConstants.Preferences.showNotifications: true,
            AppConstants.Preferences.verboseNotifications: false,
            AppConstants.Preferences.dualShock4LightbarEnabled: true,
            AppConstants.Preferences.dualShock4LightbarRed: 0.0,
            AppConstants.Preferences.dualShock4LightbarGreen: 0.0,
            AppConstants.Preferences.dualShock4LightbarBlue: 1.0
        ])
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register default preferences first
        registerDefaultPreferences()
        
        // Setup notification handling
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermissions()
        
        // Setup UI and HID controller
        setupMenuBar()
        setupHID()
        
        logger.info("DS3Activator launched successfully")
    }
    
    // MARK: - Permissions
    
    func requestNotificationPermissions() {
        NotificationManager.shared.requestPermissions { [weak self] granted, error in
            if let error = error {
                self?.logger.error("Notification permission error: \(error.localizedDescription)")
                NotificationManager.shared.notify(
                    title: "Permissions",
                    body: "Authorization error: \(error.localizedDescription)",
                    isDebug: true
                )
            } else {
                self?.logger.info("Notification permission \(granted ? "granted" : "denied")")
                NotificationManager.shared.notify(
                    title: "Permissions",
                    body: "Permission \(granted ? "granted" : "denied")",
                    isDebug: true
                )
            }
        }
    }
    
    // MARK: - Menu Bar
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "gamecontroller.fill",
            accessibilityDescription: "DSX"
        )
        
        rebuildMenu()
        logger.info("Menu bar setup complete")
    }
    
    /// Rebuilds the menu so the connected-controller list stays current.
    private func rebuildMenu() {
        let menu = NSMenu()
        
        // Add title item
        let titleItem = NSMenuItem(title: "DSX", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())
        
        // Connected controllers
        let controllersTitle = NSMenuItem(title: "Connected Controllers", action: nil, keyEquivalent: "")
        controllersTitle.isEnabled = false
        menu.addItem(controllersTitle)
        
        if connectedControllers.isEmpty {
            let emptyItem = NSMenuItem(title: "  None", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let controllers = connectedControllers.values.sorted {
                playerNumber(for: $0.id) < playerNumber(for: $1.id)
            }
            for controller in controllers {
                let player = playerNumber(for: controller.id)
                var title = "  P\(player)  \(controller.type.displayName) — \(controller.transportDisplayName)"
                if let battery = batteryStates[controller.id] {
                    title += " — \(battery.percent)%"
                    if battery.isCharging {
                        title += " charging"
                    } else if battery.isFull {
                        title += " full"
                    }
                }
                let item = NSMenuItem(
                    title: title,
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        
        menu.addItem(.separator())
        
        // Add settings item
        menu.addItem(
            NSMenuItem(
                title: "Settings…",
                action: #selector(openSettings),
                keyEquivalent: ","
            )
        )
        menu.addItem(.separator())
        
        // Add quit item
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        
        statusItem.menu = menu
    }
    
    @objc private func openSettings() {
        if settingsWindowController == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 470, height: 640),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "DSX Settings"
            // Keep the window alive so Settings can be reopened after closing.
            window.isReleasedWhenClosed = false
            window.contentView = hostingController.view
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Settings window opened")
    }
    
    // MARK: - HID
    
    private func setupHID() {
        do {
            hidMonitor = try ControllerHIDMonitor()
            hidMonitor?.onConnect = { [weak self] controller in self?.deviceConnected(controller) }
            hidMonitor?.onDisconnect = { [weak self] controller in self?.deviceDisconnected(controller) }
            hidMonitor?.onBatteryUpdate = { [weak self] id, battery in
                guard let self, self.connectedControllers[id] != nil else { return }
                self.batteryStates[id] = battery
                self.rebuildMenu()
            }
            NotificationManager.shared.notify(
                title: "HID",
                body: "Controller initialized; awaiting connection…",
                isDebug: true
            )
        } catch {
            logger.error("HID initialization failed: \(error.localizedDescription)")
            NotificationManager.shared.presentCriticalAlert(
                title: "HID Initialization Failed",
                message: "The application cannot detect controllers.\n\nError: \(error.localizedDescription)"
            )
            NotificationManager.shared.notify(
                title: "HID",
                body: "Initialization failed: \(error.localizedDescription)",
                isDebug: true
            )
        }
    }
    
    private func deviceConnected(_ controller: ControllerDevice) {
        // A physical controller can publish more than one HID interface.
        guard connectedControllers[controller.id] == nil else { return }
        connectedControllers[controller.id] = controller
        let player = playerNumber(for: controller.id)
        rebuildMenu()
        
        let name = controller.type.displayName
        logger.info("\(name) connected over \(controller.transportDisplayName) as player \(player)")
        
        NotificationManager.shared.notify(
            title: "Device",
            body: "\(name) connected (\(controller.transportDisplayName), player \(player))",
            isDebug: true
        )
        
        switch controller.type {
        case .dualShock3:
            NotificationManager.shared.notify(
                title: "\(name) Detected",
                body: "Attempting to activate controller…"
            )
            ControllerConfigurator.shared.activateDualShock3(
                controller.device,
                named: name,
                playerNumber: player
            )
        case .dualShock4:
            NotificationManager.shared.notify(
                title: "\(name) Detected",
                body: "Configuring player \(player) lightbar…"
            )
            ControllerConfigurator.shared.applyDualShock4Lightbar(
                to: controller.device,
                named: name,
                overBluetooth: controller.isBluetooth,
                playerNumber: player
            )
        case .dualSense:
            NotificationManager.shared.notify(
                title: "\(name) Detected",
                body: "Configuring player \(player) lights…"
            )
            ControllerConfigurator.shared.applyDualSenseLights(
                to: controller.device,
                named: name,
                overBluetooth: controller.isBluetooth,
                playerNumber: player,
                waitForConnectionAnimation: true
            )
        }
    }
    
    private func deviceDisconnected(_ controller: ControllerDevice) {
        guard connectedControllers.removeValue(forKey: controller.id) != nil else { return }
        playerNumbers.removeValue(forKey: controller.id)
        batteryStates.removeValue(forKey: controller.id)
        rebuildMenu()
        
        let name = controller.type.displayName
        logger.info("\(name) disconnected")
        
        NotificationManager.shared.notify(
            title: "Device",
            body: "\(name) disconnected",
            isDebug: true
        )
    }
    
    /// Returns the player slot for a controller, allocating the lowest free
    /// slot (1-4) when a new controller connects. Slots stay stable for the
    /// life of the connection, like a console.
    private func playerNumber(for id: String) -> Int {
        if let existing = playerNumbers[id] {
            return existing
        }
        
        let used = Set(playerNumbers.values)
        let number = (1...4).first { !used.contains($0) } ?? 4
        playerNumbers[id] = number
        return number
    }
    
    /// Re-applies the lightbar colour to every connected DualShock 4 and
    /// DualSense using its current player slot.
    func applyLightbarSettings() {
        for controller in connectedControllers.values {
            let player = playerNumber(for: controller.id)
            switch controller.type {
            case .dualShock3:
                break
            case .dualShock4:
                ControllerConfigurator.shared.applyDualShock4Lightbar(
                    to: controller.device,
                    named: controller.type.displayName,
                    overBluetooth: controller.isBluetooth,
                    playerNumber: player,
                    announce: false
                )
            case .dualSense:
                ControllerConfigurator.shared.applyDualSenseLights(
                    to: controller.device,
                    named: controller.type.displayName,
                    overBluetooth: controller.isBluetooth,
                    playerNumber: player,
                    announce: false
                )
            }
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        logger.info("User interacted with notification: \(response.notification.request.content.title)")
        completionHandler()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    // Launch at login state
    @State private var launchAtLogin: Bool = false
    @State private var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    
    // Notification settings
    @AppStorage(AppConstants.Preferences.showNotifications) private var showNotifications = true
    @AppStorage(AppConstants.Preferences.verboseNotifications) private var verboseNotifications = false
    
    // DualShock 4 lightbar settings
    @AppStorage(AppConstants.Preferences.dualShock4LightbarEnabled) private var dualShock4LightbarEnabled = true
    @AppStorage(AppConstants.Preferences.dualShock4LightbarRed) private var dualShock4LightbarRed = 0.0
    @AppStorage(AppConstants.Preferences.dualShock4LightbarGreen) private var dualShock4LightbarGreen = 0.0
    @AppStorage(AppConstants.Preferences.dualShock4LightbarBlue) private var dualShock4LightbarBlue = 1.0
    
    @Environment(\.openURL) private var openURL
    
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem, category: AppConstants.Logging.Category.settings)
    
    var body: some View {
        VStack(spacing: 0) {
            header
            
            Form {
                generalSection
                notificationsSection
                lightsSection
            }
            .formStyle(.grouped)
            
            Divider()
            footer
        }
        .frame(minWidth: 440, minHeight: 540)
        .onAppear {
            refreshStatuses()
            logger.info("Settings view appeared, launch at login status: \(launchAtLogin)")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up changes made in System Settings while DSX was inactive.
            refreshStatuses()
        }
    }
    
    // MARK: - Header & Footer
    
    private var header: some View {
        HStack(spacing: 12) {
            appIcon
            
            VStack(alignment: .leading, spacing: 1) {
                Text("DSX")
                    .font(.title3.weight(.semibold))
                Text("PlayStation controller companion")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
    
    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }
    
    private var footer: some View {
        HStack(spacing: 6) {
            Text("DSX")
                .fontWeight(.medium)
            if let version = versionString {
                Text("Version \(version)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
    
    private var versionString: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    
    // MARK: - Sections
    
    private var generalSection: some View {
        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { _, newValue in
                    handleLaunchAtLoginChange(to: newValue)
                }
            
            if launchAtLoginStatus == .requiresApproval {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Approval needed", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    Text("Allow DSX in Login Items to finish turning this on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings…", action: openLoginItemsSettings)
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("General")
        } footer: {
            Text("Start DSX automatically and keep it waiting in the menu bar.")
        }
    }
    
    private var notificationsSection: some View {
        Section {
            Toggle("Show notifications", isOn: $showNotifications)
                .toggleStyle(.switch)
                .onChange(of: showNotifications) { requestPermissionsIfNeeded() }
            
            Toggle("Include diagnostic details", isOn: $verboseNotifications)
                .toggleStyle(.switch)
                .disabled(!showNotifications)
                .help("Adds technical details to notifications for troubleshooting.")
            
            if showNotifications && notificationStatus == .denied {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Notifications are turned off", systemImage: "bell.slash.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    Text("Enable notifications for DSX in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                
                Button("Open Notification Settings…", action: openSystemNotificationSettings)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get notified when a controller connects, activates, or changes its lights.")
        }
    }
    
    private var lightsSection: some View {
        Section {
            Toggle("Set lightbar colour on connect", isOn: $dualShock4LightbarEnabled)
                .toggleStyle(.switch)
                .help("Also stops a Bluetooth DualShock 4 from pulsing white.")
                .onChange(of: dualShock4LightbarEnabled) { applyLightbarSettings() }
            
            LabeledContent("Player 1 colour") {
                ColorPicker("Player 1 lightbar colour", selection: lightbarColor, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel("Player 1 lightbar colour")
            }
            .disabled(!dualShock4LightbarEnabled)
            
            LabeledContent("Player colours") {
                palettePreview
            }
        } header: {
            Text("Controller Lights")
        } footer: {
            Text("Applies to DualShock 4 and DualSense. Players 2–4 use red, green, and pink to keep controllers distinct.")
        }
    }
    
    private var palettePreview: some View {
        HStack(spacing: 12) {
            ForEach(1...4, id: \.self) { player in
                HStack(spacing: 4) {
                    Circle()
                        .fill(swatchColor(for: player))
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    Text("P\(player)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Player \(player) colour")
            }
        }
    }
    
    // MARK: - DualShock 4 Lightbar
    
    private var currentLEDColor: LEDColor {
        LEDColor(red: dualShock4LightbarRed, green: dualShock4LightbarGreen, blue: dualShock4LightbarBlue)
    }
    
    private var lightbarColor: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: dualShock4LightbarRed,
                    green: dualShock4LightbarGreen,
                    blue: dualShock4LightbarBlue
                )
            },
            set: { newColor in
                let nsColor = NSColor(newColor).usingColorSpace(.sRGB)
                    ?? NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
                dualShock4LightbarRed = Double(nsColor.redComponent)
                dualShock4LightbarGreen = Double(nsColor.greenComponent)
                dualShock4LightbarBlue = Double(nsColor.blueComponent)
                applyLightbarSettings()
            }
        )
    }
    
    private func swatchColor(for player: Int) -> Color {
        let led = ControllerPlayerPalette.color(for: player, customColor: currentLEDColor)
        return Color(
            red: Double(led.red) / 255,
            green: Double(led.green) / 255,
            blue: Double(led.blue) / 255
        )
    }
    
    private func applyLightbarSettings() {
        (NSApp.delegate as? AppDelegate)?.applyLightbarSettings()
    }
    
    // MARK: - System Status
    
    private func refreshStatuses() {
        launchAtLoginStatus = SMAppService.mainApp.status
        launchAtLogin = LaunchAtLoginManager.shared.isEnabled
        refreshNotificationStatus()
    }
    
    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationStatus = settings.authorizationStatus
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func requestPermissionsIfNeeded() {
        guard showNotifications else { return }
        NotificationManager.shared.requestPermissions { _, _ in
            refreshNotificationStatus()
        }
    }
    
    private func handleLaunchAtLoginChange(to enabled: Bool) {
        logger.info("Launch at login toggle changed to: \(enabled)")
        
        // Update the system setting
        let result = LaunchAtLoginManager.shared.setEnabled(enabled)
        
        // Handle the result
        switch result {
        case .success:
            launchAtLoginStatus = SMAppService.mainApp.status
            logger.info("Successfully updated launch at login setting")
        case .failure(let error):
            logger.error("Failed to update launch at login: \(error.localizedDescription)")
            
            // Present error and reset toggle state on failure
            presentLaunchAtLoginErrorAlert(error: error)
            
            // Reset toggle to match actual system state (with slight delay to let UI update)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.launchAtLoginStatus = SMAppService.mainApp.status
                self.launchAtLogin = LaunchAtLoginManager.shared.isEnabled
            }
        }
    }
    
    // MARK: - System Settings Links
    
    private func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        openURL(url)
        logger.info("Opened system notification settings")
    }
    
    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        openURL(url)
        logger.info("Opened system login items settings")
    }
    
    // MARK: - Error Alert
    
    private func presentLaunchAtLoginErrorAlert(error: Error) {
        logger.error("Presenting launch at login error alert: \(error.localizedDescription)")
        
        let alert = NSAlert()
        alert.messageText = "Launch at Login Error"
        
        // Create a more detailed message based on error type
        var detailedMessage = "Could not change the 'Launch at Login' setting.\n\n"
        
        if let nsError = error as NSError? {
            switch nsError.domain {
            case "com.apple.ServiceManagement":
                if nsError.code == 1 { // Common error for lack of authorization
                    detailedMessage += "This may require system authorization. Please try changing this setting in System Settings > General > Login Items instead."
                } else {
                    detailedMessage += "Error: \(error.localizedDescription)"
                }
            default:
                detailedMessage += "Error: \(error.localizedDescription)"
            }
        } else {
            detailedMessage += "Error: \(error.localizedDescription)"
        }
        
        detailedMessage += "\n\nYou can also manage login items directly in System Settings."
        
        alert.informativeText = detailedMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        
        // Add a button to open System Settings
        alert.addButton(withTitle: "Open System Settings")
        
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            openLoginItemsSettings()
        }
    }
}

// MARK: - SMAppService.Status Extension

extension SMAppService.Status {
    var description: String {
        switch self {
        case .notRegistered: return "Not Registered"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Requires Approval"
        case .notFound: return "Not Found"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - App Entry Point

@main
struct DS3ActivatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        Settings {
            // An EmptyView is sufficient here since we manage windows manually
            EmptyView()
        }
    }
}
