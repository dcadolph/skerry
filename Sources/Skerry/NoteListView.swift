import SkerryKit
import SwiftUI

/// NoteListView is the middle pane: notes under the current sidebar selection and search.
struct NoteListView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Appearance preferences, for the list and gallery layout choice.
    @Environment(AppSettings.self) private var settings
    /// Path of the note being renamed; nil when the prompt is closed.
    @State private var renamePath: String?
    /// Name typed into the rename prompt.
    @State private var renameText = ""
    /// Whether the save-search prompt is showing.
    @State private var savingSmartFolder = false
    /// Name typed into the save-search prompt.
    @State private var smartFolderName = ""

    var body: some View {
        content
        #if os(iOS)
            .toolbar { filterToolbar }
        #endif
    }

    /// List body for the current selection: trash gets its own view, everything else the
    /// standard note list. The filter menu lives outside this switch so no selection, trash
    /// included, ever hides the only way back to another view on iPhone.
    @ViewBuilder
    private var content: some View {
        if model.sidebarSelection == .trash {
            TrashListView(model: model)
        } else {
            noteList
        }
    }

    /// The normal note list for every non-trash selection.
    private var noteList: some View {
        platformList
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                conflictBanner
                scopeBar
                encryptedSearchBanner
            }
        }
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
        .alert("Save Search", isPresented: $savingSmartFolder) {
            TextField("Name", text: $smartFolderName)
            Button("Save") { model.addSmartFolder(named: smartFolderName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current search, operators included, as a smart folder in the "
                + "sidebar.")
        }
        .overlay { emptyState }
        .toolbar { listToolbar }
        .navigationTitle(title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
        #endif
    }

    /// A tap-to-review banner shown while sync conflict copies await resolution.
    @ViewBuilder
    private var conflictBanner: some View {
        let count = model.conflictPairs.count
        if count > 0 {
            Button {
                model.conflictReviewVisible = true
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    Text(count == 1
                        ? "1 sync conflict to review"
                        : "\(count) sync conflicts to review")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.15))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// A segmented control to widen an in-folder or in-tag search to the whole library.
    /// Shown only while a search is active inside a folder or tag, where there is a narrower
    /// container than the whole library to choose between.
    @ViewBuilder
    private var scopeBar: some View {
        if let label = model.scopedSearchLabel {
            Picker("Search scope", selection: $model.searchReach) {
                Text(label).tag(SearchReach.scoped)
                Text("All Notes").tag(SearchReach.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// A hint shown while searching with the vault locked: encrypted notes are sealed and
    /// absent from the results until the vault is open. Tapping unlocks, which decrypts them
    /// into the session index so the same search then reaches them.
    @ViewBuilder
    private var encryptedSearchBanner: some View {
        if model.encryptedSearchLocked {
            Button {
                model.unlockVault()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                    Text(model.encryptedNoteCount == 1
                        ? "1 encrypted note isn't searched while locked"
                        : "\(model.encryptedNoteCount) encrypted notes aren't searched while locked")
                    Spacer()
                    Text("Unlock").fontWeight(.semibold)
                    Image(systemName: "chevron.right").font(.caption)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.tint.opacity(0.12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Selection-driven list on macOS, plain navigation list on iOS where selection
    /// semantics would swallow row taps. Gallery cards replace both when chosen.
    @ViewBuilder
    private var platformList: some View {
        if settings.galleryLayout {
            galleryGrid
        } else {
            #if os(iOS)
                List { noteRows }
            #else
                List(selection: $model.selectedPath) { noteRows }
            #endif
        }
    }

    /// Adaptive grid of note cards, the gallery alternative to rows.
    private var galleryGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)],
                spacing: 12
            ) {
                ForEach(model.visibleNotes, id: \.path) { stored in
                    galleryCard(for: stored)
                        .draggable(stored.path)
                        .contextMenu { noteMenu(for: stored) }
                }
            }
            .padding(12)
        }
    }

    /// Tappable card; push navigation on iOS, selection on macOS.
    @ViewBuilder
    private func galleryCard(for stored: StoredNote) -> some View {
        #if os(iOS)
            NavigationLink(value: stored.path) {
                NoteCard(stored: stored, searchHit: model.searchResults[stored.path])
            }
            .buttonStyle(.plain)
        #else
            Button {
                model.open(stored.path)
            } label: {
                NoteCard(
                    stored: stored, selected: model.selectedPath == stored.path,
                    searchHit: model.searchResults[stored.path]
                )
            }
            .buttonStyle(.plain)
        #endif
    }

    /// Rows for every visible note with their swipe actions and context menus.
    private var noteRows: some View {
            ForEach(model.visibleNotes, id: \.path) { stored in
                noteRow(for: stored)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            model.updateMetadata(for: stored.path) { $0.starred.toggle() }
                        } label: {
                            Label(
                                stored.note.metadata.starred ? "Unstar" : "Star",
                                systemImage: stored.note.metadata.starred ? "star.slash" : "star.fill"
                            )
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.trashNote(stored.path)
                        } label: {
                            Label("Trash", systemImage: "trash")
                        }
                        Button {
                            model.updateMetadata(for: stored.path) { $0.archived.toggle() }
                        } label: {
                            Label(
                                stored.note.metadata.archived ? "Unarchive" : "Archive",
                                systemImage: "archivebox"
                            )
                        }
                        .tint(.indigo)
                    }
                    .contextMenu { noteMenu(for: stored) }
            }
    }

    /// Context menu for a note, shared by list rows and gallery cards.
    @ViewBuilder
    private func noteMenu(for stored: StoredNote) -> some View {
        Button(stored.note.metadata.starred ? "Unstar" : "Star") {
            model.updateMetadata(for: stored.path) { $0.starred.toggle() }
        }
        Button(stored.note.metadata.pinned ? "Unpin" : "Pin") {
            model.updateMetadata(for: stored.path) { $0.pinned.toggle() }
        }
        Button(stored.note.metadata.archived ? "Unarchive" : "Archive") {
            model.updateMetadata(for: stored.path) { $0.archived.toggle() }
        }
        Button(stored.note.metadata.locked ? "Remove Lock" : "Lock Note") {
            if stored.note.metadata.locked {
                model.removeLock(stored.path)
            } else {
                model.lockNote(stored.path)
            }
        }
        Button(stored.note.metadata.encrypted ? "Remove Encryption" : "Encrypt Note") {
            if stored.note.metadata.encrypted {
                model.decryptNote(stored.path)
            } else {
                model.encryptNote(stored.path)
            }
        }
        Divider()
        Button("Rename...") {
            renameText = model.stem(stored.path)
            renamePath = stored.path
        }
        Menu("Move To") {
            Button("Library Root") {
                model.moveNote(stored.path, toFolder: "")
            }
            ForEach(model.folders, id: \.self) { folder in
                Button(folder) {
                    model.moveNote(stored.path, toFolder: folder)
                }
            }
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            model.trashNote(stored.path)
        }
    }

    /// Placeholder art when the library is missing or the current view is empty.
    @ViewBuilder
    private var emptyState: some View {
        if model.store == nil {
            #if os(macOS)
                // The detail pane carries the welcome hero, so the list stays quiet and
                // Skelly appears only once on a fresh launch.
                EmptyView()
            #else
                SkellyEmptyState(
                    title: "No Library Open",
                    message: "Open any folder and Skerry treats it as your notes library.",
                    actionTitle: "Open Folder…",
                    action: { model.libraryPickerPresented = true }
                )
            #endif
        } else if model.visibleNotes.isEmpty {
            #if os(macOS)
                SkellyEmptyState(
                    title: "Nothing Here Yet",
                    message: "Press Cmd-N and give Skelly some company on the skerry."
                )
            #else
                SkellyEmptyState(
                    title: "Nothing Here Yet",
                    message: "Tap the compose button and give Skelly some company on the skerry."
                )
            #endif
        }
    }

    #if os(iOS)
        /// View-switching filter menu, attached to every selection so no screen, trash
        /// included, strands the user without a way back.
        @ToolbarContentBuilder
        private var filterToolbar: some ToolbarContent {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("All Notes", systemImage: "note.text") {
                        model.sidebarSelection = .all
                    }
                    Button("Starred", systemImage: "star") {
                        model.sidebarSelection = .starred
                    }
                    Button("Tasks", systemImage: "checklist") {
                        model.sidebarSelection = .todo
                    }
                    Button("Archived", systemImage: "archivebox") {
                        model.sidebarSelection = .archived
                    }
                    Button("Recently Deleted", systemImage: "trash") {
                        model.sidebarSelection = .trash
                    }
                    if !model.folders.isEmpty {
                        Section("Folders") {
                            ForEach(model.folders, id: \.self) { folder in
                                Button(folder, systemImage: "folder") {
                                    model.sidebarSelection = .folder(folder)
                                }
                            }
                        }
                    }
                    if !model.allTags.isEmpty {
                        Section("Tags") {
                            ForEach(model.allTags, id: \.name) { tag in
                                Button("\(tag.name) (\(tag.count))", systemImage: "number") {
                                    model.sidebarSelection = .tag(tag.name)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Insights...", systemImage: "chart.bar.xaxis") {
                        model.insightsVisible = true
                    }
                    Button("Settings...", systemImage: "gearshape") {
                        model.settingsVisible = true
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .disabled(model.store == nil)
            }
        }
    #endif

    /// Why the library actions are unavailable, or nil once a library is open. Hover text on a
    /// dimmed control should say what is missing rather than only what the control would do.
    private var noLibraryReason: String? {
        model.store == nil ? "Open a library folder first, from File > Open Library." : nil
    }

    /// New-note button shown above the note list, plus save-search when one is active.
    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Section("Layout") {
                    Button {
                        settings.galleryLayout = false
                    } label: {
                        Label("Rows", systemImage: settings.galleryLayout ? "list.bullet" : "checkmark")
                    }
                    Button {
                        settings.galleryLayout = true
                    } label: {
                        Label(
                            "Gallery",
                            systemImage: settings.galleryLayout ? "checkmark" : "square.grid.2x2"
                        )
                    }
                }
                if !settings.galleryLayout {
                    Section("Density") {
                        ForEach(ListDensity.allCases) { density in
                            Button {
                                settings.listDensity = density
                            } label: {
                                Label(
                                    density.label,
                                    systemImage: settings.listDensity == density
                                        ? "checkmark" : density.symbol
                                )
                            }
                        }
                    }
                }
                Section("Sort") {
                    ForEach(NoteSort.allCases, id: \.self) { order in
                        Button {
                            model.noteSort = order
                        } label: {
                            Label(
                                order.label,
                                systemImage: model.noteSort == order ? "checkmark" : order.symbol
                            )
                        }
                    }
                }
            } label: {
                Label("View Options", systemImage: "slider.horizontal.3")
            }
            .disabled(model.store == nil)
            .help(noLibraryReason ?? "Rows or gallery, spacing, and sort order")
            if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Save Search", systemImage: "sparkle.magnifyingglass") {
                    smartFolderName = ""
                    savingSmartFolder = true
                }
                .help("Save this search as a smart folder")
            }
            Button("Audio Memo", systemImage: "mic") { model.memoRequested = true }
                .disabled(model.store == nil)
                .help(noLibraryReason ?? "Record a memo transcribed on device")
            Button("Photo to Note", systemImage: "text.viewfinder") { model.scanRequested = true }
                .disabled(model.store == nil)
                .help(noLibraryReason ?? "Scan a photo into a new note")
            #if os(iOS)
                Button("Scan Document", systemImage: "doc.viewfinder") {
                    model.documentScanRequested = true
                }
                .disabled(model.store == nil)
                .help(noLibraryReason ?? "Scan pages into a searchable note")
            #endif
            Button("New Note", systemImage: "plus") { model.createNote() }
                .disabled(model.store == nil)
                .help(noLibraryReason ?? "Create a note in the selected folder")
        }
    }

    /// Selectable row on macOS, push-navigation link on iOS.
    @ViewBuilder
    private func noteRow(for stored: StoredNote) -> some View {
        #if os(iOS)
            NavigationLink(value: stored.path) {
                NoteRow(
                    stored: stored, density: settings.listDensity,
                    searchHit: model.searchResults[stored.path]
                )
            }
            .draggable(stored.path)
        #else
            NoteRow(
                stored: stored, density: settings.listDensity,
                searchHit: model.searchResults[stored.path]
            )
            .tag(stored.path)
            .draggable(stored.path)
        #endif
    }

    /// Pane title matching the sidebar selection.
    private var title: String {
        switch model.sidebarSelection {
        case .all: return "All Notes"
        case .starred: return "Starred"
        case .todo: return "Tasks"
        case .archived: return "Archived"
        case .folder(let folder): return folder.components(separatedBy: "/").last ?? folder
        case .tag(let tag): return "#\(tag)"
        case .trash: return "Recently Deleted"
        }
    }
}

/// NoteRow renders one note: title and date on one line, a preview that shows the search
/// match when searching, and a tag row. Its air scales with the chosen list density.
struct NoteRow: View {
    /// Note to render.
    let stored: StoredNote
    /// How much spacing and how many preview lines the row carries.
    var density: ListDensity = .comfortable
    /// The search hit for this note, present only while a search is active, so the row can
    /// show the matched excerpt instead of the generic first line.
    var searchHit: NoteIndex.Hit?

    var body: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Style.Space.xs) {
                NoteStatusGlyphs(stored: stored)
                Text(stored.listTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: Style.Space.xs)
                if stored.updated > .distantPast {
                    Text(stored.updated, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            preview
            if !stored.note.metadata.tags.isEmpty {
                NoteTagChips(stored: stored, limit: density == .compact ? 2 : 4)
            }
        }
        .padding(.vertical, density.rowPadding)
    }

    /// The secondary line: a locked or encrypted placeholder, the highlighted search match,
    /// or the note's opening prose.
    @ViewBuilder
    private var preview: some View {
        if stored.note.metadata.encrypted {
            Label("Encrypted note", systemImage: "lock.shield")
                .font(.subheadline).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)
        } else if stored.note.metadata.locked {
            Label("Locked note", systemImage: "lock")
                .font(.subheadline).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)
        } else if let searchHit, !searchHit.snippet.isEmpty {
            Text(SearchMatch.snippet(searchHit))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(density.previewLineLimit)
        } else if !stored.listPreview.isEmpty {
            Text(stored.listPreview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(density.previewLineLimit)
        }
    }
}

/// NoteCard renders one note as a gallery card: title, a taller preview that shows the
/// search match when searching, date, and tags, on a bordered surface.
struct NoteCard: View {
    /// Note to render.
    let stored: StoredNote
    /// Whether the card is the current selection, macOS only.
    var selected = false
    /// The search hit for this note, present only while a search is active.
    var searchHit: NoteIndex.Hit?

    var body: some View {
        VStack(alignment: .leading, spacing: Style.Space.xs) {
            HStack(spacing: Style.Space.xs) {
                NoteStatusGlyphs(stored: stored)
                Text(stored.listTitle).font(.headline).lineLimit(2)
            }
            preview
            Spacer(minLength: 0)
            HStack(spacing: Style.Space.s - 2) {
                if stored.updated > .distantPast {
                    Text(stored.updated, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                NoteTagChips(stored: stored, limit: 2)
            }
        }
        .padding(Style.Space.m - 2)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(Style.cardFill, in: RoundedRectangle(cornerRadius: Style.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Style.Radius.card)
                .strokeBorder(selected ? Color.accentColor : Style.hairline, lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Style.Radius.card))
    }

    /// The card body line: placeholder for a sealed note, the highlighted search match, or
    /// the opening prose.
    @ViewBuilder
    private var preview: some View {
        if stored.note.metadata.encrypted {
            Label("Encrypted note", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.tertiary)
        } else if stored.note.metadata.locked {
            Label("Locked note", systemImage: "lock")
                .font(.caption).foregroundStyle(.tertiary)
        } else if let searchHit, !searchHit.snippet.isEmpty {
            Text(SearchMatch.snippet(searchHit))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else if !stored.cardPreview.isEmpty {
            Text(stored.cardPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// NoteStatusGlyphs shows the pin, star, lock, and encryption marks for a note.
struct NoteStatusGlyphs: View {
    /// Note whose flags are shown.
    let stored: StoredNote

    var body: some View {
        if stored.note.metadata.pinned {
            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint)
        }
        if stored.note.metadata.starred {
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
        }
        if stored.note.metadata.locked {
            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
        }
        if stored.note.metadata.encrypted {
            Image(systemName: "lock.shield.fill").font(.caption2).foregroundStyle(.tint)
        }
    }
}

/// NoteTagChips shows a note's first few tags as capsule chips, with a plus-count pill when
/// more tags are hidden, so a heavily tagged note still reads at a glance.
struct NoteTagChips: View {
    /// Note whose tags are shown.
    let stored: StoredNote
    /// Most tags shown before the rest collapse into a count.
    let limit: Int

    var body: some View {
        HStack(spacing: Style.Space.xs) {
            ForEach(stored.note.metadata.tags.prefix(limit), id: \.self) { tag in
                TagChip(tag: tag)
            }
            let overflow = stored.note.metadata.tags.count - limit
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

extension StoredNote {
    /// Title with file-name fallback for untitled notes. An encrypted note whose title lives
    /// inside the ciphertext shows a placeholder until the vault is unlocked.
    var listTitle: String {
        if let title = note.displayTitle { return title }
        if note.metadata.encrypted { return "Encrypted Note" }
        let name = path.components(separatedBy: "/").last ?? path
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// First non-heading body line, empty when the note has no prose yet.
    var listPreview: String {
        for line in note.body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return trimmed
        }
        return ""
    }

    /// Opening body lines for gallery cards, headings and blanks skipped.
    var cardPreview: String {
        var lines: [String] = []
        for line in note.body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            lines.append(trimmed)
            if lines.count == 6 { break }
        }
        return lines.joined(separator: "\n")
    }
}

/// Menu labels and icons for the sort order, kept in the app so the kit's NoteSort stays
/// free of presentation.
extension NoteSort {
    /// Menu label for the sort order.
    var label: String {
        switch self {
        case .updated: return "Last Edited"
        case .created: return "Date Created"
        case .title: return "Title"
        }
    }

    /// Menu icon for the sort order.
    var symbol: String {
        switch self {
        case .updated: return "clock"
        case .created: return "calendar"
        case .title: return "textformat"
        }
    }
}
