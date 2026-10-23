import CoreSpotlight
import SwiftUI

#if os(iOS)
    import BackgroundTasks
#endif

#if os(iOS)
    /// BackgroundTaskHolder completes a background task exactly once from any context.
    final class BackgroundTaskHolder: @unchecked Sendable {
        /// The held task.
        private let task: BGTask
        /// Guards the single completion.
        private let lock = NSLock()
        /// Whether completion already happened.
        private var finished = false

        /// Wraps a task.
        init(task: BGTask) {
            self.task = task
        }

        /// Completes the task once; later calls are ignored.
        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
        }
    }
#endif

/// SkerryApp is the app entry point: one window over one open library.
@main
struct SkerryApp: App {
    /// Shared library state for the window, App Intents, and URL handling.
    @State private var model = LibraryModel.shared
    /// Appearance and editor preferences shared across the window.
    @State private var settings = AppSettings()
    /// Scene phase, used on iOS to refresh the library when returning to the foreground.
    @Environment(\.scenePhase) private var scenePhase

    #if os(iOS)
        /// Background task identifier for periodic sync.
        static let syncTaskID = "com.dcadolph.skerry.sync"

        /// Registers the background sync handler; must happen during launch.
        init() {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.syncTaskID, using: nil
            ) { task in
                Self.handleBackgroundSync(task)
            }
        }

        /// Asks the system for a future background sync window.
        static func scheduleBackgroundSync() {
            let request = BGAppRefreshTaskRequest(identifier: syncTaskID)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? BGTaskScheduler.shared.submit(request)
        }

        /// Runs one sync inside a granted background window and reschedules.
        nonisolated static func handleBackgroundSync(_ task: BGTask) {
            let holder = BackgroundTaskHolder(task: task)
            Task { @MainActor in
                Self.scheduleBackgroundSync()
                await LibraryModel.shared.backgroundSync()
                holder.finish(success: true)
            }
            task.expirationHandler = {
                holder.finish(success: false)
            }
        }
    #endif

    var body: some Scene {
        WindowGroup("Skerry") {
            ContentView(model: model)
                .environment(settings)
                .tint(settings.accent.color)
                .onAppear {
                    #if os(macOS)
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    #endif
                    #if os(iOS)
                        WatchLink.shared.activate()
                    #endif
                    settings.applyAppearance()
                    // Arm sync once the entitlement lands: it resolves after this runs, so
                    // an owner's launch sync would otherwise wait for the next launch.
                    PlusStore.shared.onEntitlementGained = { model.autoSyncIfEnabled() }
                    PlusStore.shared.start()
                    model.reopenLastLibrary()
                }
                .onOpenURL { url in
                    model.handleURL(url)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let path = SpotlightIndexer.path(from: activity) {
                        model.open(path)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // New windows and scenes need the appearance override reapplied,
                    // since it lives on windows rather than in the view tree.
                    if phase == .active { settings.applyAppearance() }
                    #if os(iOS)
                        if phase == .active {
                            model.reloadLibrary()
                            model.drainShareInbox()
                            model.autoSyncIfEnabled()
                        }
                    #endif
                    #if os(macOS)
                        if phase == .active { model.drainShareInbox() }
                    #endif
                    if phase == .background {
                        model.autoBackupIfEnabled()
                        model.lockVault()
                        #if os(iOS)
                            // Without Plus the background pass returns immediately, so do not
                            // ask iOS for a window it would spend on nothing.
                            if model.backgroundSyncEnabled, PlusStore.shared.isUnlocked(.sync) {
                                Self.scheduleBackgroundSync()
                            }
                        #endif
                    }
                }
        }
        .commands {
            #if os(macOS)
                // Mac users reach for Skerry > Settings and Command-comma before they look at a
                // toolbar, so the menu item has to exist even though the sheet lives in the window.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings...") { model.settingsVisible = true }
                        .keyboardShortcut(",")
                }
            #endif
            CommandGroup(replacing: .newItem) {
                Button("New Note") { model.createNote() }
                    .keyboardShortcut("n")
                    .disabled(model.store == nil)
                    .help(model.store == nil
                        ? "Open a library folder first so the note has somewhere to live."
                        : "Create a note in the current folder.")
                if !model.templates.isEmpty {
                    Menu("New from Template") {
                        ForEach(model.templates, id: \.path) { template in
                            Button(template.note.displayTitle ?? template.path) {
                                model.createFromTemplate(template)
                            }
                        }
                    }
                }
                Button("Open Library...") { model.libraryPickerPresented = true }
                    .keyboardShortcut("o")
                Button("Jump to Anything...") { model.paletteVisible.toggle() }
                    .keyboardShortcut("k")
                    .disabled(model.store == nil)
                    .help(model.store == nil
                        ? "Open a library folder first so there is something to jump to."
                        : "Search every note by title or path.")
            }
            CommandGroup(after: .toolbar) {
                Button(model.focusMode ? "Exit Focus Mode" : "Focus Mode") {
                    model.focusMode.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.store == nil)
                .help(model.store == nil
                    ? "Open a library folder first."
                    : "Hide everything except the text.")
            }
            #if os(macOS)
                CommandMenu("Format") {
                    Toggle("Typewriter Scrolling", isOn: Binding(
                        get: { settings.typewriterMode },
                        set: { settings.typewriterMode = $0 }
                    ))
                    Toggle("Paragraph Focus", isOn: Binding(
                        get: { settings.paragraphFocus },
                        set: { settings.paragraphFocus = $0 }
                    ))
                    Divider()
                    Button("Find in Note") {
                        NSApp.sendAction(
                            #selector(PastingTextView.skerryFind(_:)), to: nil, from: nil
                        )
                    }
                    .keyboardShortcut("f", modifiers: [.command])
                    Button("Find and Replace in Note") {
                        NSApp.sendAction(
                            #selector(PastingTextView.skerryFindReplace(_:)), to: nil, from: nil
                        )
                    }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    Button("Highlight") {
                        NSApp.sendAction(
                            #selector(PastingTextView.skerryToggleHighlight(_:)), to: nil, from: nil
                        )
                    }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    Button("Fold or Unfold Section") {
                        NSApp.sendAction(
                            #selector(PastingTextView.skerryToggleFold(_:)), to: nil, from: nil
                        )
                    }
                    .keyboardShortcut(".", modifiers: [.command, .option])
                    Divider()
                    Button("Insert Table") {
                        NSApp.sendAction(
                            #selector(PastingTextView.skerryInsertTable(_:)), to: nil, from: nil
                        )
                    }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    Button("Format Table") {
                        NSApp.sendAction(
                            #selector(PastingTextView.skerryFormatTable(_:)), to: nil, from: nil
                        )
                    }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    Button("Insert Footnote") {
                        NSApp.sendAction(
                            #selector(PastingTextView.skerryInsertFootnote(_:)), to: nil, from: nil
                        )
                    }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                }
            #endif
        }
        #if os(macOS)
            MenuBarExtra("Skerry", systemImage: "note.text") {
                MenuBarCaptureView(model: model)
            }
            .menuBarExtraStyle(.window)
        #endif
    }
}
