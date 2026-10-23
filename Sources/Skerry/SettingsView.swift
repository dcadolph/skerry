import SkerryKit
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// SettingsView configures appearance, the editor, backup, and encryption.
struct SettingsView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Appearance and editor preferences.
    @Environment(AppSettings.self) private var settings
    /// Dismisses the settings sheet.
    @Environment(\.dismiss) private var dismiss
    /// Whether the backup-destination folder picker is showing.
    @State private var choosingDestination = false
    /// Whether the set-passphrase prompt is showing.
    @State private var settingPassphrase = false
    /// Passphrase being entered.
    @State private var passphrase = ""
    /// Fires the confirmation and haptic once a passphrase saves.
    @State private var passphraseSaved = false
    /// Whether the entered passphrase was too short, re-prompting without leaving settings.
    @State private var passphraseTooShort = false
    /// Whether the manual passphrase or recovery unlock sheet is showing.
    @State private var showUnlock = false
    /// Whether the decoy passphrase prompt is showing.
    @State private var settingDecoy = false
    /// Decoy passphrase being entered.
    @State private var decoyPassphrase = ""
    /// Whether the import file picker is showing.
    @State private var importing = false
    /// Count from the last import, held to drive the confirmation; nil when dismissed.
    @State private var importedCount: Int?
    /// WebDAV server URL being entered.
    @State private var webDAVURL = ""
    /// WebDAV user name being entered.
    @State private var webDAVUser = ""
    /// WebDAV password being entered.
    @State private var webDAVPassword = ""
    /// S3 endpoint URL being entered.
    @State private var s3Endpoint = ""
    /// S3 region being entered.
    @State private var s3Region = ""
    /// S3 bucket being entered.
    @State private var s3Bucket = ""
    /// S3 access key id being entered.
    @State private var s3AccessKey = ""
    /// S3 secret access key being entered.
    @State private var s3Secret = ""

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    accentGrid
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Choose light or dark and an accent color.")
                }

                Section {
                    Picker(selection: $settings.textSize) {
                        ForEach(EditorTextSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    } label: {
                        Label("Text Size", systemImage: "textformat.size")
                    }
                    Toggle(isOn: $settings.typewriterMode) {
                        Label("Typewriter Scrolling", systemImage: "text.insert")
                    }
                    Toggle(isOn: $settings.paragraphFocus) {
                        Label("Paragraph Focus", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Toggle(isOn: $settings.usesTextKit2) {
                        Label("New Editor", systemImage: "wand.and.sparkles")
                    }
                    themeRow
                } header: {
                    Text("Editor")
                } footer: {
                    Text("Typewriter scrolling keeps the line you are typing centered. Paragraph "
                        + "focus dims everything except the paragraph you are editing. The new "
                        + "editor runs on Apple's next-generation text engine; your notes are "
                        + "identical either way, so switch back any time.")
                }

                backupSection
                syncSection
                if !model.encryptedSnapshots.isEmpty { encryptedSnapshotsSection }
                if !model.backupSnapshots.isEmpty { snapshotsSection }
                webDAVSection
                if !model.webDAVSnapshots.isEmpty { webDAVSnapshotsSection }
                s3Section
                if !model.s3Snapshots.isEmpty { s3SnapshotsSection }
                encryptionSection
                importSection

                Section {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Storage", value: storageName)
                    Button {
                        dismiss()
                        model.libraryPickerPresented = true
                    } label: {
                        Label("Change Notes Folder", systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        dismiss()
                        model.onboardingVisible = true
                    } label: {
                        Label("Show Welcome Tour", systemImage: "sparkles.rectangle.stack")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Your notes are plain Markdown files in a folder you control, in an open "
                        + "format any app can read. Skerry adds no lock-in.")
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Done") { dismiss() }
            }
            .onAppear {
                guard model.encryptionSetupRequested else { return }
                model.encryptionSetupRequested = false
                // Let the settings sheet settle before raising the passphrase alert, or iOS
                // drops an alert requested mid-presentation.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    settingPassphrase = true
                }
            }
            .fileImporter(
                isPresented: $choosingDestination, allowedContentTypes: [.folder]
            ) { result in
                if case .success(let url) = result { model.chooseBackupDestination(url) }
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: Self.importContentTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { importedCount = model.importNotes(from: urls) }
            }
            .alert("Import Complete", isPresented: Binding(
                get: { importedCount != nil }, set: { if !$0 { importedCount = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importSummary)
            }
            .alert("Encryption Passphrase", isPresented: $settingPassphrase) {
                SecureField("Passphrase", text: $passphrase)
                Button("Save") {
                    // Validate length here rather than in the model: the model's failure path
                    // sets the global error, whose alert fights the settings sheet and dismisses
                    // it, dumping the user out of setup. Keep them in the flow with a local retry.
                    if passphrase.trimmingCharacters(in: .whitespaces).count < 8 {
                        passphraseTooShort = true
                        return
                    }
                    // A fresh vault surfaces a recovery code, which is its own confirmation, so
                    // the plain "Encryption Ready" note only fires when nothing else will show.
                    if model.setEncryptionPassphrase(passphrase),
                        model.pendingRecoveryCode == nil {
                        passphraseSaved = true
                    }
                }
                Button("Cancel", role: .cancel) { passphrase = "" }
            } message: {
                Text("Choose a passphrase of at least eight characters. Store it somewhere safe.")
            }
            .alert("Passphrase Too Short", isPresented: $passphraseTooShort) {
                Button("Try Again") {
                    // Reopen the prompt after this alert clears; the entered text is kept so the
                    // user can just add characters.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        settingPassphrase = true
                    }
                }
                Button("Cancel", role: .cancel) { passphrase = "" }
            } message: {
                Text("Use at least eight characters and try again.")
            }
            .alert("Encryption Ready", isPresented: $passphraseSaved) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your passphrase is saved in the Keychain behind Face ID. Encrypt any note "
                    + "from its menu and its file becomes unreadable ciphertext everywhere it "
                    + "travels, in backups and in the cloud.")
            }
            .sensoryFeedback(trigger: passphraseSaved) { _, saved in saved ? .success : nil }
            .sheet(isPresented: Binding(
                get: { model.pendingRecoveryCode != nil },
                set: { if !$0 { model.pendingRecoveryCode = nil } }
            )) {
                if let code = model.pendingRecoveryCode { RecoveryCodeView(code: code) }
            }
            .sheet(isPresented: $showUnlock) {
                UnlockView(model: model)
            }
        }
        #if os(macOS)
            // Bound the sheet so its Form scrolls inside a window that fits the screen. Without
            // this the tall settings list overflowed the display and pushed the Done button off
            // the top edge, leaving no way to dismiss it.
            // maxWidth matters as much as minWidth: without it a single wide row stretches the
            // sheet past the window and every section footer gets clipped instead of wrapping.
            .frame(
                minWidth: 520, idealWidth: 560, maxWidth: 640,
                minHeight: 460, idealHeight: 620, maxHeight: 720
            )
        #endif
    }

    /// Swatch grid of accent colors; Plus colors lock until preview is on.
    private var accentGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 14)], spacing: 14) {
            ForEach(AccentTheme.all) { theme in
                let unlocked = settings.isUnlocked(theme)
                let selected = settings.accent.id == theme.id
                Button {
                    if unlocked { settings.accent = theme }
                } label: {
                    Circle()
                        .fill(theme.color)
                        .frame(width: 34, height: 34)
                        .opacity(unlocked ? 1 : 0.4)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark").font(.subheadline.bold())
                                    .foregroundStyle(.white)
                            } else if theme.plus && !unlocked {
                                Image(systemName: "lock.fill").font(.caption2)
                                    .foregroundStyle(.white)
                            } else if theme.plus {
                                Image(systemName: "sparkle").font(.caption2)
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        .overlay {
                            Circle().strokeBorder(
                                Color.primary.opacity(selected ? 0.85 : 0), lineWidth: 2
                            )
                            .frame(width: 42, height: 42)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.name + (theme.plus ? ", Plus" : ""))
            }
        }
        .padding(.vertical, 6)
    }

    /// Swatch row of editor themes; Plus themes lock until preview is on.
    private var themeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(EditorTheme.all) { theme in
                    let unlocked = settings.isUnlocked(plus: theme.plus)
                    let selected = settings.editorTheme.id == theme.id
                    Button {
                        if unlocked { settings.editorTheme = theme }
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.background.map { Color(hex: $0) }
                                        ?? Color.gray.opacity(0.2))
                                Text("Aa")
                                    .font(.callout.bold())
                                    .foregroundStyle(
                                        theme.text.map { Color(hex: $0) } ?? Color.primary
                                    )
                                if theme.plus, !unlocked {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(
                                            maxWidth: .infinity, maxHeight: .infinity,
                                            alignment: .topTrailing
                                        )
                                        .padding(3)
                                }
                            }
                            .frame(width: 58, height: 40)
                            .opacity(unlocked ? 1 : 0.55)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        Color.accentColor.opacity(selected ? 0.9 : 0),
                                        lineWidth: 2
                                    )
                            }
                            Text(theme.name)
                                .font(.caption2)
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.name + (theme.plus ? ", Plus" : ""))
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Whether multi-device sync may be used.
    private var syncUnlocked: Bool { PlusStore.shared.isUnlocked(.sync) }

    /// Whether WebDAV and S3 destinations may be used.
    private var remoteBackupUnlocked: Bool { PlusStore.shared.isUnlocked(.remoteBackup) }

    /// Why the backup actions are unavailable, or nil when they are ready. Shown on hover so a
    /// dimmed control always says what is holding it back.
    private var backupBlockedReason: String? {
        if !model.isEncryptionConfigured {
            return "Set an encryption passphrase first. Skerry only writes encrypted backups, so "
                + "nothing leaves your device in the clear."
        }
        if !model.hasBackupDestination { return "Choose a backup folder first." }
        return nil
    }

    /// Why saving a remote destination is unavailable, or nil when it is ready.
    /// - Parameter ready: Whether every field for the destination has been filled in.
    private func remoteSaveBlockedReason(ready: Bool) -> String? {
        if !remoteBackupUnlocked {
            return "Backups to your own WebDAV or S3 storage are part of Skerry Plus."
        }
        if !ready { return "Fill in every field first." }
        return nil
    }

    /// Why the WebDAV server cannot be saved, or nil when it is ready.
    private var webDAVSaveBlockedReason: String? {
        remoteSaveBlockedReason(
            ready: !webDAVURL.isEmpty && !webDAVUser.isEmpty && !webDAVPassword.isEmpty
        )
    }

    /// Why the S3 bucket cannot be saved, or nil when it is ready.
    private var s3SaveBlockedReason: String? {
        remoteSaveBlockedReason(
            ready: !s3Endpoint.isEmpty && !s3Bucket.isEmpty && !s3AccessKey.isEmpty
                && !s3Secret.isEmpty
        )
    }

    /// Warns that syncing several devices through an iCloud Drive folder is best-effort.
    ///
    /// Sync keeps devices from colliding with a lock that depends on an atomic create. iCloud
    /// Drive delivers changes eventually rather than immediately, so two devices can both find
    /// the lock absent and reconcile at once. WebDAV and S3 answer a conditional write straight
    /// from the server, which settles it. Backups to the same folder are unaffected.
    private var cloudFolderCaution: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Best for one device")
                    .font(.callout)
                Text("This folder is in iCloud Drive, which delivers changes eventually. Two "
                    + "devices syncing at the same moment through it can collide. For several "
                    + "devices, sync through WebDAV or S3 and keep this folder for backups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Backup destination, auto-backup toggle, and a manual backup action.
    private var backupSection: some View {
        Section {
            Button {
                choosingDestination = true
            } label: {
                HStack {
                    Label("Backup Folder", systemImage: "externaldrive")
                    Spacer()
                    Text(model.backupDestinationName ?? "Not Set")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Toggle(
                isOn: Binding(
                    get: { model.autoBackupEnabled },
                    set: { model.autoBackupEnabled = $0 }
                )
            ) {
                Label("Back Up Automatically", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(backupBlockedReason != nil)
            .help(backupBlockedReason ?? "Back up when Skerry leaves the foreground.")
            Button {
                model.backUpNow()
            } label: {
                Label("Back Up Now", systemImage: "arrow.up.doc")
            }
            .disabled(backupBlockedReason != nil)
            .help(backupBlockedReason ?? "Write a new encrypted snapshot now.")
        } header: {
            Text("Backup")
        } footer: {
            if model.isEncryptionConfigured {
                Text("Backups are sealed with your passphrase, so the copy that leaves your "
                    + "device is unreadable ciphertext even for notes you did not encrypt. Point "
                    + "this at an iCloud Drive folder or a NAS share mounted in "
                    + "\(Self.mountingApp); the system holds any server login, so Skerry never "
                    + "sees it. The newest \(10) snapshots are kept.")
            } else {
                Text("Backups are always encrypted. Set an encryption passphrase above to turn "
                    + "them on, then point this at an iCloud Drive folder or a NAS share "
                    + "mounted in \(Self.mountingApp); the system holds any server login, so "
                    + "Skerry never sees it. The newest \(10) snapshots are kept.")
            }
        }
    }

    /// Multi-device sync target, manual sync, and last status.
    private var syncSection: some View {
        Section {
            Picker(selection: Binding(
                get: { model.syncMode },
                set: { model.syncMode = $0 }
            )) {
                Text("Off").tag(LibraryModel.SyncMode.off)
                if model.hasBackupDestination {
                    Text("Backup Folder").tag(LibraryModel.SyncMode.folder)
                }
                if model.hasWebDAVDestination {
                    Text("WebDAV").tag(LibraryModel.SyncMode.webdav)
                }
                if model.hasS3Destination {
                    Text("S3 Bucket").tag(LibraryModel.SyncMode.s3)
                }
            } label: {
                Label("Sync Through", systemImage: "arrow.triangle.2.circlepath.circle")
            }
            .disabled(!syncUnlocked)
            .help(syncUnlocked
                ? "Choose the storage your devices sync through."
                : "Multi-device sync is part of Skerry Plus.")
            if model.syncMode == .folder, model.backupDestinationIsCloudSynced {
                cloudFolderCaution
            }
            if model.syncMode != .off {
                Button {
                    model.syncNow()
                } label: {
                    Label(
                        model.syncing ? "Syncing..." : "Sync Now",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(model.syncing || !syncUnlocked)
                .help(syncUnlocked
                    ? "Run one sync pass now."
                    : "Multi-device sync is part of Skerry Plus.")
                #if os(iOS)
                    Toggle(isOn: Binding(
                        get: { model.backgroundSyncEnabled },
                        set: { model.backgroundSyncEnabled = $0 }
                    )) {
                        Label("Sync in Background", systemImage: "arrow.trianglehead.2.clockwise")
                    }
                    .disabled(!syncUnlocked)
                    .help(syncUnlocked
                        ? "Let iOS sync while Skerry is closed."
                        : "Multi-device sync is part of Skerry Plus.")
                #endif
            }
            if let status = model.syncStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Sync your notes between devices through storage you own. WebDAV and S3 "
                + "hold up best across several devices, because the server itself settles "
                + "which one writes first. A backup folder works too and is at its best on a "
                + "local disk or a mounted share. Everything is sealed with your vault key "
                + "before upload, edits to different paragraphs merge when they sync, and "
                + "genuine overlaps keep both versions. Background sync keeps the vault key "
                + "in the keychain so the phone can sync while the app is closed; leave it "
                + "off for the strictest posture.")
        }
    }

    /// List of plaintext snapshots with a restore action each.
    private var snapshotsSection: some View {
        Section("Snapshots") {
            ForEach(model.backupSnapshots, id: \.name) { snapshot in
                HStack {
                    Text(snapshot.date, format: .dateTime.month().day().hour().minute())
                    Spacer()
                    Button("Restore") { model.restoreBackup(snapshot) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// Encrypted snapshots; restoring one decrypts it with the vault passphrase.
    private var encryptedSnapshotsSection: some View {
        Section("Encrypted Snapshots") {
            ForEach(model.encryptedSnapshots, id: \.name) { snapshot in
                HStack {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tint)
                    Text(snapshot.date, format: .dateTime.month().day().hour().minute())
                    Spacer()
                    Button("Restore") { model.restoreEncrypted(snapshot) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// WebDAV destination setup, or its status and controls once configured.
    private var webDAVSection: some View {
        Section {
            if model.hasWebDAVDestination {
                LabeledContent("Server", value: model.webDAVHost ?? "Configured")
                Button {
                    model.testWebDAVConnection()
                } label: {
                    Label("Test Connection", systemImage: "dot.radiowaves.up.forward")
                }
                Button(role: .destructive) {
                    model.removeWebDAVDestination()
                } label: {
                    Label("Remove WebDAV", systemImage: "xmark.circle")
                }
            } else {
                TextField("Server URL", text: $webDAVURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                TextField("User name", text: $webDAVUser)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                SecureField("Password", text: $webDAVPassword)
                Button {
                    if model.setWebDAVDestination(
                        urlString: webDAVURL, username: webDAVUser, password: webDAVPassword
                    ) {
                        webDAVURL = ""
                        webDAVUser = ""
                        webDAVPassword = ""
                    }
                } label: {
                    Label("Save WebDAV Server", systemImage: "externaldrive.badge.checkmark")
                }
                .disabled(webDAVSaveBlockedReason != nil)
                .help(webDAVSaveBlockedReason ?? "Save this server as your backup destination.")
            }
            if let status = model.webDAVStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("WebDAV (iDrive, NAS, Nextcloud)")
        } footer: {
            Text("Back up straight to a WebDAV server. These backups are always encrypted with "
                + "your passphrase, so the server only ever holds ciphertext. Use the collection "
                + "URL, such as https://host/remote.php/dav/files/you/skerry/. The URL, user "
                + "name, and password are stored only in your device Keychain, never in a "
                + "settings file, and are never shown here again. Prefer giving Skerry no "
                + "login at all? Mount the server in \(Self.mountingApp) instead and choose "
                + "it as the backup folder above.")
        }
    }

    /// The system app that mounts network shares on this platform.
    private static var mountingApp: String {
        #if os(macOS)
            "Finder"
        #else
            "the Files app"
        #endif
    }

    /// Snapshots stored on the WebDAV server, each restorable.
    private var webDAVSnapshotsSection: some View {
        Section("WebDAV Snapshots") {
            ForEach(model.webDAVSnapshots) { snapshot in
                HStack {
                    Image(systemName: "lock.icloud").font(.caption2).foregroundStyle(.tint)
                    Text(snapshot.date, format: .dateTime.month().day().hour().minute())
                    Spacer()
                    Button("Restore") { model.restoreWebDAV(snapshot) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// S3-compatible destination setup, or its status and controls once configured.
    private var s3Section: some View {
        Section {
            if model.hasS3Destination {
                LabeledContent("Bucket", value: model.s3Bucket ?? "Configured")
                Button {
                    model.testS3Connection()
                } label: {
                    Label("Test Connection", systemImage: "dot.radiowaves.up.forward")
                }
                Button(role: .destructive) {
                    model.removeS3Destination()
                } label: {
                    Label("Remove S3", systemImage: "xmark.circle")
                }
            } else {
                plainField("Endpoint URL", text: $s3Endpoint, url: true)
                plainField("Region", text: $s3Region)
                plainField("Bucket", text: $s3Bucket)
                plainField("Access Key ID", text: $s3AccessKey)
                SecureField("Secret Access Key", text: $s3Secret)
                Button {
                    if model.setS3Destination(
                        endpoint: s3Endpoint, region: s3Region, bucket: s3Bucket,
                        accessKey: s3AccessKey, secret: s3Secret
                    ) {
                        s3Endpoint = ""
                        s3Region = ""
                        s3Bucket = ""
                        s3AccessKey = ""
                        s3Secret = ""
                    }
                } label: {
                    Label("Save S3 Bucket", systemImage: "externaldrive.badge.checkmark")
                }
                .disabled(s3SaveBlockedReason != nil)
                .help(s3SaveBlockedReason ?? "Save this bucket as your backup destination.")
            }
            if let status = model.s3Status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("S3 or B2 (Backblaze, Wasabi, iDrive e2)")
        } footer: {
            Text("Back up to any S3-compatible bucket. Always encrypted, so the bucket only holds "
                + "ciphertext. Endpoint like https://s3.us-west-002.backblazeb2.com with the "
                + "matching region. The endpoint, bucket, and both keys are stored only in "
                + "your device Keychain, never in a settings file, and are never shown here "
                + "again.")
        }
    }

    /// Snapshots stored in the S3 bucket, each restorable.
    private var s3SnapshotsSection: some View {
        Section("Cloud Snapshots") {
            ForEach(model.s3Snapshots) { snapshot in
                HStack {
                    Image(systemName: "lock.icloud").font(.caption2).foregroundStyle(.tint)
                    Text(snapshot.date, format: .dateTime.month().day().hour().minute())
                    Spacer()
                    Button("Restore") { model.restoreS3(snapshot) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// A no-autocapitalize, no-autocorrect text field, optionally a URL keyboard, for
    /// credentials and endpoints.
    private func plainField(_ title: String, text: Binding<String>, url: Bool = false) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(url ? .URL : .default)
            #endif
    }

    /// Content types the import picker accepts: folders, plain text, Markdown, text
    /// bundles, Evernote exports, and Day One JSON.
    private static var importContentTypes: [UTType] {
        var types: [UTType] = [.folder, .plainText, .json, .xml]
        for ext in ["md", "markdown", "textbundle", "enex"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// Sentence summarizing the last import for the confirmation alert.
    private var importSummary: String {
        switch importedCount ?? 0 {
        case 0: return "No Markdown notes were found to import."
        case 1: return "Imported 1 note into your library."
        case let count: return "Imported \(count) notes into your library."
        }
    }

    /// Import from other note apps into the selected folder.
    private var importSection: some View {
        Section {
            Button {
                importing = true
            } label: {
                Label("Import Notes…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.store == nil)
        } header: {
            Text("Import")
        } footer: {
            Text("Bring in Markdown from Bear, Obsidian, or Apple Notes, an Evernote .enex "
                + "export with its attachments, or a Day One Journal.json. Inline #tags "
                + "become tags and the first heading becomes the title. Notes land in the "
                + "selected folder.")
        }
    }

    /// Passphrase setup, the gate for per-note encryption.
    private var encryptionSection: some View {
        Section {
            if model.canUnlockManually {
                Button {
                    showUnlock = true
                } label: {
                    Label("Unlock Vault", systemImage: "lock.open")
                }
            }
            Button {
                passphrase = ""
                settingPassphrase = true
            } label: {
                Label(
                    model.isEncryptionConfigured
                        ? "Change Encryption Passphrase" : "Set Encryption Passphrase",
                    systemImage: "lock.shield"
                )
            }
            if model.isEncryptionConfigured {
                Picker(selection: Binding(
                    get: { model.autoLockMinutes }, set: { model.autoLockMinutes = $0 }
                )) {
                    Text("Off").tag(0)
                    Text("After 1 minute").tag(1)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                } label: {
                    Label("Auto-Lock", systemImage: "lock.rotation")
                }
                Picker(selection: Binding(
                    get: { model.sealingCipher }, set: { model.sealingCipher = $0 }
                )) {
                    ForEach(NoteCrypto.Cipher.allCases, id: \.self) { cipher in
                        Text(cipher.label).tag(cipher)
                    }
                } label: {
                    Label("Cipher", systemImage: "function")
                }
                Toggle(isOn: Binding(
                    get: { model.vaultLibraryMode },
                    set: { enabled in
                        model.vaultLibraryMode = enabled
                        if enabled { model.applyVaultLibraryModeNow() }
                    }
                )) {
                    Label("Encrypt Every Note", systemImage: "lock.square.stack")
                }
                if !model.isDecoySession, model.vaultIsUpgraded {
                    if model.hasDecoy {
                        Button(role: .destructive) {
                            model.removeDecoy()
                        } label: {
                            Label("Remove Decoy Library", systemImage: "theatermasks")
                        }
                    } else {
                        Button {
                            decoyPassphrase = ""
                            settingDecoy = true
                        } label: {
                            Label("Set Up Decoy Library...", systemImage: "theatermasks")
                        }
                    }
                    Picker(selection: Binding(
                        get: { model.wipeAfterFailures },
                        set: { model.wipeAfterFailures = $0 }
                    )) {
                        Text("Off").tag(0)
                        Text("After 5 failures").tag(5)
                        Text("After 10 failures").tag(10)
                    } label: {
                        Label("Erase Key After", systemImage: "exclamationmark.shield")
                    }
                }
                if model.vaultIsUpgraded {
                    Label("Master-key encryption on", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        model.upgradeEncryption()
                    } label: {
                        Label("Upgrade Encryption", systemImage: "seal")
                    }
                }
            }
        } header: {
            Text("Encryption")
        } footer: {
            Text("Set a passphrase, then encrypt any note from its menu, or turn on Encrypt "
                + "Every Note to seal the whole library. The decoy is a second, innocuous "
                + "library that opens when its own passphrase is typed at the unlock prompt. "
                + "Erase Key After destroys this device's vault key after repeated failed "
                + "unlocks; with it gone, encrypted notes here are unrecoverable even with "
                + "the recovery code. Save the recovery code shown at setup: lose it and the "
                + "passphrase both and nothing can bring your notes back.")
        }
        .alert("Decoy Passphrase", isPresented: $settingDecoy) {
            SecureField("Decoy passphrase", text: $decoyPassphrase)
            Button("Create") { model.setUpDecoy(passphrase: decoyPassphrase) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Typing this passphrase at the unlock prompt opens a separate, harmless "
                + "library instead of your real one. Choose something you can produce "
                + "under pressure.")
        }
    }

    /// App version and build from the bundle.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Name of the open library folder, for the About section.
    private var storageName: String {
        model.store?.root.lastPathComponent ?? "Not open"
    }
}

/// RecoveryCodeView shows the one-time recovery code produced by an encryption upgrade.
struct RecoveryCodeView: View {
    /// The recovery code to display.
    let code: String
    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss
    /// Whether the copy button just copied, so it can flash a confirmation.
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)
                Text("Recovery Code")
                    .font(.title2.bold())
                Text("Keep this somewhere safe. It can unlock your notes if you ever forget your "
                    + "passphrase, and it is shown only once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(code)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 12) {
                    Button {
                        copyCode()
                    } label: {
                        Label(
                            copied ? "Copied" : "Copy",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    ShareLink(item: code) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Spacer()
            }
            .padding(24)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button("Done") { dismiss() } }
        }
        #if os(macOS)
            .frame(minWidth: 360, minHeight: 340)
        #endif
    }

    /// Copies the code to the clipboard and flashes a confirmation on the button.
    private func copyCode() {
        #if canImport(UIKit)
            UIPasteboard.general.string = code
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        #endif
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// UnlockView takes a typed passphrase or recovery code when biometrics cannot open the vault, as
/// on a new device or after a reinstall, so an encrypted library always has a way back in.
struct UnlockView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss
    /// Passphrase being entered.
    @State private var passphrase = ""
    /// Recovery code being entered.
    @State private var recovery = ""
    /// Whether the recovery-code field is shown instead of the passphrase field.
    @State private var usingRecovery = false

    var body: some View {
        NavigationStack {
            Form {
                if usingRecovery {
                    Section {
                        TextField("Recovery code", text: $recovery)
                            .textContentType(.oneTimeCode)
                            .font(.system(.body, design: .monospaced))
                        #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        #endif
                    } header: {
                        Text("Recovery Code")
                    } footer: {
                        Text("Enter the recovery code you saved when encryption was set up, then "
                            + "choose a new passphrase in Settings.")
                    }
                } else {
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                    } header: {
                        Text("Passphrase")
                    } footer: {
                        Text("Enter your encryption passphrase to unlock this library here.")
                    }
                }
                Button(usingRecovery ? "Use passphrase instead" : "Use recovery code instead") {
                    usingRecovery.toggle()
                }
            }
            .navigationTitle("Unlock Vault")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") { attempt() }
                        .disabled(usingRecovery ? recovery.isEmpty : passphrase.isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 380, minHeight: 240)
        #endif
    }

    /// Tries the entered secret and closes the sheet on success.
    private func attempt() {
        let unlocked = usingRecovery
            ? model.unlockVault(withRecovery: recovery)
            : model.unlockVault(withPassphrase: passphrase)
        if unlocked { dismiss() }
    }
}
