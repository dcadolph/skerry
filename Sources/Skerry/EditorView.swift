import QuickLook
import SkerryKit
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// EditorDetail adapts EditorView for stack navigation: it selects its note on arrival.
struct EditorDetail: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Path this pushed screen edits.
    let path: String

    var body: some View {
        EditorView(model: model)
            .onAppear { model.selectedPath = path }
            .onDisappear { model.discardIfEmpty(path) }
    }
}

/// ExportItem wraps an exported file URL so it can drive a share sheet.
struct ExportItem: Identifiable {
    /// Stable identity for sheet presentation.
    let id = UUID()
    /// The exported file to share.
    let url: URL
}

/// EditorView is the detail pane: a plain Markdown editor over the selected note.
struct EditorView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Appearance and editor preferences.
    @Environment(AppSettings.self) private var settings
    /// Exported file awaiting a share sheet, iOS only.
    @State private var exportItem: ExportItem?
    /// Whether the formatting guide is showing.
    @State private var showFormatHelp = false
    /// Whether the note info sheet is showing.
    @State private var showInfo = false
    /// Whether the version history sheet is showing.
    @State private var showHistory = false
    /// Whether the outline sheet is showing.
    @State private var showOutline = false
    /// Whether the media gallery sheet is showing.
    @State private var showGallery = false
    /// Path of the note being renamed from the editor; nil when the prompt is closed.
    @State private var renamePath: String?
    /// Name typed into the rename prompt.
    @State private var renameText = ""
    /// Whether the attach-file picker is showing.
    @State private var attachingFile = false
    /// Whether the translate sheet is showing.
    @State private var showTranslate = false
    /// Whether an on-device intelligence request is running.
    @State private var thinking = false
    /// Tag suggestions awaiting the user's pick; nil when the sheet is closed.
    @State private var tagSuggestions: [String]?
    #if os(iOS)
        /// Whether the sketch canvas is showing.
        @State private var showSketch = false
    #endif

    var body: some View {
        editorBody
            .sheet(isPresented: $showFormatHelp) {
                KeyboardHelpView()
            }
            .sheet(isPresented: $showInfo) {
                if let stored = model.selectedNote {
                    NoteInfoView(stored: stored)
                }
            }
            .sheet(isPresented: $showHistory) {
                if let stored = model.selectedNote {
                    VersionHistoryView(model: model, path: stored.path)
                }
            }
            .sheet(isPresented: $showOutline) {
                if let stored = model.selectedNote {
                    OutlineView(model: model, body_: stored.note.body)
                }
            }
            .sheet(isPresented: $showGallery) {
                if let stored = model.selectedNote {
                    GalleryView(model: model, path: stored.path)
                }
            }
        #if os(iOS)
            .sheet(item: $exportItem) { item in
                ShareSheet(url: item.url)
            }
            .sheet(isPresented: $showSketch) {
                if let stored = model.selectedNote {
                    SketchView { data in
                        model.attachSketch(data, to: stored.path)
                    }
                }
            }
        #endif
            .alert(
                "Rename Note",
                isPresented: Binding(
                    get: { renamePath != nil },
                    set: { if !$0 { renamePath = nil } }
                )
            ) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let renamePath { model.renameNote(renamePath, to: renameText) }
                    renamePath = nil
                }
                Button("Cancel", role: .cancel) { renamePath = nil }
            }
            .fileImporter(
                isPresented: $attachingFile,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result, let stored = model.selectedNote {
                    model.attachFiles(urls, to: stored.path)
                }
            }
            .sheet(isPresented: $showTranslate) {
                translateSheet
            }
            .confirmationDialog(
                "Add suggested tags?",
                isPresented: Binding(
                    get: { tagSuggestions != nil },
                    set: { if !$0 { tagSuggestions = nil } }
                ),
                titleVisibility: .visible
            ) {
                ForEach(tagSuggestions ?? [], id: \.self) { tag in
                    Button("#\(tag)") {
                        if let stored = model.selectedNote {
                            model.addTag(tag, to: stored.path)
                        }
                    }
                }
                Button("Add All") {
                    if let stored = model.selectedNote {
                        for tag in tagSuggestions ?? [] {
                            model.addTag(tag, to: stored.path)
                        }
                    }
                    tagSuggestions = nil
                }
                Button("Cancel", role: .cancel) { tagSuggestions = nil }
            }
    }

    /// The translate sheet, only reachable on systems with the Translation framework.
    @ViewBuilder
    private var translateSheet: some View {
        #if canImport(Translation)
            if #available(iOS 18.0, macOS 15.0, *), let stored = model.selectedNote {
                TranslateNoteView(body_: stored.note.body) { translated, replace in
                    if replace {
                        model.updateBody(translated, for: stored.path)
                    } else {
                        let separator = stored.note.body.hasSuffix("\n") ? "\n" : "\n\n"
                        model.updateBody(
                            stored.note.body + separator + "## Translation\n\n" + translated
                                + "\n",
                            for: stored.path
                        )
                    }
                }
            }
        #endif
    }

    /// Runs the on-device summary and appends it to the note.
    private func summarize(_ stored: StoredNote) {
        thinking = true
        Task {
            defer { thinking = false }
            do {
                let summary = try await NoteIntelligence.summarize(stored.note.body)
                let separator = stored.note.body.hasSuffix("\n") ? "\n" : "\n\n"
                model.updateBody(
                    stored.note.body + separator + "## Summary\n\n" + summary + "\n",
                    for: stored.path
                )
            } catch {
                model.errorMessage = "Could not summarize: \(error.localizedDescription)"
            }
        }
    }

    /// Asks the on-device model for tag suggestions.
    private func suggestTags(_ stored: StoredNote) {
        thinking = true
        Task {
            defer { thinking = false }
            do {
                let suggestions = try await NoteIntelligence.suggestTags(
                    for: stored.note.body, existing: model.effectiveTags(stored)
                )
                if suggestions.isEmpty {
                    model.errorMessage = "No new tags suggested."
                } else {
                    tagSuggestions = suggestions
                }
            } catch {
                model.errorMessage = "Could not suggest tags: \(error.localizedDescription)"
            }
        }
    }

    /// Exports the note to a format, then shares on iOS or saves on macOS.
    private func exportNote(_ stored: StoredNote, as format: NoteExporter.Format) {
        do {
            let url = try NoteExporter.makeFile(for: stored, format: format)
            #if os(iOS)
                exportItem = ExportItem(url: url)
            #else
                NoteExporter.saveOnMac(url)
            #endif
        } catch {
            model.errorMessage = "Could not export note: \(error)"
        }
    }

    @ViewBuilder
    private var editorBody: some View {
        if let stored = model.selectedNote, !model.isReadable(stored) {
            VStack(spacing: 14) {
                Image(systemName: stored.note.metadata.encrypted ? "lock.shield.fill" : "lock.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)
                Text(stored.note.metadata.encrypted ? "Encrypted Note" : "Locked Note")
                    .font(.title3.bold())
                Button("Unlock") {
                    if stored.note.metadata.encrypted { model.unlockVault() }
                    if stored.note.metadata.locked { model.requestUnlock(stored.path) }
                }
                .buttonStyle(.borderedProminent)
            }
            #if os(macOS)
                .navigationTitle("Locked")
            #else
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
            #endif
        } else if let stored = model.selectedNote {
            VStack(spacing: 0) {
                MarkdownTextView(
                    text: bodyBinding(for: stored.path),
                    onWikiLink: { model.followWikiLink($0, heading: $1) },
                    onPasteImage: { data, ext in
                        model.saveAttachment(data, fileExtension: ext, for: stored.path)
                    },
                    highlightsMarkdown: isMarkdown(stored.path),
                    onShowFormatHelp: { showFormatHelp = true },
                    styleToken: settings.styleToken &* 2 &+ (isMarkdown(stored.path) ? 0 : 1),
                    colorSchemeHint: settings.editorTheme.scheme.colorScheme
                        ?? settings.appearanceMode.colorScheme,
                    typewriter: settings.typewriterMode,
                    paragraphFocus: settings.paragraphFocus,
                    tagCompletions: { model.completionTags },
                    titleCompletions: { model.completionTitles },
                    headingCompletions: { model.headingCompletions(for: $0) },
                    inlineImageProvider: { link in
                        model.inlineImage(link: link, for: stored.path)
                    },
                    usesTextKit2: settings.usesTextKit2,
                    scrollToHeading: model.pendingHeading,
                    onHeadingResolved: { model.clearPendingHeading() }
                )
                // Flipping the engine swaps the whole platform view, never in place.
                .id(settings.usesTextKit2)
                .padding(.horizontal, model.focusMode ? 96 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                TagBar(model: model, path: stored.path)
                AttachmentStrip(model: model, path: stored.path)
                BacklinksBar(model: model, path: stored.path)
                if isMarkdown(stored.path), model.isReadable(stored) {
                    // Keyed by path so the count resets at once on a note switch, while
                    // edits within a note debounce.
                    EditorStatusBar(body_: stored.note.body)
                        .id(stored.path)
                }
            }
            #if os(macOS)
                .navigationTitle(stored.note.displayTitle ?? "Untitled")
            #else
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { editorToolbar(for: stored) }
        } else if model.store == nil {
            #if os(macOS)
                SkellyEmptyState(
                    title: "Welcome to Skerry",
                    message: "Open any folder and Skerry treats it as your notes library.",
                    actionTitle: "Open Folder…",
                    action: { model.libraryPickerPresented = true }
                )
            #else
                SkellyEmptyState(
                    title: "No Note Selected",
                    message: "Pick a note from the list or start a new one."
                )
            #endif
        } else if model.visibleNotes.isEmpty {
            // The list pane already shows the "Nothing Here Yet" prompt; keep the detail
            // side quiet so Skelly never appears twice at once.
            Color.clear
        } else {
            #if os(macOS)
                SkellyEmptyState(
                    title: "No Note Selected",
                    message: "Pick a note, press Cmd-N for a new one, or Cmd-K to jump anywhere."
                )
            #else
                SkellyEmptyState(
                    title: "No Note Selected",
                    message: "Pick a note from the list or start a new one."
                )
            #endif
        }
    }

    /// Whether a path is a Markdown note, which gets live syntax styling.
    private func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Binding that routes editor keystrokes through the model's debounced save.
    private func bodyBinding(for path: String) -> Binding<String> {
        Binding(
            get: { model.notes.first { $0.path == path }?.note.body ?? "" },
            set: { model.updateBody($0, for: path) }
        )
    }

    /// TagBar shows a note's merged tags as chips: front matter tags removable, inline
    /// body tags shown lighter since they live in the text itself.
    struct TagBar: View {
        /// Shared library state.
        var model: LibraryModel
        /// Path of the open note.
        let path: String
        /// Whether the add-tag prompt is showing.
        @State private var addingTag = false
        /// Tag typed into the prompt.
        @State private var newTag = ""

        var body: some View {
            let stored = model.notes.first { $0.path == path }
            let metadataTags = stored?.note.metadata.tags ?? []
            let all = stored.map { model.effectiveTags($0) } ?? []
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(all, id: \.self) { tag in
                        let inMetadata = metadataTags.contains {
                            $0.caseInsensitiveCompare(tag) == .orderedSame
                        }
                        let color = TagPalette.color(for: tag)
                        HStack(spacing: 4) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(tag)
                        }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(color.opacity(inMetadata ? 0.18 : 0.10), in: Capsule())
                            .foregroundStyle(inMetadata ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                            .contextMenu {
                                Button("Show Tagged Notes", systemImage: "number") {
                                    model.sidebarSelection = .tag(tag.lowercased())
                                }
                                if inMetadata {
                                    Button("Remove Tag", systemImage: "minus.circle", role: .destructive) {
                                        model.removeTag(tag, from: path)
                                    }
                                } else {
                                    Text("Typed in the note; edit the text to remove.")
                                }
                            }
                    }
                    Button {
                        newTag = ""
                        addingTag = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Add a tag")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.bar)
            .alert("Add Tag", isPresented: $addingTag) {
                TextField("tag or parent/child", text: $newTag)
                Button("Add") { model.addTag(newTag, to: path) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tags nest with a slash, like work/clients. You can also just type "
                    + "#tag anywhere in the note.")
            }
        }
    }

    /// AttachmentStrip shows thumbnails of images and chips for files the note links to.
    struct AttachmentStrip: View {
        /// Shared library state.
        var model: LibraryModel
        /// Path of the open note.
        let path: String
        /// Decrypted or plain file being previewed with Quick Look, iOS only.
        @State private var previewFile: URL?

        var body: some View {
            let images = model.imageAttachments(for: path)
            let files = model.fileReferences(for: path)
            if !images.isEmpty || !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images, id: \.path) { url in
                            thumbnail(for: url)
                        }
                        ForEach(files, id: \.url.path) { reference in
                            fileChip(for: reference.url)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(.bar)
                .quickLookPreview($previewFile)
            }
        }

        /// A tappable chip for a file attachment, opening it in a previewer. A sealed file
        /// shows a lock while the vault is closed.
        @ViewBuilder
        private func fileChip(for url: URL) -> some View {
            let sealed = url.pathExtension.lowercased() == "skbox"
            let name = sealed
                ? url.deletingPathExtension().lastPathComponent
                : url.lastPathComponent
            let openable = !sealed || model.vaultUnlocked
            Button {
                previewFile = model.previewableURL(for: url)
            } label: {
                Label(
                    name,
                    systemImage: openable
                        ? (model.isAudioAttachment(url) ? "waveform" : "doc")
                        : "lock.doc"
                )
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!openable)
            .help(name)
            .contextMenu {
                if openable, model.isAudioAttachment(url) {
                    Button("Transcribe on Device", systemImage: "text.quote") {
                        model.transcribeAttachment(url, into: path)
                    }
                }
                #if os(macOS)
                    if openable {
                        Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                            open(url)
                        }
                    }
                #endif
            }
        }

        /// One clickable thumbnail; opening uses the platform default viewer on macOS. Sealed
        /// images are decrypted for display, and show a lock placeholder when the vault is locked.
        @ViewBuilder
        private func thumbnail(for url: URL) -> some View {
            #if os(macOS)
                if let data = model.attachmentImageData(at: url), let image = NSImage(data: data) {
                    Button {
                        previewFile = model.previewableURL(for: url)
                    } label: {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(url.lastPathComponent)
                    .contextMenu {
                        Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                            open(url)
                        }
                    }
                } else {
                    lockedThumbnail
                }
            #else
                if let data = model.attachmentImageData(at: url), let image = UIImage(data: data) {
                    Button {
                        previewFile = model.previewableURL(for: url)
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                } else {
                    lockedThumbnail
                }
            #endif
        }

        /// Placeholder shown when a sealed image cannot be displayed because the vault is locked.
        private var lockedThumbnail: some View {
            Image(systemName: "lock.doc")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }

        #if os(macOS)
            /// Opens an attachment in the default viewer, decrypting a sealed file to a scratch
            /// file first so the viewer sees the content rather than ciphertext.
            private func open(_ url: URL) {
                guard let previewable = model.previewableURL(for: url) else { return }
                NSWorkspace.shared.open(previewable)
            }
        #endif
    }

    /// BacklinksBar lists the notes that wiki-link to the open note, click to jump.
    struct BacklinksBar: View {
        /// Shared library state.
        var model: LibraryModel
        /// Path of the open note.
        let path: String

        /// Unlinked mentions are a full-library body scan, so they refresh once per
        /// note selection rather than on every model change.
        @State private var mentions: [StoredNote] = []

        var body: some View {
            let backlinks = model.backlinks(to: path)
            ZStack {
                if !backlinks.isEmpty || !mentions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if !backlinks.isEmpty {
                                Label("Linked from", systemImage: "arrow.turn.up.left")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(backlinks, id: \.path) { linking in
                                    chip(for: linking, dimmed: false)
                                }
                            }
                            if !mentions.isEmpty {
                                Label("Mentioned in", systemImage: "text.quote")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                ForEach(mentions, id: \.path) { mentioning in
                                    chip(for: mentioning, dimmed: true)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .background(.bar)
                }
            }
            .task(id: path) {
                mentions = model.unlinkedMentions(of: path)
            }
        }

        /// One tappable note chip; mentions render dimmer than real links.
        private func chip(for stored: StoredNote, dimmed: Bool) -> some View {
            Button {
                model.open(stored.path)
            } label: {
                Text(stored.note.displayTitle ?? model.stem(stored.path))
                    .font(.caption)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        .quaternary.opacity(dimmed ? 0.6 : 1), in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
    }

    /// Star, pin, and archive toggles for the open note.
    @ToolbarContentBuilder
    private func editorToolbar(for stored: StoredNote) -> some ToolbarContent {
        ToolbarItemGroup {
            Button(
                "Star",
                systemImage: stored.note.metadata.starred ? "star.fill" : "star"
            ) {
                model.updateMetadata(for: stored.path) { $0.starred.toggle() }
            }
            .help(stored.note.metadata.starred ? "Unstar" : "Star")
            Button(
                "Pin",
                systemImage: stored.note.metadata.pinned ? "pin.fill" : "pin"
            ) {
                model.updateMetadata(for: stored.path) { $0.pinned.toggle() }
            }
            .help(stored.note.metadata.pinned ? "Unpin" : "Pin")
            Button(
                "Archive",
                systemImage: stored.note.metadata.archived
                    ? "archivebox.fill" : "archivebox"
            ) {
                model.updateMetadata(for: stored.path) { $0.archived.toggle() }
            }
            .help(stored.note.metadata.archived ? "Unarchive" : "Archive")
            Button("Attach File", systemImage: "paperclip") {
                attachingFile = true
            }
            .help("Attach a file to this note")
            #if os(iOS)
                Button("Sketch", systemImage: "pencil.and.outline") {
                    showSketch = true
                }
                .help("Draw a sketch into this note")
            #endif
            Menu {
                Section("Export") {
                    ForEach(NoteExporter.Format.exportable) { format in
                        Button(format.label) { exportNote(stored, as: format) }
                    }
                }
                Section("Copy") {
                    Button("Copy Markdown") { NoteExporter.copy(stored, as: .markdown) }
                    Button("Copy HTML") { NoteExporter.copy(stored, as: .html) }
                    Button("Copy Plain Text") { NoteExporter.copy(stored, as: .text) }
                    Button("Copy Link to Note") { model.copyNoteLink(stored.path) }
                }
                Button("Print", systemImage: "printer") { NoteExporter.printNote(stored) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export, copy, or print this note")
            Menu {
                if isMarkdown(stored.path), model.isReadable(stored) {
                    Button("Outline", systemImage: "list.bullet.indent") { showOutline = true }
                }
                if !model.imageAttachments(for: stored.path).isEmpty {
                    Button("Media Gallery", systemImage: "photo.on.rectangle.angled") {
                        showGallery = true
                    }
                }
                Button("Note Info", systemImage: "info.circle") { showInfo = true }
                Button("Version History", systemImage: "clock.arrow.circlepath") {
                    if PlusStore.shared.isUnlocked(.versionHistory) {
                        showHistory = true
                    } else {
                        model.paywallFeature = .versionHistory
                    }
                }
                Button("Fetch Link Titles", systemImage: "link.badge.plus") {
                    model.fetchLinkTitles(for: stored.path)
                }
                .help("Fetches each bare link's page title; the app's only network use")
                Section("On-Device Magic") {
                    if #available(iOS 18.0, macOS 15.0, *) {
                        Button("Translate Note...", systemImage: "character.bubble") {
                            showTranslate = true
                        }
                    }
                    if NoteIntelligence.isAvailable {
                        Button("Summarize", systemImage: "text.append") {
                            summarize(stored)
                        }
                        .disabled(thinking)
                        Button("Suggest Tags", systemImage: "number.square") {
                            suggestTags(stored)
                        }
                        .disabled(thinking)
                    }
                }
                if !stored.note.metadata.encrypted,
                    ["md", "markdown", "txt"].contains(
                        (stored.path as NSString).pathExtension.lowercased()
                    ) {
                    Picker("Format", selection: Binding(
                        get: {
                            (stored.path as NSString).pathExtension.lowercased() == "txt"
                                ? "txt" : "md"
                        },
                        set: { model.changeFormat(stored.path, to: $0) }
                    )) {
                        Text("Markdown").tag("md")
                        Text("Plain Text").tag("txt")
                    }
                }
                Divider()
                Button(
                    stored.note.metadata.locked ? "Remove Lock" : "Lock Note",
                    systemImage: stored.note.metadata.locked ? "lock.open" : "lock"
                ) {
                    if stored.note.metadata.locked {
                        model.removeLock(stored.path)
                    } else {
                        model.lockNote(stored.path)
                    }
                }
                Button(
                    stored.note.metadata.encrypted ? "Remove Encryption" : "Encrypt Note",
                    systemImage: "lock.shield"
                ) {
                    if stored.note.metadata.encrypted {
                        model.decryptNote(stored.path)
                    } else {
                        model.encryptNote(stored.path)
                    }
                }
                Divider()
                Button("Rename...", systemImage: "pencil") {
                    renameText = model.stem(stored.path)
                    renamePath = stored.path
                }
                if !stored.note.metadata.encrypted, !stored.note.metadata.locked {
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        model.duplicateNote(stored.path)
                    }
                }
                Menu {
                    Button("Library Root") { model.moveNote(stored.path, toFolder: "") }
                    ForEach(model.folders, id: \.self) { folder in
                        Button(folder) { model.moveNote(stored.path, toFolder: folder) }
                    }
                } label: {
                    Label("Move To", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    model.trashNote(stored.path)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .help("Note actions")
        }
    }
}

/// EditorStatusBar is the slim readout under the editor: a live word count and reading
/// time, the kind of quiet writing feedback iA Writer and Ulysses show and Bear does not.
struct EditorStatusBar: View {
    /// Body text the counts describe.
    let body_: String
    /// Last computed statistics, refreshed off the typing path so a large note does not
    /// rescan its whole body on every keystroke.
    @State private var stats = NoteStats(body: "")
    /// Whether a first count has landed, so a freshly opened note shows its size at once
    /// while later edits debounce.
    @State private var counted = false

    var body: some View {
        HStack(spacing: Style.Space.xs) {
            Text("\(stats.words) words")
            if stats.words > 0 {
                Text("·")
                Text("\(stats.readingMinutes) min read")
            }
            Spacer()
            Text("\(stats.characters) characters")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Style.Space.m)
        .padding(.vertical, Style.Space.xs)
        .background(.bar)
        .task(id: body_) {
            // A keystroke cancels the pending recount, so the whole-body scan runs once
            // typing settles rather than on every character. The first count is immediate.
            if counted {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            stats = NoteStats(body: body_)
            counted = true
        }
    }
}

/// NoteInfoView shows word count, reading time, and dates for a note.
struct NoteInfoView: View {
    /// Note being described.
    let stored: StoredNote
    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let stats = NoteStats(body: stored.note.body)
        NavigationStack {
            Form {
                Section("Content") {
                    LabeledContent("Words", value: "\(stats.words)")
                    LabeledContent("Characters", value: "\(stats.characters)")
                    LabeledContent(
                        "Reading time",
                        value: stats.words == 0 ? "—" : "\(stats.readingMinutes) min"
                    )
                }
                Section("File") {
                    LabeledContent("Format", value: formatName)
                    if stored.created > .distantPast {
                        LabeledContent("Created", value: dateText(stored.created))
                    }
                    if stored.updated > .distantPast {
                        LabeledContent("Edited", value: dateText(stored.updated))
                    }
                }
            }
            .navigationTitle(stored.note.displayTitle ?? "Note Info")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button("Done") { dismiss() } }
        }
        #if os(macOS)
            .frame(minWidth: 340, minHeight: 320)
        #endif
    }

    /// Human name for the note's file format.
    private var formatName: String {
        switch (stored.path as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "Markdown"
        case "txt": return "Plain Text"
        case "html": return "HTML"
        default: return "Text"
        }
    }

    /// Formats a date for the info sheet.
    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// OutlineView lists a note's headings so the reader can jump straight to one, the
/// table-of-contents a long note wants. Tapping a heading scrolls the editor to it.
struct OutlineView: View {
    /// Shared library state, the target of the jump.
    var model: LibraryModel
    /// Body the headings are read from.
    let body_: String
    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let headings = MarkdownFolding.headings(in: body_).filter { !$0.text.isEmpty }
        NavigationStack {
            Group {
                if headings.isEmpty {
                    ContentUnavailableView(
                        "No Headings", systemImage: "number",
                        description: Text("Add headings to build an outline.")
                    )
                } else {
                    List(headings, id: \.line.location) { heading in
                        Button {
                            model.scroll(toHeading: heading.text)
                            dismiss()
                        } label: {
                            Text(heading.text)
                                .font(heading.level <= 1 ? .body.weight(.semibold) : .body)
                                .foregroundStyle(heading.level <= 2 ? .primary : .secondary)
                                .lineLimit(1)
                                .padding(.leading, CGFloat(heading.level - 1) * 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Outline")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button("Done") { dismiss() } }
        }
        #if os(macOS)
            .frame(minWidth: 320, minHeight: 380)
        #endif
    }
}

/// GalleryView is a grid of a note's image attachments, larger than the strip's chips, so a
/// note full of pictures can be browsed at a glance. Tapping one opens it in Quick Look.
struct GalleryView: View {
    /// Shared library state.
    var model: LibraryModel
    /// Path of the note whose images are shown.
    let path: String
    /// Image being previewed with Quick Look.
    @State private var previewFile: URL?
    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss

    /// Grid columns sized to fit as many thumbnails as the width allows.
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 10)]

    var body: some View {
        let images = model.imageAttachments(for: path)
        NavigationStack {
            Group {
                if images.isEmpty {
                    ContentUnavailableView(
                        "No Images", systemImage: "photo.on.rectangle",
                        description: Text("Images attached to this note appear here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(images, id: \.path) { url in
                                tile(for: url)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("Media")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button("Done") { dismiss() } }
            .quickLookPreview($previewFile)
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    /// One gallery tile: a square-cropped thumbnail that opens Quick Look, or a lock
    /// placeholder when a sealed image cannot be shown because the vault is closed.
    @ViewBuilder
    private func tile(for url: URL) -> some View {
        if let data = model.attachmentImageData(at: url), let image = PlatformImage(data: data) {
            Button {
                previewFile = model.previewableURL(for: url)
            } label: {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        #if os(macOS)
                            Image(nsImage: image).resizable().scaledToFill()
                        #else
                            Image(uiImage: image).resizable().scaledToFill()
                        #endif
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help(url.lastPathComponent)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay(Image(systemName: "lock.doc").foregroundStyle(.secondary))
        }
    }
}
