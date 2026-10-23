import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import SkerryKit
import WidgetKit

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// SidebarItem is one selectable row in the sidebar: a smart view, folder, or tag.
enum SidebarItem: Hashable {
    /// Every non-archived note in the library.
    case all
    /// Notes with `starred: true`.
    case starred
    /// Notes with an unchecked task in the body.
    case todo
    /// Notes with `archived: true`.
    case archived
    /// Notes whose path sits under the folder, directly or in subfolders.
    case folder(String)
    /// Notes carrying the tag, compared case-insensitively.
    case tag(String)
    /// Recently deleted notes, recoverable until they are purged.
    case trash
}

/// SearchReach is how far an active search looks: only the selected folder or tag, or the
/// whole library. It resets to `.scoped` when the search clears or the selection changes, so
/// widening never leaks across a navigation.
enum SearchReach: String, CaseIterable, Identifiable, Sendable {
    /// Search only within the selected folder or tag.
    case scoped
    /// Search the whole library, ignoring the selected folder or tag.
    case all
    /// Stable identity for the scope picker.
    var id: String { rawValue }
}

/// RemoteSnapshot is an encrypted backup snapshot stored on a WebDAV server.
struct RemoteSnapshot: Identifiable, Equatable {
    /// File name of the snapshot, extension included.
    var name: String
    /// When the snapshot was taken, parsed from the name.
    var date: Date
    /// Stable identity for lists.
    var id: String { name }
}

/// InsightsSummary is a point-in-time picture of the library for the insights sheet.
/// Word and task numbers cover only what is readable, so sealed notes stay sealed.
struct InsightsSummary {
    /// All notes in the library.
    var noteCount = 0
    /// Notes sealed with encryption.
    var encryptedCount = 0
    /// Notes whose bodies were readable when the summary was built.
    var readableCount = 0
    /// Words across every readable note body.
    var wordCount = 0
    /// Unchecked tasks across readable notes.
    var openTasks = 0
    /// Checked tasks across readable notes.
    var doneTasks = 0
    /// Distinct tags in use.
    var tagCount = 0
    /// Most-used tags, biggest first, at most five.
    var topTags: [(name: String, count: Int)] = []
    /// Writing streaks built from note creation and edit days.
    var streaks = WritingStreaks.Result(activeDays: 0, current: 0, longest: 0)
    /// Creation date of the oldest note.
    var firstNoteDate: Date?
}

/// ConflictPair joins a sync conflict copy with the note it forked from.
struct ConflictPair: Identifiable, Equatable {
    /// The conflict copy that sync wrote, holding the remote version.
    var copy: StoredNote
    /// The surviving original with this device's version, nil if since deleted.
    var original: StoredNote?
    /// Stable identity for lists.
    var id: String { copy.path }
}

/// LibraryModel owns the open library: notes in memory, selection, search, and persistence.
@MainActor
@Observable
final class LibraryModel {
    /// The one model the window, App Intents, and URL handling all share.
    static let shared = LibraryModel()

    /// UserDefaults key holding the security-scoped bookmark of the last opened library.
    private static let libraryBookmarkKey = "libraryBookmark"

    /// Whether the library folder picker is showing; toggled by Open Library actions.
    var libraryPickerPresented = false
    /// Whether the command palette overlay is showing.
    var paletteVisible = false
    /// Whether the settings sheet is showing.
    var settingsVisible = false
    /// Plus feature a person just reached for without owning it; non-nil raises the paywall.
    /// Model-level so the palette, intents, and URL scheme all land on the same sheet.
    var paywallFeature: PlusFeature?
    /// Whether focus mode hides the sidebar and note list around the editor.
    var focusMode = false
    /// Pushed editor paths for stack navigation on iPhone; unused on macOS.
    var pathStack: [String] = []
    /// Locked notes the user has authenticated for in this session.
    private(set) var unlockedPaths: Set<String> = []
    /// Encryption passphrase held in a zeroizing buffer only while the vault is unlocked.
    private var vaultPassphraseSecret: ZeroizingSecret?
    /// Encryption passphrase view over the zeroizing buffer; setting nil wipes the bytes.
    private var vaultPassphrase: String? {
        get { vaultPassphraseSecret?.value }
        set {
            vaultPassphraseSecret?.wipe()
            vaultPassphraseSecret = newValue.map(ZeroizingSecret.init)
        }
    }
    /// Vault keyfile when the library has been upgraded to the master-key format, else nil.
    private var vaultKeyfile: VaultKey.Keyfile?
    /// Master key, unwrapped and held only while the vault is unlocked.
    private var vaultMasterKey: SymmetricKey?
    /// Whether the library uses the master-key format rather than passphrase-per-note.
    var vaultIsUpgraded: Bool { vaultKeyfile != nil }
    /// One-time recovery code awaiting display after a vault is created or upgraded; nil once shown.
    var pendingRecoveryCode: String?
    /// Whether the manual passphrase or recovery unlock prompt is showing.
    var unlockPromptVisible = false
    /// Whether a photo-to-note capture or image pick has been requested from a button or command.
    var scanRequested = false
    /// Whether an audio memo recording has been requested from a button or command.
    var memoRequested = false
    /// Whether a document scan has been requested from a button or command.
    var documentScanRequested = false
    /// Whether the sync conflict review sheet is showing.
    var conflictReviewVisible = false
    /// Whether the library insights sheet is showing.
    var insightsVisible = false
    /// Whether the first-run welcome tour is showing; starts true until seen once.
    var onboardingVisible = !UserDefaults.standard.bool(forKey: LibraryModel.onboardingSeenKey)
    /// Whether the tour ended on the encryption call to action, opening settings next.
    private var onboardingWantsSecurity = false
    /// Whether settings should jump straight to the passphrase prompt on appearing, set
    /// when the user chose Set Up Encryption from the tour. Settings clears it once shown.
    var encryptionSetupRequested = false
    /// UserDefaults key remembering the welcome tour was seen.
    private static let onboardingSeenKey = "hasSeenOnboarding"

    /// Ends the welcome tour from one of its buttons; the sheet's dismissal completes it.
    func requestOnboardingFinish(openingSecurity: Bool) {
        onboardingWantsSecurity = openingSecurity
        onboardingVisible = false
    }

    /// Marks the tour seen once its sheet is fully gone, then opens security settings
    /// if that was the parting choice. Runs on swipe-dismiss too.
    func completeOnboardingDismissal() {
        UserDefaults.standard.set(true, forKey: Self.onboardingSeenKey)
        guard onboardingWantsSecurity else { return }
        onboardingWantsSecurity = false
        encryptionSetupRequested = true
        // Presenting a sheet from inside another sheet's dismissal is unreliable on iOS: the
        // onboarding sheet is still tearing down on the same view, so opening settings here
        // silently does nothing and drops the user into an empty app. Hop past the dismissal
        // so the settings sheet presents cleanly.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            settingsVisible = true
        }
    }
    /// Location of the vault keyfile at the library root, synced with the notes.
    private var vaultKeyfileURL: URL? { store?.root.appendingPathComponent(".skerryvault") }
    /// UserDefaults key for the encrypt-every-note policy.
    private static let vaultModeKey = "vaultLibraryMode"
    /// Whether every note is kept encrypted, enforced whenever the vault is unlocked.
    var vaultLibraryMode: Bool = false {
        didSet { UserDefaults.standard.set(vaultLibraryMode, forKey: Self.vaultModeKey) }
    }
    /// UserDefaults key for the erase-after-failures setting.
    private static let wipeAfterKey = "wipeAfterFailures"
    /// Failed manual unlock attempts allowed before the keyfile is destroyed; 0 disables.
    var wipeAfterFailures: Int = 0 {
        didSet { UserDefaults.standard.set(wipeAfterFailures, forKey: Self.wipeAfterKey) }
    }
    /// UserDefaults key counting consecutive failed manual unlocks.
    private static let failedUnlocksKey = "failedUnlockCount"
    /// Whether the open library is the decoy, where sync, backups, and the share inbox
    /// stay untouched so nothing links back to the real library.
    private(set) var isDecoySession = false

    /// UserDefaults key for the sealing cipher choice.
    private static let sealingCipherKey = "sealingCipher"
    /// AEAD used for everything newly sealed: notes, attachments, sync objects, and key
    /// wrappings. Existing content opens regardless of what it was sealed with.
    var sealingCipher: NoteCrypto.Cipher = .aesGCM {
        didSet {
            UserDefaults.standard.set(sealingCipher.rawValue, forKey: Self.sealingCipherKey)
            VaultKey.sealingCipher = sealingCipher
        }
    }

    /// UserDefaults key for the auto-lock timeout.
    private static let autoLockKey = "autoLockMinutes"
    /// Minutes of inactivity before the unlocked vault locks itself; 0 disables it.
    var autoLockMinutes: Int = 0 {
        didSet {
            UserDefaults.standard.set(autoLockMinutes, forKey: Self.autoLockKey)
            scheduleAutoLock()
        }
    }
    /// Pending auto-lock timer, cancelled and rescheduled on activity.
    private var autoLockTask: Task<Void, Never>?
    /// Paths of encrypted notes whose in-memory body is currently decrypted plaintext.
    private(set) var decryptedPaths: Set<String> = []
    /// Whether an encryption passphrase has been set up on this device.
    var hasEncryptionPassphrase: Bool { KeychainVault.exists() }
    /// Whether the library is encrypted at all, by a device passphrase or a synced keyfile.
    /// A synced keyfile with no device passphrase is the new-device or reinstall case.
    var isEncryptionConfigured: Bool { hasEncryptionPassphrase || vaultIsUpgraded }
    /// Whether the vault is unlocked this session, by passphrase, biometrics, or recovery code.
    var vaultUnlocked: Bool { vaultPassphraseSecret != nil || vaultMasterKey != nil }
    /// In-memory search index over decrypted notes, so encrypted notes are searchable
    /// while the vault is open without their text ever reaching the on-disk index.
    private var sessionIndex: NoteIndex?
    /// Whether a manual passphrase or recovery unlock is possible: encryption is set up but the
    /// vault is not open this session.
    var canUnlockManually: Bool { isEncryptionConfigured && !vaultUnlocked }
    /// Notes currently in the library trash, most recently deleted first.
    private(set) var trashedNotes: [TrashedNote] = []
    /// How long a trashed note is recoverable before automatic purge.
    private static let trashRetention: TimeInterval = 30 * 24 * 3600

    /// UserDefaults key for the backup destination bookmark.
    private static let backupBookmarkKey = "backupBookmark"
    /// UserDefaults key for whether backups run automatically.
    private static let autoBackupKey = "autoBackupEnabled"
    /// UserDefaults key for the note-list sort order.
    private static let noteSortKey = "noteSort"
    /// How many snapshots to keep before pruning the oldest.
    private static let backupsToKeep = 10
    /// Resolved backup destination held with security-scoped access, if configured.
    private var backupDestination: URL?
    /// Plaintext snapshots present in the backup destination, most recent first.
    private(set) var backupSnapshots: [LibraryBackup.Snapshot] = []
    /// Encrypted snapshots present in the backup destination, most recent first.
    private(set) var encryptedSnapshots: [EncryptedBackup.Snapshot] = []

    /// Keychain account holding the whole WebDAV destination as one JSON item, so the
    /// server URL and user name never sit in UserDefaults where any plist reader sees them.
    private static let webDAVDestinationAccount = "webdav.destination"
    /// Legacy UserDefaults key for the WebDAV collection URL, migrated on load.
    private static let webDAVURLKey = "webDAVURL"
    /// Legacy UserDefaults key for the WebDAV user name, migrated on load.
    private static let webDAVUserKey = "webDAVUser"
    /// Legacy keychain account for the WebDAV password alone, migrated on load.
    private static let webDAVPasswordAccount = "webdav.password"
    /// Active WebDAV destination, nil when none is configured.
    private(set) var webDAVConfig: WebDAVClient.Config?
    /// Sealed snapshots on the WebDAV server, most recent first.
    private(set) var webDAVSnapshots: [RemoteSnapshot] = []
    /// Last WebDAV status line for the settings screen.
    var webDAVStatus: String?
    /// Whether a WebDAV destination is configured.
    var hasWebDAVDestination: Bool { webDAVConfig != nil }
    /// Host of the WebDAV destination, for display.
    var webDAVHost: String? { webDAVConfig?.baseURL.host() }

    /// Keychain account holding the whole S3 destination as one JSON item, endpoint,
    /// bucket, and both keys included, so nothing about the connection sits in a plist.
    private static let s3DestinationAccount = "s3.destination"
    /// Legacy UserDefaults keys for the S3 destination, migrated on load.
    private static let s3EndpointKey = "s3Endpoint"
    private static let s3RegionKey = "s3Region"
    private static let s3BucketKey = "s3Bucket"
    private static let s3AccessKeyKey = "s3AccessKey"
    /// Legacy keychain account for the S3 secret key alone, migrated on load.
    private static let s3SecretAccount = "s3.secret"
    /// Key prefix under which snapshots are stored in the bucket.
    private static let s3Prefix = "skerry/"
    /// Active S3 destination, nil when none is configured.
    private(set) var s3Config: S3Client.Config?
    /// Sealed snapshots in the S3 bucket, most recent first.
    private(set) var s3Snapshots: [RemoteSnapshot] = []
    /// Last S3 status line for the settings screen.
    var s3Status: String?
    /// Whether an S3 destination is configured.
    var hasS3Destination: Bool { s3Config != nil }
    /// Bucket name of the S3 destination, for display.
    var s3Bucket: String? { s3Config?.bucket }
    /// Whether a backup destination is configured.
    var hasBackupDestination: Bool { backupDestination != nil }
    /// Display path of the backup destination, for the settings screen.
    var backupDestinationName: String? { backupDestination?.lastPathComponent }

    /// Whether the backup folder sits in a cloud-synced container such as iCloud Drive.
    ///
    /// Sync serializes devices with an advisory lock built on an atomic create-if-absent. On a
    /// local disk or a mounted share that create is genuinely atomic. Inside an eventually
    /// consistent container two devices can both see the lock as absent and reconcile at once,
    /// which is the lost update the lock exists to prevent. Backups are unaffected, since they
    /// never race. Used to steer multi-device sync toward WebDAV or S3.
    var backupDestinationIsCloudSynced: Bool {
        guard let path = backupDestination?.path else { return false }
        return path.contains("/Mobile Documents/") || path.contains("com~apple~CloudDocs")
    }

    /// UserDefaults key for the chosen sync target.
    private static let syncModeKey = "syncMode"
    /// Where multi-device sync points: nowhere, the backup folder, WebDAV, or S3.
    enum SyncMode: String, CaseIterable {
        case off, folder, webdav, s3

        /// Menu label.
        var label: String {
            switch self {
            case .off: return "Off"
            case .folder: return "Backup Folder"
            case .webdav: return "WebDAV"
            case .s3: return "S3 Bucket"
            }
        }
    }
    /// Sync target in use; persists across launches.
    var syncMode: SyncMode = .off {
        didSet {
            UserDefaults.standard.set(syncMode.rawValue, forKey: Self.syncModeKey)
            startSyncFreshness()
        }
    }
    /// Repeating quiet pull while the app is active, so edits from other devices land
    /// within a couple of minutes instead of waiting for an app switch.
    private var freshnessLoop: Task<Void, Never>?

    /// Starts the periodic pull when sync is on and the vault key is available; any
    /// earlier loop stops first. One small sealed-manifest read when nothing changed.
    func startSyncFreshness() {
        freshnessLoop?.cancel()
        freshnessLoop = nil
        guard syncMode != .off, vaultMasterKey != nil else { return }
        guard PlusStore.shared.isUnlocked(.sync) else { return }
        freshnessLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { break }
                await self?.runSync(manual: false)
            }
        }
    }

    /// Stops the periodic pull, on lock and when sync turns off.
    func stopSyncFreshness() {
        freshnessLoop?.cancel()
        freshnessLoop = nil
    }
    /// Last sync outcome for the settings screen.
    var syncStatus: String?
    /// Whether a sync pass is running right now.
    private(set) var syncing = false
    /// Pending debounced sync scheduled after edits settle.
    private var pendingSync: Task<Void, Never>?
    /// UserDefaults key for background sync.
    private static let backgroundSyncKey = "backgroundSyncEnabled"
    /// Keychain account holding the master key while background sync is enabled.
    private static let backgroundKeyAccount = "vault.masterkey.background"
    /// Whether iOS may sync while the app is not running. Enabling keeps the master key
    /// available to the background task through the keychain, a documented tradeoff.
    var backgroundSyncEnabled = false {
        didSet {
            UserDefaults.standard.set(backgroundSyncEnabled, forKey: Self.backgroundSyncKey)
            if backgroundSyncEnabled {
                storeBackgroundKeyIfPossible()
            } else {
                KeychainVault.deleteSecret(account: Self.backgroundKeyAccount)
            }
        }
    }

    /// Saves the unlocked master key for the background task when the setting is on.
    private func storeBackgroundKeyIfPossible() {
        guard backgroundSyncEnabled, !isDecoySession, let key = vaultMasterKey else { return }
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        KeychainVault.storeSecret(encoded, account: Self.backgroundKeyAccount)
    }

    /// Runs one sync pass from a background task, using the keychain-held key so the
    /// vault itself stays locked.
    func backgroundSync() async {
        guard backgroundSyncEnabled, syncMode != .off, !isDecoySession else { return }
        guard PlusStore.shared.isUnlocked(.sync) else { return }
        if store == nil { reopenLastLibrary() }
        guard let store, let remote = syncRemote() else { return }
        let key: SymmetricKey
        if let unlocked = vaultMasterKey {
            key = unlocked
        } else if let encoded = KeychainVault.fetchSecret(account: Self.backgroundKeyAccount),
            let data = Data(base64Encoded: encoded), data.count == 32 {
            key = SymmetricKey(data: data)
        } else {
            return
        }
        let keyfileData = vaultKeyfileURL.flatMap { try? Data(contentsOf: $0) }
        lastLocalWrite = Date()
        _ = try? await SyncEngine.sync(
            library: store.root, remote: remote, key: key, keyfile: keyfileData,
            cipher: sealingCipher
        )
    }

    /// Schedules a quiet sync shortly after edits settle, while the vault is open, so
    /// changes reach other devices without waiting for an app switch.
    private func scheduleAutoSync() {
        guard syncMode != .off, vaultMasterKey != nil else { return }
        guard PlusStore.shared.isUnlocked(.sync) else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.runSync(manual: false)
        }
    }
    /// Whether the library backs up automatically when the app leaves the foreground.
    var autoBackupEnabled = false {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: Self.autoBackupKey) }
    }
    /// Order the note list uses when no search is active, persisted across launches.
    var noteSort: NoteSort = NoteSort(
        rawValue: UserDefaults.standard.string(forKey: LibraryModel.noteSortKey) ?? ""
    ) ?? .updated {
        didSet { UserDefaults.standard.set(noteSort.rawValue, forKey: Self.noteSortKey) }
    }

    /// Opens a note in the editor, pushing it on platforms that navigate by stack. A
    /// heading, when given, is held so the editor scrolls to it once the note loads.
    func open(_ path: String, heading: String? = nil) {
        pendingHeading = heading
        selectedPath = path
        pathStack = [path]
        registerActivity()
    }

    /// Clears the pending scroll target once the editor has scrolled to it.
    func clearPendingHeading() {
        pendingHeading = nil
    }

    /// Scrolls the open editor to a heading, the outline's jump. Setting the pending
    /// heading is enough: the editor scrolls to it on the next render and clears it.
    func scroll(toHeading heading: String) {
        pendingHeading = heading
    }
    /// Library URL currently held open with security-scoped access.
    private var accessedURL: URL?
    /// Store over the open library root; nil until a library is opened.
    private(set) var store: NoteStore?
    /// Search index for the open library.
    private(set) var index: NoteIndex?
    /// Version history for notes in the open library.
    private var versionStore: VersionStore?
    /// Wiki-link graph over the in-memory bodies, feeding the backlinks bar.
    private var linkGraph = LinkGraph()
    /// Extracted attachment text by note path, folded into index entries for search.
    private var attachmentExtras: [String: String] = [:]
    /// In-flight attachment text extraction, replaced when a newer pass starts.
    private var attachmentExtractionTask: Task<Void, Never>?
    /// Every note in the library, loaded eagerly; phase-1 libraries are small.
    private(set) var notes: [StoredNote] = []
    /// Message shown when opening or saving fails.
    var errorMessage: String?
    /// Selected sidebar row. Changing the container resets an in-progress search to its narrow
    /// scope, so widening to the whole library never carries over to the next selection.
    var sidebarSelection: SidebarItem = .all {
        didSet {
            if sidebarSelection != oldValue { searchReach = .scoped }
        }
    }
    /// How far the active search reaches: the selected folder or tag, or the whole library.
    var searchReach: SearchReach = .scoped
    /// Relative path of the note open in the editor.
    var selectedPath: String?
    /// Heading the editor should scroll to on the next load, set by a wiki `#heading`
    /// link and cleared once the editor has scrolled to it.
    private(set) var pendingHeading: String?
    /// Live search text; empty means no search filter.
    var searchText: String = ""
    /// Paths matching the current search, in rank order; nil means search is off.
    private(set) var searchHits: [String]?
    /// Search hit detail keyed by path: the body snippet and its matched-term ranges, so a
    /// result row can show where the query landed instead of a generic preview.
    private(set) var searchResults: [String: NoteIndex.Hit] = [:]
    /// Structural filters parsed from the search text, like @todo or #tag.
    private(set) var activeFilters: [SearchQuery.Filter] = []
    /// Pending debounced save work, one per dirty note path.
    private var pendingSaves: [String: Task<Void, Never>] = [:]
    /// Pending debounced reload triggered by external file changes.
    private var pendingReload: Task<Void, Never>?
    /// Time of the last write this app made, used to ignore its own file events.
    private var lastLocalWrite: Date = .distantPast
    /// Folder paths in the library, empty folders included, sorted.
    private(set) var folders: [String] = []
    #if os(macOS)
        /// FSEvents watcher over the open library.
        private var watcher: LibraryWatcher?
    #endif

    /// Whether a search or structural filter is currently narrowing the list.
    private var searchActive: Bool {
        searchHits != nil || !activeFilters.isEmpty
    }

    /// Whether an active search has been widened past the selected folder or tag to the whole
    /// library. Only meaningful while a search or filter is active.
    private var searchIsWidened: Bool {
        searchReach == .all && searchActive
    }

    /// The label for the narrow end of the search scope control, or nil when there is no
    /// narrower container to widen from: a search must be active and the sidebar must show a
    /// folder or a tag. Smart views already span the library, so they offer no scope choice.
    var scopedSearchLabel: String? {
        guard searchActive else { return nil }
        switch sidebarSelection {
        case .folder(let folder):
            return folder.components(separatedBy: "/").last ?? folder
        case .tag(let tag):
            return "#" + tag
        default:
            return nil
        }
    }

    /// Number of encrypted notes sealed in the library, whether or not the vault is open.
    /// Only a count is exposed, never their contents.
    var encryptedNoteCount: Int {
        notes.reduce(0) { $0 + ($1.note.metadata.encrypted ? 1 : 0) }
    }

    /// Whether an active search is omitting encrypted notes because the vault is locked.
    /// Encrypted notes are searchable only while the vault is open, through the in-memory
    /// session index; locked, they stay sealed and out of the results, so the list offers a
    /// one-tap unlock rather than silently dropping them.
    var encryptedSearchLocked: Bool {
        searchActive && !vaultUnlocked && encryptedNoteCount > 0
    }

    /// Notes visible under the current sidebar selection and search, pinned first.
    var visibleNotes: [StoredNote] {
        var result = notes
        switch sidebarSelection {
        case .all:
            result = result.filter { !$0.note.metadata.archived }
        case .starred:
            result = result.filter { $0.note.metadata.starred && !$0.note.metadata.archived }
        case .todo:
            result = result.filter {
                !$0.note.metadata.archived && NoteQueries.hasOpenTasks($0.note.body)
            }
        case .archived:
            result = result.filter { $0.note.metadata.archived }
        case .folder(let folder):
            result = result.filter { stored in
                guard !stored.note.metadata.archived else { return false }
                return searchIsWidened
                    || SearchScope.folder(folder).contains(path: stored.path, tags: [])
            }
        case .tag(let tag):
            result = result.filter { stored in
                guard !stored.note.metadata.archived else { return false }
                return searchIsWidened
                    || SearchScope.tag(tag).contains(path: stored.path, tags: effectiveTags(stored))
            }
        case .trash:
            return []
        }
        if !activeFilters.isEmpty {
            result = result.filter { stored in
                activeFilters.allSatisfy { matches($0, stored) }
            }
        }
        if let searchHits {
            let ranks = Dictionary(
                uniqueKeysWithValues: searchHits.enumerated().map { ($1, $0) }
            )
            result = result.filter { ranks[$0.path] != nil }
            return result.sorted { ranks[$0.path, default: .max] < ranks[$1.path, default: .max] }
        }
        return noteSort.sorted(result)
    }

    /// A note's tags from both homes: front matter plus inline `#tags` typed in the body,
    /// deduplicated case-insensitively. The body of an encrypted note is base64 while
    /// locked, which can never contain a hash, so ciphertext never fabricates tags.
    func effectiveTags(_ stored: StoredNote) -> [String] {
        var seen: Set<String> = []
        var tags: [String] = []
        for tag in stored.note.metadata.tags + MarkdownScanner.inlineTags(in: stored.note.body) {
            let key = tag.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                tags.append(tag)
            }
        }
        return tags
    }

    /// Every tag on non-archived notes with its note count, sorted by name.
    var allTags: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for stored in notes where !stored.note.metadata.archived {
            for tag in effectiveTags(stored) {
                counts[tag.lowercased(), default: 0] += 1
            }
        }
        return counts.sorted { $0.key < $1.key }.map { (name: $0.key, count: $0.value) }
    }

    /// The nested tag tree for the sidebar: every tag and every intermediate parent, with
    /// depth for indentation and a descendant-inclusive note count.
    var tagTree: [(name: String, depth: Int, count: Int)] {
        let direct = allTags
        var nodes: Set<String> = []
        for tag in direct.map(\.name) {
            var prefix = ""
            for component in tag.split(separator: "/") {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                nodes.insert(prefix)
            }
        }
        return nodes.sorted().map { node in
            let count = direct
                .filter { $0.name == node || $0.name.hasPrefix(node + "/") }
                .reduce(0) { $0 + $1.count }
            return (
                name: node,
                depth: node.components(separatedBy: "/").count - 1,
                count: count
            )
        }
    }

    /// Distinct tag names across the library in their typed casing, for completion.
    var completionTags: [String] {
        var seen: Set<String> = []
        var tags: [String] = []
        for stored in notes {
            for tag in effectiveTags(stored) {
                let key = tag.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    tags.append(tag)
                }
            }
        }
        return tags.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Note titles and file stems for wiki-link completion.
    var completionTitles: [String] {
        var seen: Set<String> = []
        var titles: [String] = []
        for stored in notes {
            let title = stored.note.displayTitle ?? stem(stored.path)
            let key = title.lowercased()
            if !key.isEmpty, !seen.contains(key) {
                seen.insert(key)
                titles.append(title)
            }
        }
        return titles.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Headings of the note a wiki completion names, for `[[Note#` autocomplete. An empty
    /// name means the note being edited. Encrypted or locked notes yield nothing, so a
    /// sealed note never leaks its headings through completion.
    func headingCompletions(for name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let path = trimmed.isEmpty ? selectedPath : resolveWikiLink(trimmed)
        guard let path, let stored = notes.first(where: { $0.path == path }),
            isReadable(stored)
        else { return [] }
        return MarkdownFolding.headings(in: stored.note.body)
            .map(\.text)
            .filter { !$0.isEmpty }
    }

    /// Puts a skerry:// deep link to a note on the clipboard.
    func copyNoteLink(_ path: String) {
        var components = URLComponents()
        components.scheme = "skerry"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else { return }
        #if canImport(UIKit)
            UIPasteboard.general.string = url.absoluteString
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
    }

    /// Renames a tag across the library, descendants included: front matter entries change
    /// in place and inline #tags rewrite inside note bodies. Renaming onto an existing tag
    /// merges them.
    func renameTag(_ oldTag: String, to rawNewTag: String) {
        let newTag = rawNewTag.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !newTag.isEmpty, !newTag.contains(" "), newTag != oldTag else {
            if newTag.isEmpty || newTag.contains(" ") {
                errorMessage = "Tags cannot be empty or contain spaces. Use / to nest."
            }
            return
        }
        let target = oldTag.lowercased()
        func renamed(_ tag: String) -> String? {
            let lowered = tag.lowercased()
            if lowered == target { return newTag }
            if lowered.hasPrefix(target + "/") {
                return newTag + String(tag.dropFirst(oldTag.count))
            }
            return nil
        }
        let bodyPattern = try! NSRegularExpression(
            pattern: "(?<![\\w#])#" + NSRegularExpression.escapedPattern(for: oldTag)
                + "(?=/|$|[^\\p{L}\\p{N}_\\-/])",
            options: [.caseInsensitive]
        )
        let replacement = NSRegularExpression.escapedTemplate(for: "#" + newTag)
        for path in notes.map(\.path) {
            guard let stored = notes.first(where: { $0.path == path }) else { continue }
            if stored.note.metadata.tags.contains(where: { renamed($0) != nil }) {
                updateMetadata(for: path) { metadata in
                    var seen: Set<String> = []
                    metadata.tags = metadata.tags.compactMap { tag in
                        let result = renamed(tag) ?? tag
                        let key = result.lowercased()
                        guard !seen.contains(key) else { return nil }
                        seen.insert(key)
                        return result
                    }
                }
            }
            guard let refreshed = notes.first(where: { $0.path == path }),
                isReadable(refreshed)
            else { continue }
            let body = refreshed.note.body
            let range = NSRange(location: 0, length: (body as NSString).length)
            let updated = bodyPattern.stringByReplacingMatches(
                in: body, range: range, withTemplate: replacement
            )
            if updated != body {
                updateBody(updated, for: path)
            }
        }
        if case .tag(let selected) = sidebarSelection,
            selected == target || selected.hasPrefix(target + "/") {
            sidebarSelection = .tag(newTag.lowercased())
        }
    }

    /// One saved search shown in the sidebar.
    struct SmartFolder: Codable, Equatable, Identifiable {
        /// Display name.
        var name: String
        /// The search text the folder replays, operators included.
        var query: String
        /// Stable identity for lists.
        var id: String { name }
    }

    /// UserDefaults key holding the saved searches.
    private static let smartFoldersKey = "smartFolders"

    /// Saved searches, in creation order.
    private(set) var smartFolders: [SmartFolder] = []

    /// Loads saved searches from defaults.
    private func loadSmartFolders() {
        guard let data = UserDefaults.standard.data(forKey: Self.smartFoldersKey),
            let decoded = try? JSONDecoder().decode([SmartFolder].self, from: data)
        else { return }
        smartFolders = decoded
    }

    /// Persists saved searches to defaults.
    private func saveSmartFolders() {
        if let data = try? JSONEncoder().encode(smartFolders) {
            UserDefaults.standard.set(data, forKey: Self.smartFoldersKey)
        }
    }

    /// Saves the current search under a name, replacing one with the same name.
    func addSmartFolder(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !query.isEmpty else { return }
        smartFolders.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        smartFolders.append(SmartFolder(name: name, query: query))
        saveSmartFolders()
    }

    /// Removes a saved search.
    func removeSmartFolder(_ name: String) {
        smartFolders.removeAll { $0.name == name }
        saveSmartFolders()
    }

    /// Replays a saved search.
    func runSmartFolder(_ folder: SmartFolder) {
        sidebarSelection = .all
        searchText = folder.query
        runSearch()
    }

    /// Folder whose notes serve as templates.
    static let templatesFolder = "Templates"

    /// Notes inside the templates folder, sorted by title.
    var templates: [StoredNote] {
        notes.filter { $0.path.hasPrefix(Self.templatesFolder + "/") }
            .sorted {
                ($0.note.displayTitle ?? $0.path).lowercased()
                    < ($1.note.displayTitle ?? $1.path).lowercased()
            }
    }

    /// Creates a note from a template, filling {{date}} and {{time}} placeholders. The new
    /// note lands in the current folder unless that is the templates folder itself.
    func createFromTemplate(_ template: StoredNote) {
        var body = template.note.body
        body = body.replacingOccurrences(
            of: "{{date}}", with: Date().formatted(date: .abbreviated, time: .omitted)
        )
        body = body.replacingOccurrences(
            of: "{{time}}", with: Date().formatted(date: .omitted, time: .shortened)
        )
        if case .folder(let folder) = sidebarSelection,
            folder.hasPrefix(Self.templatesFolder) {
            sidebarSelection = .all
        }
        let title = (template.note.displayTitle ?? stem(template.path))
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        createNote(named: title.isEmpty ? "Untitled" : title, body: body)
    }

    /// Adds a tag to a note's front matter; inline tags are typed in the text itself.
    func addTag(_ rawTag: String, to path: String) {
        let tag = rawTag.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !tag.isEmpty, !tag.contains(" ") else {
            errorMessage = "Tags cannot be empty or contain spaces. Use / to nest."
            return
        }
        updateMetadata(for: path) { metadata in
            let exists = metadata.tags.contains {
                $0.caseInsensitiveCompare(tag) == .orderedSame
            }
            if !exists { metadata.tags.append(tag) }
        }
    }

    /// Removes a front matter tag from a note.
    func removeTag(_ tag: String, from path: String) {
        updateMetadata(for: path) { metadata in
            metadata.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    /// Note currently open in the editor.
    var selectedNote: StoredNote? {
        guard let selectedPath else { return nil }
        return notes.first { $0.path == selectedPath }
    }

    /// Reopens the last library from its bookmark; on iOS falls back to a default library
    /// inside the app's Documents folder so the app works with zero setup.
    func reopenLastLibrary() {
        guard store == nil else { return }
        if let url = resolveBookmark() {
            openLibrary(at: url, savingBookmark: false)
            return
        }
        #if os(iOS)
            let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            )[0]
            let fallback = documents.appendingPathComponent("Skerry Library", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: fallback, withIntermediateDirectories: true
            )
            openLibrary(at: fallback, savingBookmark: false)
        #endif
    }

    /// Opens a library the user just picked, keeping security-scoped access and a bookmark.
    func openPickedLibrary(at url: URL) {
        openLibrary(at: url, savingBookmark: true)
    }

    /// Opens a library root: loads every note and rebuilds the search index.
    private func openLibrary(at url: URL, savingBookmark: Bool) {
        isDecoySession = false
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            let store = try NoteStore(root: url)
            let index = try NoteIndex(libraryRoot: url)
            var loaded: [StoredNote] = []
            for path in try store.notePaths() {
                let stored = try store.load(path)
                loaded.append(stored)
                try index.upsert(indexEntry(stored))
            }
            if let accessedURL, accessedURL != url {
                accessedURL.stopAccessingSecurityScopedResource()
            }
            accessedURL = accessing ? url : nil
            _ = try? store.purgeTrash(deletedBefore: Date().addingTimeInterval(-Self.trashRetention))
            self.store = store
            self.index = index
            versionStore = VersionStore(libraryRoot: url)
            attachmentExtras = [:]
            notes = loaded
            decryptLoadedNotes()
            folders = (try? store.folderPaths()) ?? []
            trashedNotes = (try? store.trashedNotes()) ?? []
            selectedPath = nil
            sidebarSelection = .all
            searchText = ""
            searchHits = nil
            errorMessage = nil
            if savingBookmark { saveBookmark(for: url) }
            loadBackupState()
            loadWebDAVConfig()
            loadS3Config()
            loadVaultKeyfile()
            loadSmartFolders()
            sealingCipher = NoteCrypto.Cipher(
                rawValue: UserDefaults.standard.string(forKey: Self.sealingCipherKey) ?? ""
            ) ?? .aesGCM
            vaultLibraryMode = UserDefaults.standard.bool(forKey: Self.vaultModeKey)
            wipeAfterFailures = UserDefaults.standard.integer(forKey: Self.wipeAfterKey)
            backgroundSyncEnabled = UserDefaults.standard.bool(forKey: Self.backgroundSyncKey)
            syncMode = SyncMode(
                rawValue: UserDefaults.standard.string(forKey: Self.syncModeKey) ?? ""
            ) ?? .off
            autoLockMinutes = UserDefaults.standard.integer(forKey: Self.autoLockKey)
            startWatching(root: url)
            refreshAttachmentText()
            drainShareInbox()
            publishWidgetSnapshot()
            autoSyncIfEnabled()
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            errorMessage = "Could not open library: \(error)"
        }
    }

    /// Reloads notes and folders from disk, keeping selection where it survives.
    ///
    /// Skipped while local edits are still flushing so a reload never clobbers typing.
    func reloadLibrary() {
        guard let store, let index else { return }
        guard pendingSaves.isEmpty else { return }
        do {
            let previousPaths = Set(notes.map(\.path))
            var loaded: [StoredNote] = []
            for path in try store.notePaths() {
                let stored = try store.load(path)
                loaded.append(stored)
            }
            for vanished in previousPaths.subtracting(loaded.map(\.path)) {
                try index.remove(vanished)
            }
            notes = loaded
            decryptLoadedNotes()
            for stored in notes {
                try indexUpsert(stored)
            }
            folders = (try? store.folderPaths()) ?? []
            if let selectedPath, !notes.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = nil
            }
            if case .folder(let folder) = sidebarSelection, !folders.contains(folder) {
                sidebarSelection = .all
            }
            runSearch()
            refreshAttachmentText()
            publishWidgetSnapshot()
        } catch {
            errorMessage = "Could not reload library: \(error)"
        }
    }

    /// Creates a folder inside the current folder selection and selects it.
    func createFolder(named rawName: String) {
        guard let store else { return }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            errorMessage = "Folder names cannot be empty, contain slashes, or start with a dot."
            return
        }
        let parent: String
        if case .folder(let selected) = sidebarSelection {
            parent = selected + "/"
        } else {
            parent = ""
        }
        let path = parent + name
        guard parent.isEmpty == false || !["assets", ".skerry"].contains(name) else {
            errorMessage = "That name is reserved at the library root."
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: store.root.appendingPathComponent(path), withIntermediateDirectories: true
            )
            folders = (try? store.folderPaths()) ?? folders
            sidebarSelection = .folder(path)
        } catch {
            errorMessage = "Could not create folder: \(error)"
        }
    }

    /// Starts watching the library for outside changes; macOS only, iOS reloads on focus.
    private func startWatching(root: URL) {
        #if os(macOS)
            watcher = LibraryWatcher(root: root) { [weak self] paths in
                MainActor.assumeIsolated { self?.handleExternalChanges(paths) }
            }
        #endif
    }

    /// Schedules a reload for outside edits, ignoring cache traffic and our own writes.
    private func handleExternalChanges(_ paths: [String]) {
        let relevant = paths.contains { !$0.contains("/.skerry") }
        guard relevant else { return }
        guard Date().timeIntervalSince(lastLocalWrite) > 2 else { return }
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.reloadLibrary()
        }
    }

    /// Persists a security-scoped bookmark so the library reopens across launches.
    private func saveBookmark(for url: URL) {
        #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
            let options: URL.BookmarkCreationOptions = []
        #endif
        guard let data = try? url.bookmarkData(
            options: options, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.libraryBookmarkKey)
    }

    /// Resolves the saved bookmark, refreshing it when the system marks it stale.
    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.libraryBookmarkKey) else {
            return nil
        }
        #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
            let options: URL.BookmarkResolutionOptions = []
        #endif
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: options,
            relativeTo: nil, bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale { saveBookmark(for: url) }
        return url
    }

    /// Creates a note in the selected folder and opens it in the editor.
    /// The base name defaults to Untitled and is uniquified on collision.
    func createNote(named baseName: String = "Untitled", body customBody: String? = nil) {
        guard let store else { return }
        let folder: String
        if case .folder(let selected) = sidebarSelection {
            folder = selected + "/"
        } else {
            folder = ""
        }
        var name = "\(baseName).md"
        var counter = 2
        while notes.contains(where: { $0.path == folder + name }) {
            name = "\(baseName) \(counter).md"
            counter += 1
        }
        var metadata = Note.Metadata()
        metadata.id = UUID()
        metadata.created = Date()
        metadata.updated = metadata.created
        let seedBody = customBody ?? (baseName == "Untitled" ? "# " : "# \(baseName)\n\n")
        let stored = StoredNote(path: folder + name, note: Note(metadata: metadata, body: seedBody))
        do {
            lastLocalWrite = Date()
            try store.save(stored.note, to: stored.path)
            try indexUpsert(stored)
            notes.append(stored)
            linkGraph.update(path: stored.path, body: stored.note.body)
            open(stored.path)
            if vaultLibraryMode, vaultUnlocked {
                encryptNote(stored.path)
            }
        } catch {
            errorMessage = "Could not create note: \(error)"
        }
    }

    /// Duplicates a plain note as a new "<title> copy" carrying the same body, then opens it.
    /// Sealed or locked notes are skipped, since their in-memory body is not plain text.
    func duplicateNote(_ path: String) {
        guard let stored = notes.first(where: { $0.path == path }),
            !stored.note.metadata.encrypted, !stored.note.metadata.locked
        else { return }
        let base = (stored.note.displayTitle ?? stem(path)) + " copy"
        createNote(named: base, body: stored.note.body)
    }

    /// Creates a note from captured text, deriving a safe file name from the title or the
    /// first line. The path taken by the URL scheme, Shortcuts, and the share inbox.
    @discardableResult
    func createNoteFromCapture(title rawTitle: String, text: String) -> String? {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        var title = rawTitle.isEmpty ? firstLine : rawTitle
        title = String(title.prefix(60))
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        var body = rawTitle.isEmpty ? "" : "# \(rawTitle)\n\n"
        body += text
        createNote(
            named: title.isEmpty ? "Captured Note" : title,
            body: body.isEmpty ? nil : body
        )
        return selectedPath
    }

    /// Publishes pinned and recent plain notes for the widgets. Encrypted, locked, and
    /// archived notes never appear, so nothing sensitive sits in the shared container.
    private func publishWidgetSnapshot() {
        let visible = notes.filter {
            !$0.note.metadata.encrypted && !$0.note.metadata.locked && !$0.note.metadata.archived
        }
        let sorted = visible.sorted {
            if $0.note.metadata.pinned != $1.note.metadata.pinned {
                return $0.note.metadata.pinned
            }
            return $0.updated > $1.updated
        }
        let items = sorted.prefix(8).map {
            WidgetNote(
                title: $0.note.displayTitle ?? stem($0.path),
                path: $0.path,
                pinned: $0.note.metadata.pinned,
                updated: $0.updated
            )
        }
        let changed = WidgetSnapshotStore.write(
            WidgetSnapshot(notes: Array(items), totalCount: visible.count)
        )
        if changed {
            WidgetCenter.shared.reloadAllTimelines()
            #if os(iOS)
                WatchLink.shared.publish(titles: items.map(\.title))
            #endif
            // The same privacy cut feeds Spotlight: plain, unlocked notes only.
            let entries = visible.map { stored in
                SpotlightIndexer.Entry(
                    path: stored.path,
                    title: stored.note.displayTitle ?? stem(stored.path),
                    preview: String(stored.note.body.prefix(300)),
                    tags: effectiveTags(stored)
                )
            }
            SpotlightIndexer.reindex(entries)
        }
    }

    /// Imports captures parked by the share extension: each becomes a note, clipped
    /// images included, then the inbox is emptied.
    func drainShareInbox() {
        // Captures wait for the real library; the decoy never absorbs them.
        guard store != nil, !isDecoySession else { return }
        let previousSelection = selectedPath
        var imported = false
        for capture in ShareInbox.drain() {
            var text = capture.text
            if HTMLToMarkdown.looksLikeHTML(text) {
                text = HTMLToMarkdown.convert(text)
            }
            if !capture.url.isEmpty {
                text += text.isEmpty ? "<\(capture.url)>" : "\n\n<\(capture.url)>"
            }
            createNoteFromCapture(title: capture.title, text: text)
            imported = true
            guard let path = selectedPath else { continue }
            for (position, imageData) in capture.images.enumerated() {
                guard let link = saveFileAttachment(
                    imageData, preferredName: "clipped-\(position + 1).png", for: path
                ), let stored = notes.first(where: { $0.path == path }) else { continue }
                let body = stored.note.body
                let separator = body.isEmpty || body.hasSuffix("\n") ? "\n" : "\n\n"
                updateBody(body + separator + "![](\(link))", for: path)
            }
        }
        // Capture import should not steal the note the user was reading.
        if imported, let previousSelection,
            notes.contains(where: { $0.path == previousSelection }) {
            open(previousSelection)
        }
    }

    /// Handles a skerry:// URL: create, open, search, or sync, with Bear-style
    /// x-callback-url paths accepted alongside the short forms.
    func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "skerry" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = url.host()?.lowercased() ?? ""
        let action = host == "x-callback-url"
            ? url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            : host
        func param(_ name: String) -> String? {
            components?.queryItems?.first { $0.name == name }?.value
        }
        switch action {
        case "create", "new":
            createNoteFromCapture(
                title: param("title")?.trimmingCharacters(in: .whitespaces) ?? "",
                text: param("text") ?? ""
            )
        case "open", "open-note":
            if let path = param("path"), notes.contains(where: { $0.path == path }) {
                open(path)
            } else if let title = param("title") ?? param("id"),
                let path = resolveWikiLink(title) {
                open(path)
            }
        case "search":
            searchText = param("term") ?? param("q") ?? ""
            runSearch()
        case "sync":
            syncNow()
        default:
            break
        }
    }

    /// Recognizes text in a captured or picked image with on-device OCR and opens a new note
    /// holding it. Nothing leaves the device. An image with no text surfaces a message instead of
    /// creating an empty note.
    func scanImageToNote(_ imageData: Data) {
        Task { [weak self] in
            let recognized = await Task.detached {
                try? TextRecognizer.recognize(imageData: imageData)
            }.value
            await MainActor.run {
                guard let self else { return }
                let text = (recognized ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.errorMessage = "No text was found in that image."
                    return
                }
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? "Scanned Note"
                let title = String(firstLine.prefix(60))
                    .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
                    .joined(separator: "-")
                    .trimmingCharacters(in: .whitespaces)
                let body = text.hasPrefix("#") ? text : "# " + text
                self.createNote(named: title.isEmpty ? "Scanned Note" : title, body: body)
            }
        }
    }

    /// Imports notes picked from Bear, Obsidian, Apple Notes, or any Markdown source into the
    /// selected folder. Reads Markdown files and folders of them, pulls the text and attachments
    /// out of text bundles, and reloads the library once everything is written.
    @discardableResult
    func importNotes(from urls: [URL]) -> Int {
        guard let store else { return 0 }
        let folder: String
        if case .folder(let selected) = sidebarSelection { folder = selected + "/" } else {
            folder = ""
        }
        var count = 0
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            count += importItem(at: url, into: folder, store: store)
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        if count > 0 {
            lastLocalWrite = Date()
            reloadLibrary()
        }
        return count
    }

    /// Imports one picked item, walking folders and reading text bundles, Markdown files,
    /// Evernote exports, and Day One journals.
    private func importItem(at url: URL, into folder: String, store: NoteStore) -> Int {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        let ext = url.pathExtension.lowercased()
        if ext == "textbundle" {
            return importTextBundle(at: url, into: folder, store: store) ? 1 : 0
        }
        if isDirectory.boolValue {
            let contents = (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            )) ?? []
            return contents.reduce(0) { $0 + importItem(at: $1, into: folder, store: store) }
        }
        if ext == "enex" {
            return importENEXFile(at: url, into: folder, store: store)
        }
        if ext == "json", let data = try? Data(contentsOf: url),
            NoteImporter.looksLikeDayOne(data) {
            return importDayOneData(data, into: folder, store: store)
        }
        guard NoteImporter.markdownExtensions.contains(ext) else {
            return 0
        }
        return importMarkdownFile(at: url, into: folder, store: store) ? 1 : 0
    }

    /// Imports every note in an Evernote export, saving its attachments into assets and
    /// pointing the converted bodies at them.
    private func importENEXFile(at url: URL, into folder: String, store: NoteStore) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        var count = 0
        let depth = folder.isEmpty ? 0 : folder.split(separator: "/").count
        let backToRoot = String(repeating: "../", count: depth)
        for item in NoteImporter.importENEX(data) {
            var note = item.imported.note
            for attachment in item.attachments {
                guard let saved = try? store.saveAsset(
                    attachment.data, preferredName: attachment.preferredName
                ) else { continue }
                note.body = note.body.replacingOccurrences(
                    of: "skerry-enex://\(attachment.hash)", with: backToRoot + saved
                )
            }
            let fixed = NoteImporter.Imported(name: item.imported.name, note: note)
            if writeImported(fixed, into: folder, store: store) { count += 1 }
        }
        return count
    }

    /// Imports every entry in a Day One journal export.
    private func importDayOneData(_ data: Data, into folder: String, store: NoteStore) -> Int {
        var count = 0
        for imported in NoteImporter.importDayOne(data) {
            if writeImported(imported, into: folder, store: store) { count += 1 }
        }
        return count
    }

    /// Reads a Markdown file, converts it, and writes it into the library.
    private func importMarkdownFile(at url: URL, into folder: String, store: NoteStore) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let imported = NoteImporter.importMarkdown(
            text, fileName: url.lastPathComponent,
            created: attributes?[.creationDate] as? Date,
            modified: attributes?[.modificationDate] as? Date
        )
        return writeImported(imported, into: folder, store: store)
    }

    /// Imports a text bundle: its Markdown text plus any bundled assets, rewriting image links to
    /// the copied files so pictures survive the move.
    private func importTextBundle(at url: URL, into folder: String, store: NoteStore) -> Bool {
        let fileManager = FileManager.default
        let candidates = ["text.md", "text.markdown", "text.txt"].map(url.appendingPathComponent)
        guard let textFile = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
            var text = try? String(contentsOf: textFile, encoding: .utf8)
        else { return false }
        let depth = folder.isEmpty ? 0 : folder.split(separator: "/").count
        let backToRoot = String(repeating: "../", count: depth)
        let assetsDirectory = url.appendingPathComponent("assets")
        if let assets = try? fileManager.contentsOfDirectory(
            at: assetsDirectory, includingPropertiesForKeys: nil
        ) {
            for asset in assets {
                guard let data = try? Data(contentsOf: asset),
                    let saved = try? store.saveAsset(data, preferredName: asset.lastPathComponent)
                else { continue }
                text = text.replacingOccurrences(
                    of: "assets/\(asset.lastPathComponent)", with: backToRoot + saved
                )
            }
        }
        let attributes = try? fileManager.attributesOfItem(atPath: textFile.path)
        let imported = NoteImporter.importMarkdown(
            text, fileName: url.deletingPathExtension().lastPathComponent,
            created: attributes?[.creationDate] as? Date,
            modified: attributes?[.modificationDate] as? Date
        )
        return writeImported(imported, into: folder, store: store)
    }

    /// Writes an imported note under a collision-free file name in the target folder.
    private func writeImported(
        _ imported: NoteImporter.Imported, into folder: String, store: NoteStore
    ) -> Bool {
        let fileManager = FileManager.default
        var name = imported.name + ".md"
        var counter = 2
        while fileManager.fileExists(atPath: store.root.appendingPathComponent(folder + name).path) {
            name = "\(imported.name) \(counter).md"
            counter += 1
        }
        do {
            try store.save(imported.note, to: folder + name)
            return true
        } catch {
            return false
        }
    }

    /// Renames a note file in place, keeping its folder and the .md extension.
    func renameNote(_ path: String, to rawName: String) {
        if let stored = notes.first(where: { $0.path == path }), stored.note.metadata.encrypted {
            errorMessage = "Encrypted notes keep a private file name and cannot be renamed."
            return
        }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            errorMessage = "Note names cannot be empty, contain slashes, or start with a dot."
            return
        }
        let folder = path.contains("/")
            ? String(path[..<path.lastIndex(of: "/")!]) + "/"
            : ""
        let fileName = name.lowercased().hasSuffix(".md") ? name : name + ".md"
        movePath(path, to: folder + fileName)
    }

    /// Moves a note file into a folder; empty string means the library root.
    func moveNote(_ path: String, toFolder folder: String) {
        let fileName = String(path.split(separator: "/").last ?? "")
        movePath(path, to: folder.isEmpty ? fileName : folder + "/" + fileName)
    }

    /// Switches a note between Markdown and Plain Text by changing its file extension.
    ///
    /// Both formats carry front matter, so the note keeps its id, title, tags, and dates; only
    /// whether the editor styles Markdown changes. Refused for encrypted notes, whose sealed
    /// envelope must stay a `.md` file.
    func changeFormat(_ path: String, to ext: String) {
        guard let stored = notes.first(where: { $0.path == path }) else { return }
        guard !stored.note.metadata.encrypted else {
            errorMessage = "Encrypted notes stay in their sealed format."
            return
        }
        let current = (path as NSString).pathExtension.lowercased()
        guard current != ext else { return }
        let base = (path as NSString).deletingPathExtension
        movePath(path, to: base + "." + ext)
    }

    /// Relocates a note file, then fixes memory, index, and selection to match.
    private func movePath(_ oldPath: String, to newPath: String) {
        guard let store, oldPath != newPath else { return }
        if pendingSaves[oldPath] != nil {
            pendingSaves[oldPath]?.cancel()
            pendingSaves[oldPath] = nil
            persist(oldPath)
        }
        do {
            lastLocalWrite = Date()
            try store.move(from: oldPath, to: newPath)
            try index?.remove(oldPath)
            if let extras = attachmentExtras.removeValue(forKey: oldPath) {
                attachmentExtras[newPath] = extras
            }
            if let position = notes.firstIndex(where: { $0.path == oldPath }) {
                notes[position].path = newPath
                try indexUpsert(notes[position])
            }
            if selectedPath == oldPath { selectedPath = newPath }
            folders = (try? store.folderPaths()) ?? folders
            versionStore?.move(from: oldPath, to: newPath)
            linkGraph.move(from: oldPath, to: newPath)
        } catch {
            errorMessage = "Could not move note: \(error)"
        }
    }

    /// Whether a note's body may be shown right now.
    func isReadable(_ stored: StoredNote) -> Bool {
        let lockOK = !stored.note.metadata.locked || unlockedPaths.contains(stored.path)
        let cryptoOK = !stored.note.metadata.encrypted || decryptedPaths.contains(stored.path)
        return lockOK && cryptoOK
    }

    /// Sets or changes the encryption passphrase, stored in the keychain behind biometrics.
    ///
    /// A first passphrase is simply stored. Changing an existing one re-keys every encrypted
    /// note: the vault is unlocked so each note can be read under the old key, the change is
    /// refused if any encrypted note cannot be read, and each is then re-sealed under the new
    /// key. Without this a changed passphrase would orphan notes sealed under the old one.
    @discardableResult
    func setEncryptionPassphrase(_ passphrase: String) -> Bool {
        let trimmed = passphrase.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 8 else {
            errorMessage = "Choose a passphrase of at least eight characters."
            return false
        }

        // A legacy per-note vault holding notes is upgraded under its current passphrase first,
        // so the change becomes a re-wrap that cannot leave a note sealed under a passphrase that
        // no longer exists anywhere.
        if !vaultIsUpgraded, KeychainVault.exists(),
            notes.contains(where: { $0.note.metadata.encrypted }) {
            guard upgradeEncryption(), vaultIsUpgraded else { return false }
        }

        if vaultIsUpgraded {
            return rewrapVaultPassphrase(to: trimmed)
        }
        return createVault(passphrase: trimmed)
    }

    /// Creates a master-key vault for a fresh library: a random master key wrapped by the
    /// passphrase and a recovery code. The keyfile is the source of truth and is written before
    /// the passphrase reaches the keychain, so a keychain failure is recoverable by typing the
    /// passphrase rather than leaving the library unopenable.
    private func createVault(passphrase: String) -> Bool {
        guard let url = vaultKeyfileURL else {
            errorMessage = "Open a library before setting a passphrase."
            return false
        }
        do {
            let created = try VaultKey.create(passphrase: passphrase)
            let (code, keyfile) = try VaultKey.addRecovery(created.keyfile, master: created.key)
            let data = try VaultKey.encode(keyfile)
            lastLocalWrite = Date()
            try data.write(to: url, options: .atomic)
            vaultKeyfile = keyfile
            vaultMasterKey = created.key
            vaultPassphrase = passphrase
            if !KeychainVault.store(passphrase) {
                errorMessage = "Encryption is on, but the passphrase could not be saved to the "
                    + "keychain. You may need to enter it manually next time."
            }
            pendingRecoveryCode = code
            decryptLoadedNotes()
            convergeEncryptedNames()
            scheduleAutoLock()
            return true
        } catch {
            errorMessage = "Could not set up encryption: \(error.localizedDescription)"
            return false
        }
    }

    /// Re-wraps the master key under a new passphrase, leaving every note untouched. Requires the
    /// vault to be unlocked so the master key is in hand; writes the keyfile before updating the
    /// keychain so the on-disk key stays authoritative.
    private func rewrapVaultPassphrase(to passphrase: String) -> Bool {
        if vaultMasterKey == nil { unlockVault() }
        guard let master = vaultMasterKey, let keyfile = vaultKeyfile, let url = vaultKeyfileURL
        else {
            errorMessage = "Unlock the vault before changing the passphrase."
            return false
        }
        do {
            let updated = try VaultKey.changePassphrase(keyfile, master: master, to: passphrase)
            let data = try VaultKey.encode(updated)
            lastLocalWrite = Date()
            try data.write(to: url, options: .atomic)
            vaultKeyfile = updated
            vaultPassphrase = passphrase
            if !KeychainVault.store(passphrase) {
                errorMessage = "Passphrase changed, but it could not be saved to the keychain. "
                    + "You may need to enter it manually next time."
            }
            return true
        } catch {
            errorMessage = "Could not update the vault key: \(error.localizedDescription)"
            return false
        }
    }

    /// Unlocks the vault with biometrics and decrypts every encrypted note in memory. When the
    /// keychain has nothing to release, as on a new device or after a reinstall, it opens the
    /// manual passphrase or recovery prompt so there is always a way in.
    func unlockVault() {
        guard let passphrase = KeychainVault.fetch(reason: "Unlock your encrypted notes") else {
            if canUnlockManually {
                unlockPromptVisible = true
            } else {
                errorMessage = "Could not unlock. Authentication was canceled or failed."
            }
            return
        }
        if !applyUnlock(passphrase: passphrase), canUnlockManually {
            unlockPromptVisible = true
        }
    }

    /// Unlocks the vault with a typed passphrase, validating it against the keyfile when the
    /// library is upgraded, then caching it in the keychain so biometrics work next time. This is
    /// the way in on a new device whose keychain does not yet hold the passphrase.
    @discardableResult
    func unlockVault(withPassphrase passphrase: String) -> Bool {
        let trimmed = passphrase.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if vaultKeyfile != nil {
            if applyUnlock(passphrase: trimmed) {
                resetFailedUnlocks()
            } else if enterDecoyIfMatching(passphrase: trimmed) {
                // The decoy opened; its passphrase never reaches the real keychain entry.
                resetFailedUnlocks()
                return true
            } else {
                registerFailedUnlock()
                errorMessage = "That passphrase does not match this library."
                return false
            }
        } else {
            // Legacy per-note vault: validate against a version-1 note when one exists.
            if let sample = notes.first(where: {
                $0.note.metadata.encrypted && !EncryptedNote.isVersion2($0.note)
            }), (try? EncryptedNote.unseal(sample.note, passphrase: trimmed)) == nil {
                registerFailedUnlock()
                errorMessage = "That passphrase does not match this library."
                return false
            }
            _ = applyUnlock(passphrase: trimmed)
            resetFailedUnlocks()
        }
        KeychainVault.store(trimmed)
        return true
    }

    /// Unlocks the vault with the recovery code, recovering the master key when the passphrase is
    /// lost. The passphrase is left unset so the owner is prompted to choose a new one.
    @discardableResult
    func unlockVault(withRecovery code: String) -> Bool {
        guard let keyfile = vaultKeyfile else {
            errorMessage = "This library has no recovery code."
            return false
        }
        guard let key = try? VaultKey.unlock(keyfile, recovery: code) else {
            registerFailedUnlock()
            errorMessage = "That recovery code does not match this library."
            return false
        }
        resetFailedUnlocks()
        vaultMasterKey = key
        vaultPassphrase = nil
        // With the code in hand, a legacy recovery wrapping upgrades to Argon2id now.
        if VaultKey.needsRecoveryKDFUpgrade(keyfile), let url = vaultKeyfileURL,
            let upgraded = try? VaultKey.upgradeRecoveryKDF(keyfile, master: key, recovery: code),
            let data = try? VaultKey.encode(upgraded) {
            lastLocalWrite = Date()
            if (try? data.write(to: url, options: .atomic)) != nil {
                vaultKeyfile = upgraded
            }
        }
        decryptLoadedNotes()
        if vaultLibraryMode { encryptAllPlainNotes() }
        storeBackgroundKeyIfPossible()
        scheduleAutoLock()
        autoSyncIfEnabled()
        refreshSearchAfterUnlock()
        return true
    }

    /// Upgrades a version 2 keyfile's passphrase wrapping to Argon2id after a successful
    /// unlock, written atomically; any failure leaves the working keyfile untouched.
    private func migrateKDFIfNeeded(passphrase: String, master: SymmetricKey) {
        guard let keyfile = vaultKeyfile, VaultKey.needsKDFUpgrade(keyfile),
            let url = vaultKeyfileURL
        else { return }
        guard let upgraded = try? VaultKey.upgradeKDF(
            keyfile, master: master, passphrase: passphrase
        ), let data = try? VaultKey.encode(upgraded) else { return }
        lastLocalWrite = Date()
        if (try? data.write(to: url, options: .atomic)) != nil {
            vaultKeyfile = upgraded
        }
    }

    /// Shared unlock tail: unwraps the master key when the library is upgraded, records the
    /// passphrase, and decrypts notes. Returns false without recording anything if an upgraded
    /// keyfile refuses the passphrase.
    @discardableResult
    private func applyUnlock(passphrase: String) -> Bool {
        if let keyfile = vaultKeyfile {
            guard let key = try? VaultKey.unlock(keyfile, passphrase: passphrase) else {
                return false
            }
            vaultMasterKey = key
            migrateKDFIfNeeded(passphrase: passphrase, master: key)
        }
        vaultPassphrase = passphrase
        decryptLoadedNotes()
        convergeEncryptedNames()
        if vaultLibraryMode { encryptAllPlainNotes() }
        storeBackgroundKeyIfPossible()
        scheduleAutoLock()
        autoSyncIfEnabled()
        refreshSearchAfterUnlock()
        return true
    }

    /// Re-runs an active search after the vault opens so the newly decrypted notes, absent from
    /// the results while locked, appear at once without the user retyping the query.
    private func refreshSearchAfterUnlock() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        runSearch()
    }

    /// Enforces the invariant that every encrypted note lives under an opaque id file name.
    ///
    /// A note encrypted by an earlier build, or one that arrived title-named through file sync,
    /// is resealed into the current envelope format and renamed so its title stops leaking on
    /// disk. Idempotent: once every encrypted file is id-named, this does nothing.
    private func convergeEncryptedNames() {
        guard vaultPassphrase != nil else { return }
        let encryptedPaths = notes
            .filter { $0.note.metadata.encrypted && decryptedPaths.contains($0.path) }
            .map(\.path)
        var converged = false
        for path in encryptedPaths {
            guard let position = notes.firstIndex(where: { $0.path == path }) else { continue }
            // A sync conflict copy keeps its review name until the user resolves it. Renaming it
            // to <id>.md would hide it from the conflict review, and while its id still matched
            // the original's it also failed here on every unlock (finding F2).
            if Self.conflictOriginalStem(of: path) != nil { continue }
            if notes[position].note.metadata.id == nil {
                notes[position].note.metadata.id = UUID()
            }
            let id = notes[position].note.metadata.id!
            let name = path.components(separatedBy: "/").last ?? path
            guard name != id.uuidString + ".md" else { continue }
            persist(path)
            let folder = path.contains("/")
                ? String(path[..<path.lastIndex(of: "/")!]) + "/"
                : ""
            movePath(path, to: folder + id.uuidString + ".md")
            converged = true
        }
        // A converged note left title-named plaintext in the index; scrub it from the file.
        if converged { scrubIndexAfterEncryption() }
    }

    /// Decrypts encrypted notes in memory when the vault is unlocked; a no-op otherwise.
    /// Called after any load so a reload never leaves ciphertext in a note marked decrypted.
    private func decryptLoadedNotes() {
        guard vaultUnlocked else {
            decryptedPaths.removeAll()
            sessionIndex = nil
            rebuildLinkGraph()
            return
        }
        decryptedPaths.removeAll()
        sessionIndex = try? NoteIndex(databasePath: ":memory:")
        for position in notes.indices where notes[position].note.metadata.encrypted {
            let envelope = notes[position].note
            let inner: Note?
            if EncryptedNote.isVersion2(envelope), let key = vaultMasterKey {
                inner = try? EncryptedNote.unseal(envelope, key: key)
            } else if let passphrase = vaultPassphrase {
                inner = try? EncryptedNote.unseal(envelope, passphrase: passphrase)
            } else {
                inner = nil
            }
            if let inner {
                notes[position].note = inner
                decryptedPaths.insert(notes[position].path)
                try? sessionIndex?.upsert(notes[position])
            }
        }
        // Bodies just changed shape, so the link graph reflects the new plaintext or
        // ciphertext state. Every load and vault transition funnels through here.
        rebuildLinkGraph()
    }

    /// Loads the vault keyfile from the library root, marking the library upgraded when present.
    private func loadVaultKeyfile() {
        guard let url = vaultKeyfileURL, let data = try? Data(contentsOf: url) else {
            vaultKeyfile = nil
            return
        }
        vaultKeyfile = try? VaultKey.decode(data)
    }

    /// Upgrades the library to the master-key format and returns a recovery code to show once.
    ///
    /// The keyfile is written before any note is re-sealed, so the master key is recoverable even
    /// if the migration is interrupted, and a half-migrated library still opens because both the
    /// old passphrase and the new master key can decrypt what they sealed.
    @discardableResult
    func upgradeEncryption() -> Bool {
        guard hasEncryptionPassphrase, !vaultIsUpgraded, let url = vaultKeyfileURL else {
            return false
        }
        if vaultPassphrase == nil { unlockVault() }
        guard let passphrase = vaultPassphrase else { return false }
        let encryptedPaths = notes.filter { $0.note.metadata.encrypted }.map(\.path)
        let unreadable = encryptedPaths.filter { !decryptedPaths.contains($0) }
        guard unreadable.isEmpty else {
            errorMessage = "Some encrypted notes cannot be read, so the upgrade was canceled."
            return false
        }
        do {
            let created = try VaultKey.create(passphrase: passphrase)
            let (code, keyfile) = try VaultKey.addRecovery(created.keyfile, master: created.key)
            let data = try VaultKey.encode(keyfile)
            lastLocalWrite = Date()
            try data.write(to: url, options: .atomic)
            vaultKeyfile = keyfile
            vaultMasterKey = created.key
            for path in encryptedPaths where decryptedPaths.contains(path) {
                persist(path)
            }
            pendingRecoveryCode = code
            return true
        } catch {
            errorMessage = "Could not upgrade encryption: \(error.localizedDescription)"
            return false
        }
    }

    /// Where the decoy library lives, inside the real library's cache so it never syncs
    /// or lands in a backup.
    private var decoyRootURL: URL? {
        store?.root
            .appendingPathComponent(".skerry", isDirectory: true)
            .appendingPathComponent("decoy-library", isDirectory: true)
    }

    /// Whether a decoy library has been set up.
    var hasDecoy: Bool {
        guard let decoyRootURL else { return false }
        return FileManager.default.fileExists(
            atPath: decoyRootURL.appendingPathComponent(".skerryvault").path
        )
    }

    /// Creates the decoy library: a second, innocuous library that the unlock prompt opens
    /// when its own passphrase is typed. On disk it is just another vaulted library; only
    /// entering its passphrase reveals it exists.
    func setUpDecoy(passphrase rawPassphrase: String) {
        let passphrase = rawPassphrase.trimmingCharacters(in: .whitespaces)
        guard passphrase.count >= 8 else {
            errorMessage = "Choose a decoy passphrase of at least eight characters."
            return
        }
        guard let decoyRootURL else { return }
        if let keyfile = vaultKeyfile,
            (try? VaultKey.unlock(keyfile, passphrase: passphrase)) != nil {
            errorMessage = "That passphrase already opens your real library. Choose another."
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: decoyRootURL, withIntermediateDirectories: true
            )
            let created = try VaultKey.create(passphrase: passphrase)
            let data = try VaultKey.encode(created.keyfile)
            try data.write(
                to: decoyRootURL.appendingPathComponent(".skerryvault"), options: .atomic
            )
            let decoyStore = try NoteStore(root: decoyRootURL)
            var metadata = Note.Metadata()
            metadata.id = UUID()
            metadata.created = Date()
            metadata.updated = metadata.created
            let seed = Note(
                metadata: metadata,
                body: "# Groceries\n\n- [ ] Eggs\n- [ ] Coffee\n- [ ] Bread\n"
            )
            try decoyStore.save(seed, to: "Groceries.md")
        } catch {
            errorMessage = "Could not set up the decoy: \(error.localizedDescription)"
        }
    }

    /// Removes the decoy library.
    func removeDecoy() {
        guard let decoyRootURL else { return }
        try? FileManager.default.removeItem(at: decoyRootURL)
    }

    /// Tries the decoy after a failed real unlock; true when the decoy opened. The typed
    /// passphrase is verified against the decoy's own keyfile, so nothing about the decoy
    /// is stored beyond another ordinary vaulted library.
    private func enterDecoyIfMatching(passphrase: String) -> Bool {
        guard !isDecoySession, let decoyRootURL else { return false }
        let keyfileURL = decoyRootURL.appendingPathComponent(".skerryvault")
        guard let data = try? Data(contentsOf: keyfileURL),
            let keyfile = try? VaultKey.decode(data),
            (try? VaultKey.unlock(keyfile, passphrase: passphrase)) != nil
        else { return false }
        openLibrary(at: decoyRootURL, savingBookmark: false)
        isDecoySession = true
        applyUnlock(passphrase: passphrase)
        return true
    }

    /// Counts a failed manual unlock, destroying the keyfile at the configured limit.
    private func registerFailedUnlock() {
        guard wipeAfterFailures > 0, !isDecoySession else { return }
        let count = UserDefaults.standard.integer(forKey: Self.failedUnlocksKey) + 1
        UserDefaults.standard.set(count, forKey: Self.failedUnlocksKey)
        if count >= wipeAfterFailures {
            executeWipe()
        }
    }

    /// Clears the failed-unlock counter after any successful unlock.
    private func resetFailedUnlocks() {
        UserDefaults.standard.removeObject(forKey: Self.failedUnlocksKey)
    }

    /// Destroys local access to the vault: the keyfile and the cached passphrase.
    /// Encrypted notes become permanently unreadable on this device, recovery code
    /// included, and sync turns off so the keyfile is not simply re-adopted. Copies of
    /// the keyfile on backups or sync storage are outside this device's reach.
    private func executeWipe() {
        UserDefaults.standard.removeObject(forKey: Self.failedUnlocksKey)
        if let url = vaultKeyfileURL {
            try? FileManager.default.removeItem(at: url)
        }
        KeychainVault.clear()
        vaultKeyfile = nil
        vaultMasterKey = nil
        vaultPassphrase = nil
        pendingRecoveryCode = nil
        syncMode = .off
        backgroundSyncEnabled = false
        KeychainVault.deleteSecret(account: Self.backgroundKeyAccount)
        // Connection credentials go too: they reveal where the library lives.
        removeWebDAVDestination()
        removeS3Destination()
    }

    /// Turns on encrypt-every-note and seals everything now, unlocking first if needed.
    func applyVaultLibraryModeNow() {
        if !vaultUnlocked { unlockVault() }
        guard vaultUnlocked else { return }
        encryptAllPlainNotes()
    }

    /// Seals every plain note, the encrypt-every-note sweep.
    private func encryptAllPlainNotes() {
        guard vaultUnlocked else { return }
        for path in notes.filter({ !$0.note.metadata.encrypted }).map(\.path) {
            encryptNote(path)
        }
    }

    /// Clears the passphrase and re-reads encrypted notes as ciphertext, on backgrounding.
    ///
    /// Any debounced edit is flushed and sealed first, while the passphrase is still in hand, so
    /// a save that fires after the vault locks can never write a decrypted note out in the clear.
    func lockVault() {
        guard vaultPassphrase != nil else { return }
        autoLockTask?.cancel()
        autoLockTask = nil
        pendingSync?.cancel()
        pendingSync = nil
        stopSyncFreshness()
        flushPendingSaves()
        vaultPassphrase = nil
        vaultMasterKey = nil
        decryptedPaths.removeAll()
        reloadLibrary()
    }

    /// Resets the auto-lock countdown; call on user activity while the vault is unlocked.
    func registerActivity() {
        guard vaultUnlocked, autoLockMinutes > 0 else { return }
        scheduleAutoLock()
    }

    /// Starts or restarts the auto-lock timer, or cancels it when it does not apply.
    private func scheduleAutoLock() {
        autoLockTask?.cancel()
        autoLockTask = nil
        guard autoLockMinutes > 0, vaultUnlocked else { return }
        let seconds = Double(autoLockMinutes) * 60
        autoLockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.lockVault()
        }
    }

    /// Runs every pending debounced save now, cancelling its timer first.
    private func flushPendingSaves() {
        for path in Array(pendingSaves.keys) {
            pendingSaves[path]?.cancel()
            pendingSaves[path] = nil
            persist(path)
        }
    }

    /// Encrypts a note and renames its file to an opaque id, hiding the title on disk.
    func encryptNote(_ path: String) {
        if !vaultUnlocked {
            guard isEncryptionConfigured else {
                errorMessage = "Set an encryption passphrase in Settings first."
                return
            }
            unlockVault()
            guard vaultUnlocked else { return }
        }
        guard let position = notes.firstIndex(where: { $0.path == path }) else { return }
        // A stable opaque id becomes the file name so the title never appears on disk.
        if notes[position].note.metadata.id == nil {
            notes[position].note.metadata.id = UUID()
        }
        let id = notes[position].note.metadata.id!
        decryptedPaths.insert(path)
        // Seal any pasted images the note already carries, so encrypting a note that has
        // attachments leaves no readable picture on disk either.
        sealAttachments(for: path)
        // Seal the note at its current name first, then rename the ciphertext file, so the
        // title-named file only ever holds encrypted bytes.
        updateMetadata(for: path) { $0.encrypted = true }
        let folder = path.contains("/")
            ? String(path[..<path.lastIndex(of: "/")!]) + "/"
            : ""
        movePath(path, to: folder + id.uuidString + ".md")
        // The note's pre-encryption text was in the index; scrub it from the database file.
        scrubIndexAfterEncryption()
    }

    /// Purges freed index pages after an encryption change so a note's pre-encryption title, tags,
    /// and body cannot be carved from the index file. Retries once and warns rather than failing
    /// silently, since this scrub is the only thing that removes the former plaintext.
    private func scrubIndexAfterEncryption() {
        guard let index else { return }
        if (try? index.scrub()) != nil { return }
        if (try? index.scrub()) == nil {
            errorMessage = "The search index could not be fully cleaned. Reopen the library to "
                + "purge any leftover text from encrypted notes."
        }
    }

    /// Removes encryption from a note, writing plaintext back under a readable file name.
    func decryptNote(_ path: String) {
        guard vaultPassphrase != nil, decryptedPaths.contains(path) else {
            errorMessage = "Unlock the vault before removing encryption."
            return
        }
        guard let store, let position = notes.firstIndex(where: { $0.path == path }) else { return }
        // Restore any sealed images to plaintext while the master key is still in hand.
        unsealAttachments(for: path)
        updateMetadata(for: path) { $0.encrypted = false }
        decryptedPaths.remove(path)
        let folder = path.contains("/")
            ? String(path[..<path.lastIndex(of: "/")!]) + "/"
            : ""
        var safe = (notes[position].note.displayTitle ?? "Untitled")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        safe = String(safe.prefix(60)).trimmingCharacters(in: .whitespaces)
        if safe.isEmpty || safe.hasPrefix(".") { safe = "Untitled" }
        var target = folder + safe + ".md"
        var counter = 2
        while target != path,
            FileManager.default.fileExists(
                atPath: store.root.appendingPathComponent(target).path
            ) {
            target = folder + safe + " \(counter).md"
            counter += 1
        }
        if target != path { movePath(path, to: target) }
    }

    /// Seals a note's plaintext attachments, images and files alike, under the master key,
    /// rewrites the links to the sealed files, and deletes the originals. Changes the body in
    /// memory only, so the caller persists the now-encrypted note afterward.
    private func sealAttachments(for path: String) {
        guard let store, let key = vaultMasterKey,
            let index = notes.firstIndex(where: { $0.path == path }) else { return }
        var body = notes[index].note.body
        var changed = false
        for reference in allAttachmentReferences(for: path)
        where reference.url.pathExtension.lowercased() != "skbox" {
            guard let data = try? Data(contentsOf: reference.url),
                let sealed = try? NoteCrypto.seal(data, key: key, cipher: sealingCipher),
                let saved = try? store.saveAsset(
                    sealed, preferredName: reference.url.lastPathComponent + ".skbox"
                )
            else { continue }
            let newLink = reference.link.replacingOccurrences(
                of: reference.url.lastPathComponent, with: (saved as NSString).lastPathComponent
            )
            body = body.replacingOccurrences(of: "(\(reference.link))", with: "(\(newLink))")
            try? FileManager.default.removeItem(at: reference.url)
            changed = true
        }
        if changed { notes[index].note.body = body }
    }

    /// Restores a note's sealed attachments to plaintext, rewrites the links back, and
    /// deletes the sealed files. Changes the body in memory only, so the caller persists after.
    private func unsealAttachments(for path: String) {
        guard let store, let key = vaultMasterKey,
            let index = notes.firstIndex(where: { $0.path == path }) else { return }
        var body = notes[index].note.body
        var changed = false
        for reference in allAttachmentReferences(for: path)
        where reference.url.pathExtension.lowercased() == "skbox" {
            guard let data = try? Data(contentsOf: reference.url),
                let opened = try? NoteCrypto.unsealAny(data, key: key),
                let saved = try? store.saveAsset(
                    opened, preferredName: reference.url.deletingPathExtension().lastPathComponent
                )
            else { continue }
            let newLink = reference.link.replacingOccurrences(
                of: reference.url.lastPathComponent, with: (saved as NSString).lastPathComponent
            )
            body = body.replacingOccurrences(of: "(\(reference.link))", with: "(\(newLink))")
            try? FileManager.default.removeItem(at: reference.url)
            changed = true
        }
        if changed { notes[index].note.body = body }
    }

    /// Locks a note behind device-owner authentication.
    func lockNote(_ path: String) {
        unlockedPaths.remove(path)
        updateMetadata(for: path) { $0.locked = true }
    }

    /// Removes the lock from a note after a successful authentication.
    func removeLock(_ path: String) {
        authenticate(reason: "Remove the lock from this note") { [weak self] in
            self?.updateMetadata(for: path) { $0.locked = false }
            self?.unlockedPaths.remove(path)
        }
    }

    /// Unlocks a note for this session after a successful authentication.
    func requestUnlock(_ path: String) {
        authenticate(reason: "Unlock this note") { [weak self] in
            self?.unlockedPaths.insert(path)
        }
    }

    /// Runs device-owner authentication and calls the handler only on success.
    private func authenticate(reason: String, onSuccess: @escaping () -> Void) {
        let context = LAContext()
        var checkError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &checkError) else {
            errorMessage = "This device has no passcode or biometrics set up."
            return
        }
        Task { @MainActor in
            do {
                let ok = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication, localizedReason: reason
                )
                if ok { onSuccess() }
            } catch let error as LAError where error.code == .userCancel {
                // Canceling the prompt is not an error worth surfacing.
            } catch {
                errorMessage = "Authentication failed: \(error.localizedDescription)"
            }
        }
    }

    /// Writes a note's index entry, folding in extracted attachment text for notes whose
    /// content belongs in search. Locked and encrypted notes carry no attachment text.
    private func indexUpsert(_ stored: StoredNote) throws {
        let redactable = stored.note.metadata.locked || stored.note.metadata.encrypted
        let extras = redactable ? "" : attachmentExtras[stored.path] ?? ""
        try index?.upsert(indexEntry(stored), extras: extras)
        // A decrypted note's full text goes into the session index, memory only.
        if stored.note.metadata.encrypted, decryptedPaths.contains(stored.path) {
            try? sessionIndex?.upsert(stored)
        }
    }

    /// Extracts attachment text off the main thread and folds it into the search index.
    /// Only plain, unlocked notes take part, so OCR output of an encrypted note's sealed
    /// attachments never lands in a plaintext cache.
    private func refreshAttachmentText() {
        guard let store else { return }
        let targets: [(path: String, urls: [URL])] = notes
            .filter { !$0.note.metadata.encrypted && !$0.note.metadata.locked }
            .map { (path: $0.path, urls: allAttachmentReferences(for: $0.path).map(\.url)) }
            .filter { !$0.urls.isEmpty }
        guard !targets.isEmpty else { return }
        let root = store.root
        attachmentExtractionTask?.cancel()
        attachmentExtractionTask = Task { [weak self] in
            let extracted = await Task.detached(priority: .utility) {
                var cache = AttachmentTextCache(libraryRoot: root)
                var results: [(path: String, text: String)] = []
                for target in targets {
                    guard !Task.isCancelled else { break }
                    var texts: [String] = []
                    for url in target.urls {
                        if let text = cache.text(for: url) { texts.append(text) }
                    }
                    if !texts.isEmpty {
                        results.append((path: target.path, text: texts.joined(separator: "\n")))
                    }
                }
                cache.save()
                return results
            }.value
            guard !Task.isCancelled else { return }
            self?.applyAttachmentExtras(extracted)
        }
    }

    /// Applies freshly extracted attachment text to the index entries it belongs to.
    private func applyAttachmentExtras(_ extracted: [(path: String, text: String)]) {
        for entry in extracted where attachmentExtras[entry.path] != entry.text {
            attachmentExtras[entry.path] = entry.text
            if let stored = notes.first(where: { $0.path == entry.path }) {
                try? indexUpsert(stored)
            }
        }
    }

    /// Index representation of a note; locked and encrypted bodies stay out of search,
    /// and a plain note's inline tags count as tags for tag search.
    private func indexEntry(_ stored: StoredNote) -> StoredNote {
        guard stored.note.metadata.locked || stored.note.metadata.encrypted else {
            var entry = stored
            entry.note.metadata.tags = effectiveTags(stored)
            return entry
        }
        var redacted = stored
        redacted.note.body = ""
        // An encrypted note keeps its title and tags out of the on-disk index as well, so the
        // plaintext search cache never reveals what a decrypted note is about.
        if stored.note.metadata.encrypted {
            redacted.note.metadata.title = nil
            redacted.note.metadata.tags = []
        }
        return redacted
    }

    /// File extensions rendered as image thumbnails rather than file chips.
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]

    /// Saves pasted attachment data into assets and returns the note-relative link path. When the
    /// target note is encrypted, the image is sealed under the master key and stored with a
    /// `.skbox` suffix, so an encrypted note never leaves a readable picture on disk.
    func saveAttachment(_ data: Data, fileExtension: String, for notePath: String) -> String? {
        let stamp = Date().formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: false)
        ).replacingOccurrences(of: ":", with: "")
        return saveFileAttachment(
            data, preferredName: "pasted-\(stamp).\(fileExtension)", for: notePath
        )
    }

    /// Saves any file's bytes into assets under its own name and returns the note-relative
    /// link path. Sealed under the master key with a `.skbox` suffix when the note is
    /// encrypted, so an encrypted note never leaves a readable attachment on disk.
    func saveFileAttachment(_ data: Data, preferredName: String, for notePath: String) -> String? {
        guard let store else { return nil }
        do {
            lastLocalWrite = Date()
            var payload = data
            var name = preferredName
            if decryptedPaths.contains(notePath), let key = vaultMasterKey {
                payload = try NoteCrypto.seal(data, key: key, cipher: sealingCipher)
                name += ".skbox"
            }
            let assetPath = try store.saveAsset(payload, preferredName: name)
            let depth = notePath.split(separator: "/").count - 1
            return String(repeating: "../", count: max(depth, 0)) + assetPath
        } catch {
            errorMessage = "Could not save attachment: \(error)"
            return nil
        }
    }

    /// Copies picked files into assets and appends links to the note body; returns how many
    /// attached. Images become image links so they render in the thumbnail strip.
    @discardableResult
    func attachFiles(_ urls: [URL], to notePath: String) -> Int {
        guard let stored = notes.first(where: { $0.path == notePath }) else { return 0 }
        var links: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                let link = saveFileAttachment(
                    data, preferredName: url.lastPathComponent, for: notePath
                )
            else { continue }
            if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                links.append("![](\(link))")
            } else {
                links.append("[\(url.lastPathComponent)](\(link))")
            }
        }
        guard !links.isEmpty else { return 0 }
        let body = stored.note.body
        let separator = body.isEmpty || body.hasSuffix("\n") ? "\n" : "\n\n"
        updateBody(body + separator + links.joined(separator: "\n"), for: notePath)
        refreshAttachmentText()
        return links.count
    }

    /// Matches a web link standing alone, outside any markdown link syntax.
    private static let bareLinkPattern = try! NSRegularExpression(
        pattern: #"(?<![\(\]<])https?://[^\s\)\]>]+"#
    )

    /// Fetches page titles for bare links in a note and rewrites them as markdown links.
    /// The only network use in the app, and it happens solely on this explicit command.
    func fetchLinkTitles(for path: String) {
        guard let stored = notes.first(where: { $0.path == path }) else { return }
        let body = stored.note.body
        let ns = body as NSString
        var targets: [String] = []
        let whole = NSRange(location: 0, length: ns.length)
        for match in Self.bareLinkPattern.matches(in: body, range: whole) {
            let link = ns.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if !targets.contains(link) { targets.append(link) }
        }
        guard !targets.isEmpty else {
            errorMessage = "No bare links found to title."
            return
        }
        Task { [weak self] in
            var titles: [String: String] = [:]
            for link in targets.prefix(8) {
                guard let url = URL(string: link) else { continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                    let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode)
                else { continue }
                let html = String(decoding: data.prefix(262_144), as: UTF8.self)
                if let title = HTMLToMarkdown.pageTitle(in: html) {
                    let safe = title
                        .replacingOccurrences(of: "[", with: "")
                        .replacingOccurrences(of: "]", with: "")
                    if !safe.isEmpty { titles[link] = safe }
                }
            }
            guard let self else { return }
            guard !titles.isEmpty else {
                self.errorMessage = "No titles could be fetched for those links."
                return
            }
            guard let current = self.notes.first(where: { $0.path == path }) else { return }
            var updated = current.note.body
            for (link, title) in titles {
                let escaped = NSRegularExpression.escapedPattern(for: link)
                let pattern = try! NSRegularExpression(pattern: "(?<![\\(\\]<])" + escaped)
                let range = NSRange(location: 0, length: (updated as NSString).length)
                updated = pattern.stringByReplacingMatches(
                    in: updated, range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(
                        for: "[\(title)](\(link))"
                    )
                )
            }
            self.updateBody(updated, for: path)
        }
    }

    /// Opens today's journal note, creating it in the Journal folder on first use.
    func openDailyNote() {
        guard store != nil else { return }
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let path = "Journal/\(stamp).md"
        if notes.contains(where: { $0.path == path }) {
            open(path)
            return
        }
        let heading = Date().formatted(
            Date.FormatStyle().weekday(.wide).month(.wide).day().year()
        )
        let previous = sidebarSelection
        sidebarSelection = .folder("Journal")
        if !folders.contains("Journal") {
            createFolder(named: "Journal")
        }
        createNote(named: stamp, body: "# \(heading)\n\n")
        sidebarSelection = previous
        if let selectedPath { open(selectedPath) }
    }

    /// Creates a note from a recorded memo: the on-device transcript as the body and the
    /// audio attached beside it. Without a transcript, the note still keeps the audio.
    func createAudioMemoNote(audio: URL, transcript: String?, problem: String?) {
        guard store != nil else { return }
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        let title = "Audio Memo \(stamp)"
        var body = "# \(title)\n\n"
        if let transcript {
            body += transcript + "\n"
        } else if let problem {
            body += "_No transcript: \(problem)_\n"
        }
        createNoteFromCapture(title: title, text: String(body.dropFirst("# \(title)\n\n".count)))
        guard let path = selectedPath, let data = try? Data(contentsOf: audio) else { return }
        if let link = saveFileAttachment(data, preferredName: "memo.m4a", for: path),
            let stored = notes.first(where: { $0.path == path }) {
            let separator = stored.note.body.hasSuffix("\n") ? "\n" : "\n\n"
            updateBody(stored.note.body + separator + "[Audio](\(link))", for: path)
        }
        try? FileManager.default.removeItem(at: audio)
        if let problem, transcript == nil {
            errorMessage = problem
        }
    }

    #if canImport(UIKit)
        /// Builds a note from scanned pages: on-device OCR text as the body, page by page,
        /// with the pages bound into a searchable PDF attachment.
        func createScannedDocumentNote(pages: [UIImage]) {
            guard !pages.isEmpty, store != nil else { return }
            let pageData = pages.compactMap { $0.jpegData(compressionQuality: 0.85) }
            let pdf = Self.bindPDF(pages: pages)
            Task { [weak self] in
                var texts: [String] = []
                for data in pageData {
                    let recognized = await Task.detached {
                        try? TextRecognizer.recognize(imageData: data)
                    }.value
                    let trimmed = (recognized ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    texts.append(trimmed)
                }
                await MainActor.run {
                    guard let self else { return }
                    let stamp = Date().formatted(date: .abbreviated, time: .shortened)
                    let title = "Scanned Document \(stamp)"
                    var body = ""
                    for (index, text) in texts.enumerated() where !text.isEmpty {
                        if texts.filter({ !$0.isEmpty }).count > 1 {
                            body += "## Page \(index + 1)\n\n"
                        }
                        body += text + "\n\n"
                    }
                    if body.isEmpty { body = "_No text was recognized in the scan._\n" }
                    self.createNoteFromCapture(title: title, text: body)
                    guard let path = self.selectedPath else { return }
                    if let link = self.saveFileAttachment(
                        pdf, preferredName: "scan.pdf", for: path
                    ), let stored = self.notes.first(where: { $0.path == path }) {
                        let separator = stored.note.body.hasSuffix("\n") ? "\n" : "\n\n"
                        self.updateBody(
                            stored.note.body + separator + "[Scanned PDF](\(link))", for: path
                        )
                    }
                }
            }
        }

        /// Binds page images into one PDF.
        private static func bindPDF(pages: [UIImage]) -> Data {
            let data = NSMutableData()
            UIGraphicsBeginPDFContextToData(data, .zero, nil)
            for page in pages {
                let bounds = CGRect(origin: .zero, size: page.size)
                UIGraphicsBeginPDFPageWithInfo(bounds, nil)
                page.draw(in: bounds)
            }
            UIGraphicsEndPDFContext()
            return data as Data
        }
    #endif

    /// File extensions treated as audio for transcription.
    private static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "aiff", "caf"]

    /// Whether an attachment URL points at audio, sealed or not.
    func isAudioAttachment(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased() == "skbox"
            ? (url.deletingPathExtension().pathExtension.lowercased())
            : url.pathExtension.lowercased()
        return Self.audioExtensions.contains(ext)
    }

    /// Transcribes an audio attachment on device and appends the transcript to the note.
    func transcribeAttachment(_ url: URL, into path: String) {
        guard let playable = previewableURL(for: url) else {
            errorMessage = "Unlock the vault to transcribe this attachment."
            return
        }
        Task { [weak self] in
            do {
                let transcript = try await SpeechTranscriber.transcribe(url: playable)
                guard let self, let stored = self.notes.first(where: { $0.path == path })
                else { return }
                let separator = stored.note.body.hasSuffix("\n") ? "\n" : "\n\n"
                self.updateBody(
                    stored.note.body + separator + "## Transcript\n\n" + transcript + "\n",
                    for: path
                )
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Saves sketch PNG data as an attachment and appends its image link to the note.
    func attachSketch(_ data: Data, to notePath: String) {
        guard let stored = notes.first(where: { $0.path == notePath }) else { return }
        let stamp = Date().formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: false)
        ).replacingOccurrences(of: ":", with: "")
        guard let link = saveFileAttachment(
            data, preferredName: "sketch-\(stamp).png", for: notePath
        ) else { return }
        let body = stored.note.body
        let separator = body.isEmpty || body.hasSuffix("\n") ? "\n" : "\n\n"
        updateBody(body + separator + "![](\(link))", for: notePath)
    }

    /// Absolute URLs of image files the note links to, resolved against its folder.
    func imageAttachments(for notePath: String) -> [URL] {
        imageReferences(for: notePath).map(\.url)
    }

    /// Image links in a note paired with the resolved file URL, including sealed `.skbox` images.
    /// Remote URLs and anything resolving outside the library are skipped.
    func imageReferences(for notePath: String) -> [(link: String, url: URL)] {
        resolvedLinks(
            in: notePath, pattern: #"!\[[^\]\n]*\]\(([^)\n]+)\)"#,
            allows: { Self.imageExtensions.contains($0) }
        )
    }

    /// Non-image file links in a note paired with the resolved file URL, including sealed
    /// `.skbox` attachments. Remote URLs and anything outside the library are skipped.
    func fileReferences(for notePath: String) -> [(link: String, url: URL)] {
        resolvedLinks(
            in: notePath, pattern: #"(?<!\!)\[[^\]\n]*\]\(([^)\n]+)\)"#,
            allows: { !Self.imageExtensions.contains($0) }
        )
    }

    /// Every attachment reference in a note: images and files together.
    func allAttachmentReferences(for notePath: String) -> [(link: String, url: URL)] {
        imageReferences(for: notePath) + fileReferences(for: notePath)
    }

    /// Links matched by a pattern in a note's body, resolved to files inside the library.
    /// The filter receives the effective extension, with a sealed `.skbox` layer stripped.
    private func resolvedLinks(
        in notePath: String, pattern: String, allows: (String) -> Bool
    ) -> [(link: String, url: URL)] {
        guard let store, let stored = notes.first(where: { $0.path == notePath }) else { return [] }
        let noteDir = store.root
            .appendingPathComponent(notePath)
            .deletingLastPathComponent()
        var seen: Set<String> = []
        var references: [(link: String, url: URL)] = []
        let body = stored.note.body as NSString
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(
            in: stored.note.body, range: NSRange(location: 0, length: body.length)
        )
        for match in matches {
            let link = body.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            guard !link.contains("://"), !link.hasPrefix("#") else { continue }
            let nsLink = link as NSString
            let ext = nsLink.pathExtension.lowercased()
            let effective = ext == "skbox"
                ? (nsLink.deletingPathExtension as NSString).pathExtension.lowercased()
                : ext
            guard allows(effective) else { continue }
            let url = URL(fileURLWithPath: link, relativeTo: noteDir).standardizedFileURL
            guard url.path.hasPrefix(store.root.path + "/"), !seen.contains(url.path),
                FileManager.default.fileExists(atPath: url.path)
            else { continue }
            seen.insert(url.path)
            references.append((link: link, url: url))
        }
        return references
    }

    /// Bytes to render for an attachment: the file as-is, or the decrypted plaintext for a sealed
    /// `.skbox` attachment. Returns nil when a sealed file cannot be opened, as when the vault is
    /// locked, so the view can show a placeholder instead of broken content.
    func attachmentImageData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard url.pathExtension.lowercased() == "skbox" else { return data }
        guard let key = vaultMasterKey else { return nil }
        return try? NoteCrypto.unsealAny(data, key: key)
    }

    /// Decoded image for an inline body link, decrypting sealed attachments in memory.
    /// Nil for remote links, missing files, or a sealed image while the vault is locked.
    func inlineImage(link: String, for notePath: String) -> PlatformImage? {
        guard let store else { return nil }
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }
        let noteDir = store.root
            .appendingPathComponent(notePath)
            .deletingLastPathComponent()
        let url = URL(fileURLWithPath: trimmed, relativeTo: noteDir).standardizedFileURL
        guard url.path.hasPrefix(store.root.path + "/") else { return nil }
        guard let data = attachmentImageData(at: url) else { return nil }
        return PlatformImage(data: data)
    }

    /// A URL a previewer can open: the file itself, or a sealed attachment decrypted into a
    /// scratch file that is replaced on each preview. Nil while the vault is locked.
    func previewableURL(for url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "skbox" else { return url }
        guard let data = attachmentImageData(at: url) else { return nil }
        let previews = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkerryPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: previews)
        guard (try? FileManager.default.createDirectory(
            at: previews, withIntermediateDirectories: true
        )) != nil else { return nil }
        let target = previews.appendingPathComponent(
            url.deletingPathExtension().lastPathComponent
        )
        guard (try? data.write(to: target)) != nil else { return nil }
        return target
    }

    /// Opens the note a wiki link points at, creating it first when it does not exist,
    /// then scrolls to the linked heading. A `Note#Heading` target resolves on the note
    /// part, so the heading never leaks into the note name; an empty note part scrolls
    /// within the note the link sits in.
    func followWikiLink(_ target: String, heading: String? = nil) {
        let split = WikiLink.split(target)
        let wantedHeading = heading ?? split.heading
        if split.note.isEmpty {
            if let current = selectedPath { open(current, heading: wantedHeading) }
            return
        }
        if let existing = resolveWikiLink(split.note) {
            open(existing, heading: wantedHeading)
            return
        }
        createNote(named: split.note.trimmingCharacters(in: .whitespaces))
    }

    /// Resolves a wiki-link name to a note path by title or file name, case-insensitive.
    func resolveWikiLink(_ name: String) -> String? {
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return nil }
        if let hit = notes.first(where: { stem($0.path).lowercased() == target }) {
            return hit.path
        }
        return notes.first { $0.note.displayTitle?.lowercased() == target }?.path
    }

    /// Notes whose bodies wiki-link to the given note, by its title or file name.
    /// A lookup in the cached link graph, so large libraries stay fast.
    func backlinks(to path: String) -> [StoredNote] {
        guard let stored = notes.first(where: { $0.path == path }) else { return [] }
        var names = [stem(path)]
        if let title = stored.note.displayTitle { names.append(title) }
        let sources = linkGraph.sources(linkingTo: names)
        guard !sources.isEmpty else { return [] }
        return notes.filter { $0.path != path && sources.contains($0.path) }
    }

    /// Notes that mention the open note's title in plain text without wiki-linking it.
    /// Titles shorter than four characters stay quiet, since matches would be noise.
    func unlinkedMentions(of path: String) -> [StoredNote] {
        guard let stored = notes.first(where: { $0.path == path }) else { return [] }
        guard let title = stored.note.displayTitle, title.count >= 4 else { return [] }
        let linked = Set(backlinks(to: path).map(\.path))
        return notes.filter { other in
            guard other.path != path, !linked.contains(other.path),
                isReadable(other)
            else { return false }
            return other.note.body.range(of: title, options: .caseInsensitive) != nil
        }
    }

    /// Rebuilds the wiki-link graph from every in-memory body. Runs after loads and
    /// vault transitions; single-note edits update the graph incrementally instead.
    private func rebuildLinkGraph() {
        linkGraph = LinkGraph()
        for stored in notes {
            linkGraph.update(path: stored.path, body: stored.note.body)
        }
    }

    /// File name of a note path without folders or the .md extension.
    func stem(_ path: String) -> String {
        let name = String(path.split(separator: "/").last ?? "")
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// Discards a note when leaving it if it is still a blank, untitled placeholder.
    /// Removes the file outright since there was never any content to recover.
    func discardIfEmpty(_ path: String) {
        guard let store, let stored = notes.first(where: { $0.path == path }) else { return }
        let trimmed = stored.note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank note is empty or only heading markers, matching the seeded "# " scaffold and the
        // empty-note character count. Any real content keeps the note.
        let isBlank = trimmed.allSatisfy { $0 == "#" }
        guard isBlank, stem(path).hasPrefix("Untitled"),
            !stored.note.metadata.starred, !stored.note.metadata.pinned,
            !stored.note.metadata.locked, stored.note.metadata.tags.isEmpty
        else { return }
        pendingSaves[path]?.cancel()
        pendingSaves[path] = nil
        do {
            lastLocalWrite = Date()
            try FileManager.default.removeItem(at: store.root.appendingPathComponent(path))
            try index?.remove(path)
            notes.removeAll { $0.path == path }
            if selectedPath == path { selectedPath = nil }
            pathStack.removeAll { $0 == path }
            versionStore?.removeAll(for: path)
            linkGraph.remove(path: path)
        } catch {
            // A failed discard is not worth interrupting the user over.
        }
    }

    /// Moves a note to the library trash, where it can be recovered for 30 days.
    func trashNote(_ path: String) {
        guard let store else { return }
        do {
            lastLocalWrite = Date()
            try store.moveToTrash(path, deletedAt: Date())
            try index?.remove(path)
            notes.removeAll { $0.path == path }
            if selectedPath == path { selectedPath = nil }
            pathStack.removeAll { $0 == path }
            linkGraph.remove(path: path)
            refreshTrash()
            publishWidgetSnapshot()
        } catch {
            errorMessage = "Could not delete note: \(error)"
        }
    }

    /// Reloads the list of trashed notes from disk.
    func refreshTrash() {
        trashedNotes = (try? store?.trashedNotes()) ?? []
    }

    /// Matches the stem of a sync conflict copy and captures the original stem.
    private static let conflictStemPattern = try! NSRegularExpression(
        pattern: #"^(.+) \(conflict [0-9T:\-]+( [0-9]+)?\)$"#
    )

    /// Conflict copies written by sync, each paired with the note it forked from.
    var conflictPairs: [ConflictPair] {
        notes.compactMap { stored in
            guard let originalStem = Self.conflictOriginalStem(of: stored.path) else { return nil }
            let folder = stored.path.contains("/")
                ? String(stored.path[..<stored.path.lastIndex(of: "/")!]) + "/"
                : ""
            let ext = (stored.path as NSString).pathExtension
            let originalPath = folder + originalStem + (ext.isEmpty ? "" : "." + ext)
            return ConflictPair(
                copy: stored, original: notes.first { $0.path == originalPath }
            )
        }
    }

    /// The stem a conflict copy forked from, or nil for ordinary paths. A cheap
    /// substring check runs first so scanning every note stays fast.
    private static func conflictOriginalStem(of path: String) -> String? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard stem.contains("(conflict ") else { return nil }
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = conflictStemPattern.firstMatch(in: stem, range: range),
            let originalRange = Range(match.range(at: 1), in: stem)
        else { return nil }
        return String(stem[originalRange])
    }

    /// Resolves a conflict by keeping this device's version and trashing the sync copy.
    func resolveConflictKeepingMine(_ pair: ConflictPair) {
        trashNote(pair.copy.path)
    }

    /// Resolves a conflict by taking the synced version: the original's text and tags
    /// become the copy's, and the copy is trashed. Lock and encryption flags stay as
    /// they are, since those must follow the sealed bytes rather than a review click.
    /// With no surviving original, the copy is promoted to the original name instead.
    func resolveConflictKeepingTheirs(_ pair: ConflictPair) {
        guard let original = pair.original else {
            promoteConflictCopy(pair)
            return
        }
        updateBody(pair.copy.note.body, for: original.path)
        updateMetadata(for: original.path) { $0.tags = pair.copy.note.metadata.tags }
        trashNote(pair.copy.path)
    }

    /// Resolves a conflict by keeping both notes; the copy is renamed from a conflict
    /// marker to a plain copy marker so it stops being flagged for review.
    func resolveConflictKeepingBoth(_ pair: ConflictPair) {
        let newPath = pair.copy.path.replacingOccurrences(of: "(conflict ", with: "(copy ")
        movePath(pair.copy.path, to: newPath)
    }

    /// Builds the insights summary from the library as it is readable right now.
    /// Sealed notes count toward totals but contribute no words, tasks, or dates.
    func computeInsights() -> InsightsSummary {
        var summary = InsightsSummary()
        var dates: [Date] = []
        for stored in notes {
            summary.noteCount += 1
            if stored.note.metadata.encrypted { summary.encryptedCount += 1 }
            guard isReadable(stored) else { continue }
            summary.readableCount += 1
            summary.wordCount += stored.note.body.split(whereSeparator: \.isWhitespace).count
            summary.openTasks += NoteQueries.openTaskCount(stored.note.body)
            summary.doneTasks += NoteQueries.doneTaskCount(stored.note.body)
            if let created = stored.note.metadata.created {
                dates.append(created)
                if summary.firstNoteDate.map({ created < $0 }) ?? true {
                    summary.firstNoteDate = created
                }
            }
            if let updated = stored.note.metadata.updated { dates.append(updated) }
        }
        let tags = allTags
        summary.tagCount = tags.count
        summary.topTags = Array(tags.sorted { $0.count > $1.count }.prefix(5))
        summary.streaks = WritingStreaks.compute(from: dates)
        return summary
    }

    /// Renames a conflict copy to the original name its stem points at, taking the
    /// first free variant if a file has appeared there in the meantime.
    private func promoteConflictCopy(_ pair: ConflictPair) {
        guard let store, let originalStem = Self.conflictOriginalStem(of: pair.copy.path)
        else { return }
        let folder = pair.copy.path.contains("/")
            ? String(pair.copy.path[..<pair.copy.path.lastIndex(of: "/")!]) + "/"
            : ""
        let ext = (pair.copy.path as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = folder + originalStem + suffix
        var counter = 2
        while FileManager.default.fileExists(
            atPath: store.root.appendingPathComponent(candidate).path
        ) {
            candidate = folder + originalStem + " \(counter)" + suffix
            counter += 1
        }
        movePath(pair.copy.path, to: candidate)
    }

    /// Resolves the saved backup destination and loads its snapshots, on library open.
    private func loadBackupState() {
        autoBackupEnabled = UserDefaults.standard.bool(forKey: Self.autoBackupKey)
        guard let data = UserDefaults.standard.data(forKey: Self.backupBookmarkKey) else {
            backupDestination = nil
            backupSnapshots = []
            encryptedSnapshots = []
            return
        }
        #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
            let options: URL.BookmarkResolutionOptions = []
        #endif
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: options, relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        backupDestination = url
        refreshBackups()
    }

    /// Sets and remembers the folder where backups are written.
    func chooseBackupDestination(_ url: URL) {
        #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
            let options: URL.BookmarkCreationOptions = []
        #endif
        guard let data = try? url.bookmarkData(
            options: options, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else {
            errorMessage = "Could not remember that backup location."
            return
        }
        UserDefaults.standard.set(data, forKey: Self.backupBookmarkKey)
        backupDestination = url
        refreshBackups()
    }

    /// Writes a new backup snapshot now, pruning old ones. Sealed when a passphrase exists, so
    /// the copy that leaves the device is ciphertext even for notes that are not encrypted. A
    /// WebDAV destination takes precedence and is always encrypted.
    ///
    /// Snapshots to a folder are free. WebDAV and S3 destinations belong to Plus, so without
    /// it a manual backup offers the upgrade and still writes the local snapshot.
    /// - Parameter manual: Whether a person pressed Back Up Now, which may raise the paywall.
    func backUpNow(manual: Bool = true) {
        guard !isDecoySession else { return }
        let hasRemote = webDAVConfig != nil || s3Config != nil
        if hasRemote, PlusStore.shared.isUnlocked(.remoteBackup) {
            if let config = webDAVConfig {
                Task { await backUpToWebDAV(config) }
                return
            }
            if let config = s3Config {
                Task { await backUpToS3(config) }
                return
            }
        }
        if hasRemote, manual, !PlusStore.shared.isUnlocked(.remoteBackup) {
            paywallFeature = .remoteBackup
        }
        guard let store, let destination = backupDestination else { return }
        guard isEncryptionConfigured else {
            errorMessage = "Set an encryption passphrase in Settings to enable backups. Skerry "
                + "only writes encrypted backups, so nothing leaves your device in the clear."
            return
        }
        if vaultPassphrase == nil { unlockVault() }
        guard let passphrase = vaultPassphrase else {
            errorMessage = "Unlock to back up your encrypted library."
            return
        }
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        do {
            try EncryptedBackup.seal(
                library: store.root, to: destination,
                named: EncryptedBackup.name(for: Date()), passphrase: passphrase
            )
            try EncryptedBackup.prune(in: destination, keeping: Self.backupsToKeep)
            // Sweep any plaintext snapshots left from before encryption was enabled, so the
            // destination never keeps a cleartext copy alongside the sealed ones.
            _ = try? LibraryBackup.prune(in: destination, keeping: 0)
            refreshBackups()
        } catch {
            errorMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    /// Backs up when auto-backup is on; called as the app leaves the foreground.
    ///
    /// With encryption on, a background backup runs only while the vault is already unlocked, so
    /// it never writes plaintext and never prompts for Face ID at an awkward moment.
    func autoBackupIfEnabled() {
        guard autoBackupEnabled,
            hasBackupDestination || hasWebDAVDestination || hasS3Destination else { return }
        // Backups are always encrypted, so an automatic one needs an unlocked vault to seal with.
        // It waits rather than prompting for Face ID or writing anything in the clear.
        guard isEncryptionConfigured, vaultPassphrase != nil else { return }
        backUpNow(manual: false)
    }

    /// Restores a plaintext snapshot into the library and reloads notes from disk.
    func restoreBackup(_ snapshot: LibraryBackup.Snapshot) {
        guard let store, let destination = backupDestination else { return }
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        do {
            try LibraryBackup.restore(snapshot.url, into: store.root)
            reloadLibrary()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Restores an encrypted snapshot, decrypting it with the vault passphrase.
    func restoreEncrypted(_ snapshot: EncryptedBackup.Snapshot) {
        guard let store, let destination = backupDestination else { return }
        if vaultPassphrase == nil { unlockVault() }
        guard let passphrase = vaultPassphrase else {
            errorMessage = "Unlock to restore an encrypted backup."
            return
        }
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        do {
            try EncryptedBackup.restore(snapshot.url, into: store.root, passphrase: passphrase)
            reloadLibrary()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Reloads the plaintext and encrypted snapshot lists from the backup destination.
    func refreshBackups() {
        guard let destination = backupDestination else {
            backupSnapshots = []
            encryptedSnapshots = []
            return
        }
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        backupSnapshots = LibraryBackup.snapshots(in: destination)
        encryptedSnapshots = EncryptedBackup.snapshots(in: destination)
    }

    /// StoredWebDAVDestination is the keychain-serialized WebDAV connection.
    private struct StoredWebDAVDestination: Codable {
        /// Collection URL string.
        var url: String
        /// Login user name.
        var user: String
        /// Login password.
        var password: String
    }

    /// Loads a saved WebDAV destination from its keychain item and lists its snapshots,
    /// after migrating anything an earlier build left in UserDefaults.
    private func loadWebDAVConfig() {
        if let json = KeychainVault.fetchSecret(account: Self.webDAVDestinationAccount),
            let stored = try? JSONDecoder().decode(
                StoredWebDAVDestination.self, from: Data(json.utf8)
            ),
            let url = URL(string: stored.url) {
            webDAVConfig = WebDAVClient.Config(
                baseURL: url, username: stored.user, password: stored.password
            )
            Task { await refreshWebDAVSnapshots() }
            return
        }
        migrateLegacyWebDAVStorage()
    }

    /// Moves a destination saved by earlier builds, URL and user name in UserDefaults and
    /// the password in its own keychain item, into the single keychain item, then wipes
    /// every legacy trace so nothing about the server remains in a plist.
    private func migrateLegacyWebDAVStorage() {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: Self.webDAVURLKey)
            defaults.removeObject(forKey: Self.webDAVUserKey)
            KeychainVault.deleteSecret(account: Self.webDAVPasswordAccount)
        }
        guard let urlString = defaults.string(forKey: Self.webDAVURLKey),
            let url = URL(string: urlString),
            let user = defaults.string(forKey: Self.webDAVUserKey),
            let password = KeychainVault.fetchSecret(account: Self.webDAVPasswordAccount)
        else {
            webDAVConfig = nil
            return
        }
        storeWebDAVDestination(url: url, username: user, password: password)
        Task { await refreshWebDAVSnapshots() }
    }

    /// Persists the WebDAV destination as one keychain item and adopts it in memory.
    private func storeWebDAVDestination(url: URL, username: String, password: String) {
        let stored = StoredWebDAVDestination(
            url: url.absoluteString, user: username, password: password
        )
        if let data = try? JSONEncoder().encode(stored) {
            KeychainVault.storeSecret(
                String(decoding: data, as: UTF8.self), account: Self.webDAVDestinationAccount
            )
        }
        webDAVConfig = WebDAVClient.Config(baseURL: url, username: username, password: password)
    }

    /// Configures a WebDAV destination and lists its snapshots. Returns whether the
    /// destination was accepted, so the form knows when to clear its fields.
    @discardableResult
    func setWebDAVDestination(urlString: String, username: String, password: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", url.host() != nil
        else {
            webDAVStatus = "Enter a valid URL, for example https://host/dav/skerry/"
            return false
        }
        storeWebDAVDestination(url: url, username: username, password: password)
        webDAVStatus = nil
        Task { await refreshWebDAVSnapshots() }
        return true
    }

    /// Removes the WebDAV destination from the keychain, legacy traces included.
    func removeWebDAVDestination() {
        KeychainVault.deleteSecret(account: Self.webDAVDestinationAccount)
        UserDefaults.standard.removeObject(forKey: Self.webDAVURLKey)
        UserDefaults.standard.removeObject(forKey: Self.webDAVUserKey)
        KeychainVault.deleteSecret(account: Self.webDAVPasswordAccount)
        webDAVConfig = nil
        webDAVSnapshots = []
        webDAVStatus = nil
    }

    /// Tests the WebDAV connection and reports the result on the settings screen.
    func testWebDAVConnection() {
        guard let config = webDAVConfig else { return }
        guard PlusStore.shared.isUnlocked(.remoteBackup) else {
            paywallFeature = .remoteBackup
            return
        }
        webDAVStatus = "Testing..."
        Task {
            do {
                try await WebDAVClient(config: config).check()
                webDAVStatus = "Connected."
            } catch {
                webDAVStatus = "Could not connect: \(error.localizedDescription)"
            }
        }
    }

    /// Uploads a fresh encrypted snapshot to WebDAV, pruning old ones. Always encrypted, so a
    /// remote server never receives anything but ciphertext.
    private func backUpToWebDAV(_ config: WebDAVClient.Config) async {
        guard let store else { return }
        guard hasEncryptionPassphrase else {
            errorMessage = "Set a passphrase first. WebDAV backups are always encrypted."
            return
        }
        if vaultPassphrase == nil { unlockVault() }
        guard let passphrase = vaultPassphrase else {
            errorMessage = "Unlock to back up to WebDAV."
            return
        }
        do {
            let data = try EncryptedBackup.sealedData(of: store.root, passphrase: passphrase)
            let client = WebDAVClient(config: config)
            let container = EncryptedBackup.containerName
            try await client.makeCollection(container)
            let file = EncryptedBackup.name(for: Date()) + "." + EncryptedBackup.fileExtension
            try await client.upload(data, to: "\(container)/\(file)")
            try await pruneWebDAV(client)
            await refreshWebDAVSnapshots()
        } catch {
            errorMessage = "WebDAV backup failed: \(error.localizedDescription)"
        }
    }

    /// Downloads and decrypts a WebDAV snapshot into the library.
    func restoreWebDAV(_ snapshot: RemoteSnapshot) {
        guard let store, let config = webDAVConfig else { return }
        guard PlusStore.shared.isUnlocked(.remoteBackup) else {
            paywallFeature = .remoteBackup
            return
        }
        if vaultPassphrase == nil { unlockVault() }
        guard let passphrase = vaultPassphrase else {
            errorMessage = "Unlock to restore a WebDAV backup."
            return
        }
        Task {
            do {
                let path = "\(EncryptedBackup.containerName)/\(snapshot.name)"
                let data = try await WebDAVClient(config: config).download(path)
                try EncryptedBackup.restore(from: data, into: store.root, passphrase: passphrase)
                reloadLibrary()
            } catch {
                errorMessage = "WebDAV restore failed: \(error.localizedDescription)"
            }
        }
    }

    /// Refreshes the WebDAV snapshot list from the server.
    func refreshWebDAVSnapshots() async {
        guard let config = webDAVConfig, PlusStore.shared.isUnlocked(.remoteBackup) else {
            webDAVSnapshots = []
            return
        }
        do {
            let entries = try await WebDAVClient(config: config).list(EncryptedBackup.containerName)
            webDAVSnapshots = remoteSnapshots(from: entries)
        } catch {
            // A missing collection just means no backups yet; leave the list empty.
            webDAVSnapshots = []
        }
    }

    /// Deletes WebDAV snapshots beyond the keep count.
    private func pruneWebDAV(_ client: WebDAVClient) async throws {
        let entries = try await client.list(EncryptedBackup.containerName)
        let snapshots = remoteSnapshots(from: entries)
        guard snapshots.count > Self.backupsToKeep else { return }
        for snapshot in snapshots.dropFirst(Self.backupsToKeep) {
            try? await client.delete("\(EncryptedBackup.containerName)/\(snapshot.name)")
        }
    }

    /// Turns WebDAV listing entries into dated snapshots, most recent first.
    private func remoteSnapshots(from entries: [WebDAVClient.Entry]) -> [RemoteSnapshot] {
        entries
            .filter { !$0.isCollection && $0.name.hasSuffix("." + EncryptedBackup.fileExtension) }
            .compactMap { entry in
                EncryptedBackup.date(fromFileName: entry.name).map {
                    RemoteSnapshot(name: entry.name, date: $0)
                }
            }
            .sorted { $0.date > $1.date }
    }

    /// StoredS3Destination is the keychain-serialized S3 connection.
    private struct StoredS3Destination: Codable {
        /// Endpoint URL string.
        var endpoint: String
        /// Signing region.
        var region: String
        /// Bucket name.
        var bucket: String
        /// Access key id.
        var accessKey: String
        /// Secret access key.
        var secret: String
    }

    /// Loads a saved S3 destination from its keychain item and lists its snapshots,
    /// after migrating anything an earlier build left in UserDefaults.
    private func loadS3Config() {
        if let json = KeychainVault.fetchSecret(account: Self.s3DestinationAccount),
            let stored = try? JSONDecoder().decode(
                StoredS3Destination.self, from: Data(json.utf8)
            ),
            let url = URL(string: stored.endpoint) {
            s3Config = S3Client.Config(
                endpoint: url, region: stored.region.isEmpty ? "us-east-1" : stored.region,
                bucket: stored.bucket, accessKeyID: stored.accessKey,
                secretAccessKey: stored.secret
            )
            Task { await refreshS3Snapshots() }
            return
        }
        migrateLegacyS3Storage()
    }

    /// Moves a destination saved by earlier builds, endpoint and keys in UserDefaults and
    /// the secret in its own keychain item, into the single keychain item, then wipes
    /// every legacy trace so nothing about the bucket remains in a plist.
    private func migrateLegacyS3Storage() {
        let defaults = UserDefaults.standard
        defer {
            for key in [
                Self.s3EndpointKey, Self.s3RegionKey, Self.s3BucketKey, Self.s3AccessKeyKey,
            ] {
                defaults.removeObject(forKey: key)
            }
            KeychainVault.deleteSecret(account: Self.s3SecretAccount)
        }
        guard let endpoint = defaults.string(forKey: Self.s3EndpointKey),
            let url = URL(string: endpoint),
            let bucket = defaults.string(forKey: Self.s3BucketKey),
            let accessKey = defaults.string(forKey: Self.s3AccessKeyKey),
            let secret = KeychainVault.fetchSecret(account: Self.s3SecretAccount)
        else {
            s3Config = nil
            return
        }
        let region = defaults.string(forKey: Self.s3RegionKey) ?? ""
        storeS3Destination(
            url: url, region: region, bucket: bucket, accessKey: accessKey, secret: secret
        )
        Task { await refreshS3Snapshots() }
    }

    /// Persists the S3 destination as one keychain item and adopts it in memory.
    private func storeS3Destination(
        url: URL, region: String, bucket: String, accessKey: String, secret: String
    ) {
        let stored = StoredS3Destination(
            endpoint: url.absoluteString, region: region, bucket: bucket,
            accessKey: accessKey, secret: secret
        )
        if let data = try? JSONEncoder().encode(stored) {
            KeychainVault.storeSecret(
                String(decoding: data, as: UTF8.self), account: Self.s3DestinationAccount
            )
        }
        s3Config = S3Client.Config(
            endpoint: url, region: region.isEmpty ? "us-east-1" : region,
            bucket: bucket, accessKeyID: accessKey, secretAccessKey: secret
        )
    }

    /// Configures an S3-compatible destination and lists its snapshots. Returns whether
    /// the destination was accepted, so the form knows when to clear its fields.
    @discardableResult
    func setS3Destination(
        endpoint: String, region: String, bucket: String, accessKey: String, secret: String
    ) -> Bool {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespaces)
        let trimmedBucket = bucket.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmedEndpoint), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", url.host() != nil,
            !trimmedBucket.isEmpty, !accessKey.isEmpty, !secret.isEmpty
        else {
            s3Status = "Enter the endpoint URL, bucket, and both keys."
            return false
        }
        storeS3Destination(
            url: url, region: region.trimmingCharacters(in: .whitespaces),
            bucket: trimmedBucket, accessKey: accessKey, secret: secret
        )
        s3Status = nil
        Task { await refreshS3Snapshots() }
        return true
    }

    /// Removes the S3 destination from the keychain, legacy traces included.
    func removeS3Destination() {
        KeychainVault.deleteSecret(account: Self.s3DestinationAccount)
        let defaults = UserDefaults.standard
        for key in [Self.s3EndpointKey, Self.s3RegionKey, Self.s3BucketKey, Self.s3AccessKeyKey] {
            defaults.removeObject(forKey: key)
        }
        KeychainVault.deleteSecret(account: Self.s3SecretAccount)
        s3Config = nil
        s3Snapshots = []
        s3Status = nil
    }

    /// Tests the S3 connection and reports the result on the settings screen.
    func testS3Connection() {
        guard let config = s3Config else { return }
        guard PlusStore.shared.isUnlocked(.remoteBackup) else {
            paywallFeature = .remoteBackup
            return
        }
        s3Status = "Testing..."
        Task {
            do {
                try await S3Client(config: config).check()
                s3Status = "Connected."
            } catch {
                s3Status = "Could not connect: \(error.localizedDescription)"
            }
        }
    }

    /// Uploads a fresh encrypted snapshot to S3, pruning old ones. Always encrypted.
    private func backUpToS3(_ config: S3Client.Config) async {
        guard let store else { return }
        guard hasEncryptionPassphrase else {
            errorMessage = "Set a passphrase first. Cloud backups are always encrypted."
            return
        }
        if vaultPassphrase == nil { unlockVault() }
        guard let passphrase = vaultPassphrase else {
            errorMessage = "Unlock to back up to the cloud."
            return
        }
        do {
            let data = try EncryptedBackup.sealedData(of: store.root, passphrase: passphrase)
            let client = S3Client(config: config)
            let file = EncryptedBackup.name(for: Date()) + "." + EncryptedBackup.fileExtension
            try await client.putObject(key: Self.s3Prefix + file, data: data)
            try await pruneS3(client)
            await refreshS3Snapshots()
        } catch {
            errorMessage = "Cloud backup failed: \(error.localizedDescription)"
        }
    }

    /// Downloads and decrypts an S3 snapshot into the library.
    func restoreS3(_ snapshot: RemoteSnapshot) {
        guard let store, let config = s3Config else { return }
        guard PlusStore.shared.isUnlocked(.remoteBackup) else {
            paywallFeature = .remoteBackup
            return
        }
        if vaultPassphrase == nil { unlockVault() }
        guard let passphrase = vaultPassphrase else {
            errorMessage = "Unlock to restore a cloud backup."
            return
        }
        Task {
            do {
                let data = try await S3Client(config: config).getObject(key: snapshot.name)
                try EncryptedBackup.restore(from: data, into: store.root, passphrase: passphrase)
                reloadLibrary()
            } catch {
                errorMessage = "Cloud restore failed: \(error.localizedDescription)"
            }
        }
    }

    /// Refreshes the S3 snapshot list from the bucket.
    func refreshS3Snapshots() async {
        guard let config = s3Config, PlusStore.shared.isUnlocked(.remoteBackup) else {
            s3Snapshots = []
            return
        }
        do {
            let keys = try await S3Client(config: config).listObjects(prefix: Self.s3Prefix)
            s3Snapshots = s3Snapshots(from: keys)
        } catch {
            s3Snapshots = []
        }
    }

    /// Deletes S3 snapshots beyond the keep count.
    private func pruneS3(_ client: S3Client) async throws {
        let keys = try await client.listObjects(prefix: Self.s3Prefix)
        let snapshots = s3Snapshots(from: keys)
        guard snapshots.count > Self.backupsToKeep else { return }
        for snapshot in snapshots.dropFirst(Self.backupsToKeep) {
            try? await client.deleteObject(key: snapshot.name)
        }
    }

    /// Turns S3 object keys into dated snapshots, most recent first.
    private func s3Snapshots(from keys: [String]) -> [RemoteSnapshot] {
        keys
            .filter { $0.hasSuffix("." + EncryptedBackup.fileExtension) }
            .compactMap { key in
                let file = (key as NSString).lastPathComponent
                return EncryptedBackup.date(fromFileName: file).map {
                    RemoteSnapshot(name: key, date: $0)
                }
            }
            .sorted { $0.date > $1.date }
    }

    /// The remote for the current sync mode, nil while unconfigured. The decoy session
    /// never syncs, so nothing on the wire betrays which library is open.
    private func syncRemote() -> (any SyncRemote)? {
        guard !isDecoySession else { return nil }
        switch syncMode {
        case .off:
            return nil
        case .folder:
            guard let backupDestination else { return nil }
            return FolderSyncRemote(base: backupDestination)
        case .webdav:
            guard let config = webDAVConfig else { return nil }
            return WebDAVSyncRemote(config: config)
        case .s3:
            guard let config = s3Config else { return nil }
            return S3SyncRemote(config: config)
        }
    }

    /// Starts a sync pass now, prompting to unlock when the vault is closed.
    func syncNow() {
        guard PlusStore.shared.isUnlocked(.sync) else {
            paywallFeature = .sync
            return
        }
        Task { await runSync(manual: true) }
    }

    /// Syncs quietly when a target is set and the vault is already unlocked, so lifecycle
    /// triggers never throw a Face ID prompt at an awkward moment. Also arms the periodic
    /// pull that keeps other devices' edits arriving while the app stays open.
    func autoSyncIfEnabled() {
        guard syncMode != .off, vaultMasterKey != nil else { return }
        guard PlusStore.shared.isUnlocked(.sync) else { return }
        startSyncFreshness()
        Task { await runSync(manual: false) }
    }

    /// One sync pass: adopts the remote keyfile on a fresh device, requires the unlocked
    /// master key, runs the engine, and reloads the library with whatever arrived.
    private func runSync(manual: Bool) async {
        guard !syncing, let store, let remote = syncRemote() else { return }
        // Last gate before the engine runs, covering the lifecycle and timer callers that
        // reach this without passing through syncNow.
        guard PlusStore.shared.isUnlocked(.sync) else {
            if manual { paywallFeature = .sync }
            return
        }
        let library = store.root
        let accessingFolder = syncMode == .folder
            ? backupDestination?.startAccessingSecurityScopedResource() ?? false
            : false
        defer {
            if accessingFolder { backupDestination?.stopAccessingSecurityScopedResource() }
        }

        // A device without a keyfile adopts the synced one first, so both sides share one
        // master key instead of this device minting its own.
        if vaultKeyfile == nil, let keyURL = vaultKeyfileURL,
            let remoteKeyfile = try? await SyncEngine.fetchKeyfile(remote: remote),
            (try? VaultKey.decode(remoteKeyfile)) != nil {
            lastLocalWrite = Date()
            try? remoteKeyfile.write(to: keyURL, options: .atomic)
            loadVaultKeyfile()
        }

        if vaultMasterKey == nil, manual { unlockVault() }
        guard let key = vaultMasterKey else {
            if manual {
                syncStatus = "Unlock to sync. Sync is always encrypted with your vault key."
                if canUnlockManually { unlockPromptVisible = true }
            }
            return
        }

        syncing = true
        syncStatus = "Syncing..."
        let keyfileData = vaultKeyfileURL.flatMap { try? Data(contentsOf: $0) }
        do {
            lastLocalWrite = Date()
            let result = try await SyncEngine.sync(
                library: library, remote: remote, key: key, keyfile: keyfileData,
                cipher: sealingCipher
            )
            lastLocalWrite = Date()
            syncStatus = syncSummary(result)
            if !result.isQuiet { reloadLibrary() }
        } catch SyncEngine.SyncError.wrongKey {
            syncStatus = "This storage holds a different vault's sync data. Use the same "
                + "passphrase and recovery vault on every device."
        } catch {
            syncStatus = "Sync failed: \(error.localizedDescription)"
        }
        syncing = false
    }

    /// One line summarizing a sync result for the settings screen.
    private func syncSummary(_ result: SyncEngine.Result) -> String {
        var parts: [String] = []
        if result.uploaded > 0 { parts.append("\(result.uploaded) sent") }
        if result.downloaded > 0 { parts.append("\(result.downloaded) received") }
        let removed = result.deletedLocal + result.deletedRemote
        if removed > 0 { parts.append("\(removed) removed") }
        if result.merged > 0 { parts.append("\(result.merged) merged") }
        if result.conflicts > 0 { parts.append("\(result.conflicts) conflict copies") }
        let time = Date().formatted(date: .omitted, time: .shortened)
        let detail = parts.isEmpty ? "everything already in sync" : parts.joined(separator: ", ")
        return "Synced at \(time): \(detail)."
    }

    /// Restores a trashed note to the library and reloads it into memory.
    func recoverNote(id: String) {
        guard let store else { return }
        do {
            lastLocalWrite = Date()
            let restored = try store.recoverFromTrash(id: id)
            let stored = try store.load(restored)
            notes.append(stored)
            try indexUpsert(stored)
            linkGraph.update(path: stored.path, body: stored.note.body)
            folders = (try? store.folderPaths()) ?? folders
            refreshTrash()
        } catch {
            errorMessage = "Could not recover note: \(error)"
        }
    }

    /// Permanently removes one note from the trash.
    func purgeNote(id: String) {
        guard let store else { return }
        try? store.purgeFromTrash(id: id)
        refreshTrash()
    }

    /// Permanently empties the trash.
    func emptyTrash() {
        guard let store else { return }
        for trashed in trashedNotes { try? store.purgeFromTrash(id: trashed.id) }
        refreshTrash()
    }

    /// Replaces the body of a note and schedules a debounced write. Notes still named
    /// Untitled take their file name from the first heading, the Bear title flow.
    func updateBody(_ body: String, for path: String) {
        guard let position = notes.firstIndex(where: { $0.path == path }) else { return }
        guard notes[position].note.body != body else { return }
        notes[position].note.body = body
        notes[position].note.metadata.updated = Date()
        linkGraph.update(path: path, body: body)
        scheduleSave(for: path)
        autoRenameFromTitle(path)
        registerActivity()
    }

    /// Renames an Untitled note file to match its first heading once one exists.
    private func autoRenameFromTitle(_ path: String) {
        guard let store, stem(path).hasPrefix("Untitled"),
            let stored = notes.first(where: { $0.path == path }),
            !stored.note.metadata.encrypted,
            let title = stored.note.displayTitle, !title.isEmpty
        else { return }
        var safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        safe = String(safe.prefix(60)).trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty, !safe.hasPrefix(".") else { return }
        let folder = path.contains("/")
            ? String(path[..<path.lastIndex(of: "/")!]) + "/"
            : ""
        let ext = (path as NSString).pathExtension
        let target = folder + safe + "." + ext
        guard target != path,
            !FileManager.default.fileExists(atPath: store.root.appendingPathComponent(target).path)
        else { return }
        movePath(path, to: target)
    }

    /// Mutates the metadata of a note and writes it immediately.
    ///
    /// Refused for an encrypted note while the vault is locked: its metadata lives inside the
    /// sealed envelope, so a change now would either leak a flag in the clear or be lost.
    func updateMetadata(for path: String, _ mutate: (inout Note.Metadata) -> Void) {
        guard let position = notes.firstIndex(where: { $0.path == path }) else { return }
        if notes[position].note.metadata.encrypted, !decryptedPaths.contains(path) {
            errorMessage = "Unlock the vault to change this encrypted note."
            return
        }
        mutate(&notes[position].note.metadata)
        notes[position].note.metadata.updated = Date()
        persist(path)
    }

    /// Runs the search index against the current search text, splitting out the
    /// structural @operators first.
    func runSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchHits = nil
            searchResults = [:]
            activeFilters = []
            searchReach = .scoped
            return
        }
        let query = SearchQuery.parse(trimmed)
        activeFilters = query.filters
        guard !query.text.isEmpty, let index else {
            searchHits = nil
            searchResults = [:]
            return
        }
        // Decrypted notes rank first from the in-memory session index, then disk hits. Each
        // hit's snippet and highlight ranges are kept so a result row shows the match.
        var hits: [String] = []
        var results: [String: NoteIndex.Hit] = [:]
        for hit in (try? sessionIndex?.search(query.text)) ?? [] {
            if results[hit.path] == nil {
                hits.append(hit.path)
                results[hit.path] = hit
            }
        }
        for hit in (try? index.search(query.text)) ?? [] where results[hit.path] == nil {
            hits.append(hit.path)
            results[hit.path] = hit
        }
        searchHits = hits
        searchResults = results
    }

    /// Whether a note satisfies one structural search filter.
    private func matches(_ filter: SearchQuery.Filter, _ stored: StoredNote) -> Bool {
        switch filter {
        case .todo: return NoteQueries.hasOpenTasks(stored.note.body)
        case .done: return NoteQueries.hasDoneTasks(stored.note.body)
        case .images: return NoteQueries.hasImages(stored.note.body)
        case .files: return NoteQueries.hasFileLinks(stored.note.body)
        case .pinned: return stored.note.metadata.pinned
        case .starred: return stored.note.metadata.starred
        case .encrypted: return stored.note.metadata.encrypted
        case .locked: return stored.note.metadata.locked
        case .tag(let tag):
            return SearchScope.tag(tag).contains(path: stored.path, tags: effectiveTags(stored))
        }
    }

    /// Schedules a write for a dirty note, coalescing rapid keystrokes.
    private func scheduleSave(for path: String) {
        pendingSaves[path]?.cancel()
        pendingSaves[path] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist(path)
            self?.pendingSaves[path] = nil
        }
    }

    /// Writes a note to disk and refreshes its index entry.
    ///
    /// An encrypted note is only ever written as ciphertext: sealed fresh when the vault holds
    /// its plaintext, or passed through when it is already a verified sealed envelope. Anything
    /// else, cleartext under an `encrypted` marker, is refused rather than written to disk.
    private func persist(_ path: String) {
        guard let store, let stored = notes.first(where: { $0.path == path }) else { return }
        do {
            var toWrite = stored.note
            if stored.note.metadata.encrypted {
                if decryptedPaths.contains(path) {
                    if let key = vaultMasterKey {
                        toWrite = try EncryptedNote.seal(stored.note, key: key, cipher: sealingCipher)
                    } else {
                        guard let passphrase = vaultPassphrase else {
                            errorMessage = "Cannot save an encrypted note while the vault is locked."
                            return
                        }
                        toWrite = try EncryptedNote.seal(stored.note, passphrase: passphrase)
                    }
                } else {
                    // Vault locked: the in-memory note must already be a sealed envelope. If it
                    // carries cleartext, refuse the write so a decrypted note never leaks.
                    let alreadySealed = stored.note.metadata.title == nil
                        && stored.note.metadata.tags.isEmpty
                        && NoteCrypto.isSealedBlob(stored.note.body)
                    guard alreadySealed else {
                        errorMessage = "Cannot save an encrypted note while the vault is locked."
                        return
                    }
                }
            }
            lastLocalWrite = Date()
            let written = try store.save(toWrite, to: stored.path)
            try indexUpsert(stored)
            try? versionStore?.record(path: stored.path, text: written)
            scheduleAutoSync()
            publishWidgetSnapshot()
        } catch {
            errorMessage = "Could not save note: \(error)"
        }
    }

    /// Versions recorded for a note, newest first.
    func versions(for path: String) -> [VersionStore.Version] {
        versionStore?.versions(for: path) ?? []
    }

    /// Body text of a version for preview. An envelope version is decrypted in memory when
    /// the vault is open; nil means the version cannot be shown right now.
    func versionPreview(_ version: VersionStore.Version) -> String? {
        guard let versionStore, let text = try? versionStore.text(of: version) else { return nil }
        let parsed = FrontMatter.parseNote(text)
        guard parsed.metadata.encrypted else { return parsed.body }
        if EncryptedNote.isVersion2(parsed), let key = vaultMasterKey {
            return (try? EncryptedNote.unseal(parsed, key: key))?.body
        }
        if let passphrase = vaultPassphrase {
            return (try? EncryptedNote.unseal(parsed, passphrase: passphrase))?.body
        }
        return nil
    }

    /// Restores a note to a recorded version, recording the current state first so the
    /// restore itself can be undone.
    ///
    /// A version recorded before a note was encrypted holds plaintext, so it is resealed in
    /// memory before anything reaches the disk; the note file only ever holds ciphertext.
    func restoreVersion(_ version: VersionStore.Version, for path: String) {
        guard let store, let versionStore,
            let position = notes.firstIndex(where: { $0.path == path }) else { return }
        do {
            let text = try versionStore.text(of: version)
            let parsed = FrontMatter.parseNote(text)
            let wasEncrypted = notes[position].note.metadata.encrypted
            let versionSealed = parsed.metadata.encrypted && NoteCrypto.isSealedBlob(parsed.body)
            var fileText = text
            if wasEncrypted, !versionSealed {
                var inner = parsed
                inner.metadata.id = notes[position].note.metadata.id
                inner.metadata.encrypted = true
                let envelope: Note
                if let key = vaultMasterKey {
                    envelope = try EncryptedNote.seal(inner, key: key, cipher: sealingCipher)
                } else if let passphrase = vaultPassphrase {
                    envelope = try EncryptedNote.seal(inner, passphrase: passphrase)
                } else {
                    errorMessage = "Unlock the vault to restore this version."
                    return
                }
                fileText = store.serializedText(envelope, for: path)
            }
            pendingSaves[path]?.cancel()
            pendingSaves[path] = nil
            let url = store.root.appendingPathComponent(path)
            if let current = try? String(contentsOf: url, encoding: .utf8) {
                try? versionStore.record(path: path, text: current, coalescing: false)
            }
            lastLocalWrite = Date()
            try fileText.write(to: url, atomically: true, encoding: .utf8)
            notes[position] = try store.load(path)
            decryptLoadedNotes()
            try? indexUpsert(notes[position])
        } catch {
            errorMessage = "Could not restore version: \(error.localizedDescription)"
        }
    }
}
