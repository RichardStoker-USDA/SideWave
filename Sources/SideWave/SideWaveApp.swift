// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Sparkle
import SwiftUI

import TipKit

@main
struct SideWaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @AppStorage("appearance") private var appearance: String = "system"
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false
    @AppStorage(WindowAppearance.opacityKey) private var windowOpacity = WindowAppearance.defaultOpacity
    @Environment(\.openWindow) private var openWindow

    /// Toggles when macOS system appearance changes. Forces SwiftUI to
    /// re-evaluate the `colorScheme` computed property, which otherwise
    /// wouldn't re-run because `appearance` stays "system".
    @State private var systemAppearanceTick = false

    init() {
        guard !AppPaths.isTestHost else { return }
        // Configure TransparencyURLProtocol to capture all outbound/inbound traffic
        URLProtocol.registerClass(TransparencyURLProtocol.self)
        TransparencyURLProtocol.setupSwizzling()

        // Each tip has its own display limit and event rule, so there's no global daily limit; TipKit's
        // daily counter also survived `Tips.resetDatastore()` and kept Reset Hints from showing tips again.
        // `.immediate` shows a tip as soon as its rule is met.
        try? Tips.configure([
            .displayFrequency(.immediate)
        ])
    }

    var body: some Scene {
        // Main window (Dashboard + History + Dictionary)
        WindowGroup {
            ContentView()
                .environment(appState)
                .preferredColorScheme(colorScheme)
                .frame(minWidth: 675, minHeight: 670)
                .background(MainWindowReader())
                #if DEBUG
                .overlay(alignment: .bottomTrailing) {
                    if AppPaths.showsDebugLabels {
                        GeometryReader { geo in
                            Text("\(Int(geo.size.width)) x \(Int(geo.size.height))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.5))
                                .padding(4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if AppPaths.showsDebugLabels {
                        Text("\(Self.appVersion) (\(Self.appBuild))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .padding(4)
                            .accessibilityHidden(true)
                    }
                }
                #endif
                .modifier(ModelRecoveryWindowPresenter(appState: appState))
                .onAppear {
                    appState.startServices()
                    GlossaryBundleManager.shared.startAutomaticUpdates()
                    switch appearance {
                    case "light":
                        NSApp.appearance = NSAppearance(named: .aqua)
                    case "dark":
                        NSApp.appearance = NSAppearance(named: .darkAqua)
                    default:
                        NSApp.appearance = nil
                    }

                    // Observe macOS appearance changes (System Settings > Appearance).
                    // When the user switches macOS dark/light and SideWave theme is "System",
                    // toggling systemAppearanceTick forces SwiftUI to re-evaluate colorScheme.
                    DistributedNotificationCenter.default().addObserver(
                        forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                        object: nil,
                        queue: .main
                    ) { _ in
                        MainActor.assumeIsolated {
                            guard self.appearance == "system" else { return }
                            // Small delay: UserDefaults "AppleInterfaceStyle" updates
                            // slightly after the notification fires.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                MainActor.assumeIsolated {
                                    self.systemAppearanceTick.toggle()

                                    // Force toolbar chrome to re-render by briefly setting an
                                    // explicit appearance then clearing it. Just setting nil
                                    // doesn't always flush cached NSSegmentedControl rendering.
                                    let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
                                    let tempAppearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                                    NSApp.appearance = tempAppearance
                                    for window in NSApp.windows {
                                        window.appearance = tempAppearance
                                        // Force toolbar items to invalidate
                                        window.toolbar?.validateVisibleItems()
                                    }
                                    // Then set to nil so it follows system going forward
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        MainActor.assumeIsolated {
                                            NSApp.appearance = nil
                                            for window in NSApp.windows {
                                                window.appearance = nil
                                            }
                                            Self.invalidateAllWindows()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Make windows translucent so the desktop shows through, including Settings and
                    // Help, which are created later.
                    Self.applyTransparencyToAllWindows()

                    // Observe new windows being added
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didBecomeKeyNotification,
                        object: nil,
                        queue: .main
                    ) { notification in
                        let window = notification.object as? NSWindow
                        MainActor.assumeIsolated {
                            guard let window else { return }
                            guard window.styleMask.contains(.titled) else { return }
                            // Skip small windows such as the About panel.
                            guard window.frame.width >= 500 else { return }
                            if window.isOpaque {
                                window.isOpaque = false
                                window.backgroundColor = .clear
                            }
                        }
                    }
                }
                .onChange(of: appearance) { _, newValue in
                    // AppKit windows get nil for "system" so they follow macOS, while SwiftUI
                    // always receives an explicit light or dark scheme so it updates correctly.
                    let newAppearance: NSAppearance? = switch newValue {
                    case "light": NSAppearance(named: .aqua)
                    case "dark": NSAppearance(named: .darkAqua)
                    default: nil  // Follow system for AppKit
                    }

                    NSApp.appearance = newAppearance
                    for window in NSApp.windows {
                        window.appearance = newAppearance
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        Self.invalidateAllWindows()
                    }
                }
                .onChange(of: appState.showMainWindow) {
                    if appState.showMainWindow {
                        NSApp.activate()
                        let mainWindow = MainWindowTracker.mainWindow()
                        if let mainWindow {
                            mainWindow.makeKeyAndOrderFront(nil)
                        }
                        appState.showMainWindow = false
                    }
                }
        }
        .defaultSize(width: 675, height: 670)
        .windowToolbarStyle(.unified(showsTitle: false))
        // Always present the main window at launch, whatever restoration chose.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appInfo) {
                Button("About SideWave") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "SideWave",
                        .credits: NSAttributedString(
                            string: "Richard Stoker\nApache License 2.0\nCopyright \u{00A9} 2026 Richard Stoker",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                                .foregroundColor: NSColor.secondaryLabelColor,
                                .paragraphStyle: {
                                    let ps = NSMutableParagraphStyle()
                                    ps.alignment = .center
                                    return ps
                                }(),
                            ]
                        ),
                    ])
                }

                Button("Check for Updates\u{2026}") {
                    appState.updaterController.updater.checkForUpdates()
                }
                .disabled(!appState.supportsAppUpdates || !appState.updaterController.updater.canCheckForUpdates)
            }

            // Settings is a Window scene, so its menu item is added here.
            CommandGroup(replacing: .appSettings) {
                Toggle("Advanced View", isOn: Binding(
                    get: { showAdvancedControls },
                    set: { newValue in
                        showAdvancedControls = newValue
                        appState.showToast(newValue ? "Advanced view on" : "Advanced view off",
                                           icon: "slider.horizontal.3")
                    }
                ))

                Button("Settings\u{2026}") {
                    openWindow(id: "settings")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // View menu: appearance
            CommandGroup(after: .toolbar) {
                Toggle("Light Appearance", isOn: appearanceBinding("light"))
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Toggle("Dark Appearance", isOn: appearanceBinding("dark"))
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Toggle("System Appearance", isOn: appearanceBinding("system"))
                    .keyboardShortcut("0", modifiers: [.command, .option])

                #if DEBUG
                Divider()
                Button("Reset App Settings") {
                    appState.resetAppSettingsToDefaults()
                    appState.showToast("App settings reset", icon: "arrow.counterclockwise")
                }
                #endif
            }

            CommandMenu("Dictation") {
                Toggle("Send to Chosen App", isOn: Binding(
                    get: { appState.dictationTargetMode == DictationTargetMode.assignedWindow.rawValue },
                    set: { _ in
                        appState.toggleTargetMode()
                        let assigned = appState.dictationTargetMode == DictationTargetMode.assignedWindow.rawValue
                        appState.showToast(assigned ? "Sending to the chosen app" : "Sending to the current app",
                                           icon: "arrow.right.doc.on.clipboard")
                    }
                ))
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Toggle("Add Trailing Space", isOn: Binding(
                    get: { appState.appendTrailingSpace },
                    set: { newValue in
                        appState.appendTrailingSpace = newValue
                        appState.showToast(newValue ? "Trailing space on" : "Trailing space off", icon: "space")
                    }
                ))
                .keyboardShortcut(.space, modifiers: [.command, .shift])

                Divider()

                Button("SideWave Mini") {
                    UserDefaults.standard.set("mini", forKey: "mainWindowMode")
                    openWindow(id: "mini")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            // Help menu
            CommandGroup(replacing: .help) {
                Button("SideWave Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Take a Tour") {
                    appState.tutorialState.reset()
                    appState.requestedPage = .home
                    appState.showMainWindow = true
                    appState.showTutorial = true
                }
                .disabled(appState.isDictationBusy || appState.meetingService.isCaptureActive)

                Divider()

                Button("Data Transparency") {
                    openWindow(id: "data-transparency")
                }

                Divider()

                Button("Reset Hints") {
                    Task { @MainActor in
                        // Show the dashboard first so the tip's anchor is on
                        // screen, and let TipKit finish its reset before
                        // donating again.
                        try? Tips.resetDatastore()
                        appState.requestedPage = .home
                        appState.showMainWindow = true
                        try? await Task.sleep(for: .milliseconds(400))
                        await FirstLaunchDashboardTip.settled.donate()
                        NotificationCenter.default.post(
                            name: .sideWaveResetHints, object: nil
                        )
                        appState.showToast(
                            "Hints reset. A tip will appear on the dashboard in a few seconds.",
                            icon: "arrow.counterclockwise"
                        )
                    }
                }
            }
        }

        // A Window rather than a Settings scene, so Settings shares Help's
        // single-row unified toolbar. Command-comma is wired in the app menu.
        Window("Settings", id: "settings") {
            AppSettingsView()
                .environment(appState)
                .preferredColorScheme(colorScheme)
                .background {
                    WindowBackgroundView(opacity: windowOpacity)
                    .ignoresSafeArea()
                }
                .overlay(alignment: .bottomTrailing) { Self.debugDimensionsOverlay() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultSize(width: 860, height: 620)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        // Opened from its own menu item, so it stays out of the Window menu.
        .commandsRemoved()

        // Every network request SideWave has made, for the user to review.
        Window("Data Transparency", id: "data-transparency") {
            DataTransparencyView()
                .preferredColorScheme(colorScheme)
                .background {
                    WindowBackgroundView(opacity: windowOpacity)
                    .ignoresSafeArea()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultSize(width: 580, height: 680)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        // Opens when a model download starts outside setup, and closes itself
        // shortly after the transfer finishes.
        Window("Downloads", id: "model-recovery") {
            ModelRecoveryView(reviewModel: { repoID in
                let name = repoID?.lowercased() ?? ""
                appState.requestedSettingsTab = name.contains("gemma") ? .settingsRefine
                    : name.contains("nemotron") || name.contains("diar") ? .settingsMeetings : .settingsDictation
            }, retryModel: { _ in
                guard !appState.isDictationBusy, !appState.isProcessingAgenticEdit else { return }
                if !appState.dictationCleanupEnabled { appState.dictationCleanupEnabled = true }
                else { appState.dictationFormatter.enable() }
            }, canRetry: { repoID in
                guard !appState.isDictationBusy, !appState.isProcessingAgenticEdit,
                      let selected = appState.dictationFormatter.activeBackend.huggingFaceRepoID,
                      ModelDownloadManager.resolveRepoID(selected) == repoID else { return false }
                switch appState.dictationFormatter.state {
                case .error, .disabled, .unloaded: return true
                default: return false
                }
            })
                .preferredColorScheme(colorScheme)
                .background {
                    WindowBackgroundView(opacity: windowOpacity)
                    .ignoresSafeArea()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 360)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(.suppressed)

        // Help window
        Window("Help", id: "help") {
            HelpView()
                .environment(appState)
                .preferredColorScheme(colorScheme)
                .background {
                    WindowBackgroundView(opacity: windowOpacity)
                    .ignoresSafeArea()
                }
                .overlay(alignment: .bottomTrailing) { Self.debugDimensionsOverlay() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultSize(width: 808, height: 623)
        .defaultPosition(.center)
        // Keeps state restoration from reopening Help without the main window.
        .defaultLaunchBehavior(.suppressed)
        // Opened from its own menu item, so it stays out of the Window menu.
        .commandsRemoved()

        // Compact floating strip that replaces the main window when chosen.
        Window("SideWave Mini", id: "mini") {
            MiniDashboardView()
                .environment(appState)
                .preferredColorScheme(colorScheme)
                .background {
                    WindowBackgroundView(opacity: windowOpacity)
                    .ignoresSafeArea()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 72)
        .defaultLaunchBehavior(.suppressed)
        // Opened from its own menu item, so it stays out of the Window menu.
        .commandsRemoved()

        Window("Document", id: "specialty-preview") {
            SpecialtyPreviewView()
                .environment(appState)
                .preferredColorScheme(colorScheme)
                .background {
                    WindowBackgroundView(opacity: windowOpacity)
                    .ignoresSafeArea()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.automatic)
        .defaultSize(width: 760, height: 640)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        // Template image, so it follows the menu bar's appearance.
        MenuBarExtra {
            MenuBarView(appState: appState)
                .preferredColorScheme(colorScheme)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("SideWave")
        }
    }

    private func appearanceBinding(_ value: String) -> Binding<Bool> {
        Binding(get: { appearance == value }, set: { if $0 { appearance = value } })
    }

    /// The resolved scheme, never nil: preferredColorScheme(nil) doesn't reliably update when
    /// moving from Light or Dark back to System, so System returns the scheme that matches macOS.
    private var colorScheme: ColorScheme? {
        // Read systemAppearanceTick so SwiftUI knows this property depends on it.
        // When macOS appearance changes, the tick toggles, forcing re-evaluation.
        _ = systemAppearanceTick

        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default:
            // Read the system setting directly; NSApp.effectiveAppearance may be overridden by the
            // app.
            let systemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            return systemDark ? .dark : .light
        }
    }

    /// Makes every titled app window transparent so the frosted background shows.
    private static func applyTransparencyToAllWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows {
                guard window.styleMask.contains(.titled) else { continue }
                guard window.frame.width >= 500 else { continue }
                window.isOpaque = false
                window.backgroundColor = .clear
            }
        }
    }

    /// CFBundleShortVersionString, for the debug build tag on the dashboard and overlay.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Debug-only overlay showing the view's current width and height in the bottom-trailing
    /// corner, for sizing windows.
    @ViewBuilder
    static func debugDimensionsOverlay() -> some View {
        #if DEBUG
        if AppPaths.showsDebugLabels {
            GeometryReader { geo in
                Text("\(Int(geo.size.width)) x \(Int(geo.size.height))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }
        }
        #else
        EmptyView()
        #endif
    }

    /// CFBundleVersion. Debug builds use 9999 so they sort above any release.
    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// Force every window to re-render its entire view hierarchy.
    private static func invalidateAllWindows() {
        for window in NSApp.windows {
            window.invalidateShadow()
            if let hostingView = window.contentView {
                hostingView.needsLayout = true
                hostingView.needsDisplay = true
                func invalidateSubviews(_ view: NSView) {
                    view.needsDisplay = true
                    view.needsLayout = true
                    for sub in view.subviews {
                        invalidateSubviews(sub)
                    }
                }
                invalidateSubviews(hostingView)
            }
            window.display()
        }
    }
}

/// Opens the Downloads window whenever a real model download starts, during setup too: setup
/// describes only the speech model, and other downloads would otherwise be invisible. A
/// ViewModifier so Observation tracks `ModelDownloadActivity.shared` through its state.
private struct ModelRecoveryWindowPresenter: ViewModifier {
    let appState: AppState
    @State private var activity = ModelDownloadActivity.shared
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: activity.session?.hasRealDownload) { _, hasReal in
                guard hasReal == true else { return }
                guard activity.shouldPresentWindow else { return }
                openWindow(id: "model-recovery")
            }
    }
}
