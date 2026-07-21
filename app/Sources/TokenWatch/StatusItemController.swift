import Foundation
@preconcurrency import AppKit
import Combine
import OSLog
import SwiftUI

/// Owns the `NSStatusItem`, renders the menu-bar label, drives the popover and
/// right-click context menu, and self-heals the status item after sleep/wake and
/// display reconfiguration.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {

    // MARK: - Layout constants

    private static let popoverWidth: CGFloat = 440

    /// Fixed-height buckets for the popover, plus a per-model-window allowance.
    static func popoverHeight(forVisibleSnapshotCount count: Int, modelWindowCount: Int = 0) -> CGFloat {
        let base: CGFloat
        switch count {
        case ..<1: base = 208
        case 1: base = 208
        case 2: base = 348
        case 3: base = 488
        default: base = 628
        }
        let models = count == 0 ? 0 : modelWindowCount
        return base + CGFloat(models) * 40
    }

    /// The status-item length for a rendered content width: width + 12, floored at 32.
    static func statusItemLength(forContentWidth width: CGFloat) -> CGFloat {
        max(32, width + 12)
    }

    // MARK: - Dependencies

    private let store: UsageStore
    private let openSettings: @MainActor () -> Void
    private let userDefaults: UserDefaults
    private let logger = Logger(subsystem: "com.tokenwatch.app", category: "StatusItem")

    // MARK: - Status item / popover

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hostingController: NSHostingController<MenuContentView>?

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private var repairDebouncer: StatusItemRepairDebouncer!
    private var wakeFollowupTask: Task<Void, Never>?

    private var globalMouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    private var rebuildCount = 0
    private var creationTimestamp = Date()
    private var isRenderingFallback = false

    // MARK: - Init

    init(store: UsageStore, openSettings: @escaping @MainActor () -> Void) {
        self.store = store
        self.openSettings = openSettings
        self.userDefaults = .standard
        super.init()

        repairDebouncer = StatusItemRepairDebouncer { [weak self] reason in
            self?.installStatusItem(reason: reason)
        }

        configurePopover()
        installStatusItem(reason: .launch)
        subscribeToUpdates()
        registerRepairTriggers()
    }

    deinit {
        // The controller lives for the app's lifetime; observers, monitors,
        // and Combine subscriptions die with the process. Only the pending
        // wake follow-up task needs explicit cancellation (Task is Sendable
        // and safe to touch from a nonisolated deinit); the repair debouncer
        // cancels its own pending task in its deinit.
        wakeFollowupTask?.cancel()
    }

    // MARK: - Popover configuration

    private func configurePopover() {
        popover.behavior = .semitransient
        popover.animates = false
        popover.delegate = self

        let height = currentPopoverHeight()
        let size = NSSize(width: Self.popoverWidth, height: height)
        popover.contentSize = size

        let hosting = NSHostingController(rootView: makeMenuContent(height: height))
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(origin: .zero, size: size)
        hosting.preferredContentSize = size
        popover.contentViewController = hosting
        hostingController = hosting
    }

    private func makeMenuContent(height: CGFloat) -> MenuContentView {
        MenuContentView(
            store: store,
            openSettings: { [openSettings] in
                MainActor.assumeIsolated { openSettings() }
            },
            popoverHeight: height
        )
    }

    /// Height for the current visible snapshots, counting Gemini's model windows
    /// only when the "showGeminiOtherModels" default is set.
    private func currentPopoverHeight() -> CGFloat {
        let snapshots = store.visibleSnapshots
        let modelCount = snapshots.reduce(0) { $0 + modelWindowCount(for: $1) }
        return Self.popoverHeight(forVisibleSnapshotCount: snapshots.count, modelWindowCount: modelCount)
    }

    private func modelWindowCount(for snapshot: ProviderSnapshot) -> Int {
        if snapshot.provider == .gemini, !userDefaults.bool(forKey: "showGeminiOtherModels") {
            return 0
        }
        return snapshot.modelWindows.count
    }

    /// Re-layout the popover, but only when its content size actually changed.
    private func layoutPopover() {
        let height = currentPopoverHeight()
        let size = NSSize(width: Self.popoverWidth, height: height)
        guard size != popover.contentSize else { return }

        popover.contentSize = size
        if let hosting = hostingController {
            hosting.view.frame = NSRect(origin: .zero, size: size)
            hosting.preferredContentSize = size
            hosting.rootView = makeMenuContent(height: height)
        }
    }

    // MARK: - Status item lifecycle

    /// Creates (or rebuilds) the status item and configures its button and label.
    private func installStatusItem(reason: StatusItemRepairReason) {
        let isRebuild = statusItem != nil

        if isRebuild {
            rebuildCount += 1
            let priorAge = Date().timeIntervalSince(creationTimestamp)
            logger.info("Rebuilding status item (reason: \(reason.rawValue, privacy: .public), rebuild #\(self.rebuildCount), prior age: \(priorAge, privacy: .public)s)")

            popover.performClose(nil)
            stopDismissMonitoring()

            NSStatusBar.system.removeStatusItem(statusItem)
            logger.info("Removed status item (reason: \(reason.rawValue, privacy: .public))")
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        creationTimestamp = Date()
        logger.info("Created status item (reason: \(reason.rawValue, privacy: .public))")

        configureButton()
        renderLabel()
        logPostRebuildState(reason: reason)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleButtonAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func logPostRebuildState(reason: StatusItemRepairReason) {
        let hasButton = statusItem.button != nil
        let hasWindow = statusItem.button?.window != nil
        let length = Double(statusItem.length)
        let fallback = isRenderingFallback
        logger.info("Post-rebuild state (reason: \(reason.rawValue, privacy: .public)): button=\(hasButton ? "yes" : "no", privacy: .public), window=\(hasWindow ? "yes" : "no", privacy: .public), length=\(length, privacy: .public), fallback=\(fallback ? "yes" : "no", privacy: .public)")
    }

    // MARK: - Label rendering

    private func renderLabel() {
        guard let button = statusItem.button else { return }

        let view = StatusItemLabelView(
            claudeUsage: providerUsage(for: .claude, snapshot: store.claude),
            codexUsage: providerUsage(for: .codex, snapshot: store.codex),
            geminiUsage: providerUsage(for: .gemini, snapshot: filteredGeminiSnapshot),
            zaiUsage: providerUsage(for: .zai, snapshot: store.zai)
        )

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        if let image = renderer.nsImage {
            image.isTemplate = false
            button.image = image
            button.title = ""
            statusItem.length = Self.statusItemLength(forContentWidth: image.size.width)

            if isRenderingFallback {
                isRenderingFallback = false
                logger.info("Status item label rendering recovered")
            }
        } else {
            button.image = nil
            button.title = StatusItemLabelView.defaultFallbackText
            statusItem.length = NSStatusItem.variableLength

            if !isRenderingFallback {
                isRenderingFallback = true
                logger.error("Status item label rendering failed; using fallback text")
            }
        }
    }

    /// Compact per-provider usage, or nil unless the provider is popover-visible
    /// and should show in the menu bar for the given snapshot.
    private func providerUsage(for provider: ProviderKind, snapshot: ProviderSnapshot) -> StatusItemProviderUsage? {
        guard store.agentStatus(for: provider).availability.showsInPopover else { return nil }
        guard MenuBarVisibility.showsInMenuBar(snapshot) else { return nil }
        let name = ProviderDisplayName.displayName(for: provider)
        return StatusItemFormatter.content(name: name, snapshot: snapshot)
    }

    /// Gemini's snapshot with its model windows emptied unless the
    /// "showGeminiOtherModels" default is set.
    private var filteredGeminiSnapshot: ProviderSnapshot {
        var snapshot = store.gemini
        if !userDefaults.bool(forKey: "showGeminiOtherModels") {
            snapshot.modelWindows = []
        }
        return snapshot
    }

    // MARK: - Updates

    private func subscribeToUpdates() {
        store.$claude
            .combineLatest(store.$codex, store.$gemini, store.$zai)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLabelAndLayout() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLabelAndLayout() }
            }
            .store(in: &cancellables)
    }

    private func refreshLabelAndLayout() {
        renderLabel()
        layoutPopover()
    }

    // MARK: - Click handling

    @objc private func handleButtonAction(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        layoutPopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startDismissMonitoring()
    }

    private func startDismissMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func stopDismissMonitoring() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
    }

    // MARK: - Context menu

    private func showContextMenu() {
        if popover.isShown {
            popover.performClose(nil)
        }

        let menu = NSMenu()
        menu.delegate = self

        let options = NSMenuItem(title: "Options...", action: #selector(optionsMenuItemClicked), keyEquivalent: "")
        options.target = self
        menu.addItem(options)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Token Watch", action: #selector(quitMenuItemClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    @objc private func optionsMenuItemClicked() {
        openSettings()
    }

    @objc private func quitMenuItemClicked() {
        NSApp.terminate(nil)
    }

    // MARK: - Self-repair triggers

    private func registerRepairTriggers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repairDebouncer.schedule(reason: .wake)
                self.scheduleWakeFollowup()
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelWakeFollowup()
                self.repairDebouncer.schedule(reason: .displayChange)
            }
        }
    }

    /// One-shot rebuild ~2s after wake, replaced/cancelled by newer events.
    private func scheduleWakeFollowup() {
        wakeFollowupTask?.cancel()
        wakeFollowupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.installStatusItem(reason: .wakeFollowup)
        }
    }

    private func cancelWakeFollowup() {
        wakeFollowupTask?.cancel()
        wakeFollowupTask = nil
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        stopDismissMonitoring()
    }

    // MARK: - NSMenuDelegate

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
}
