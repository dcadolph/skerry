import SkerryKit
import SwiftUI
import UniformTypeIdentifiers

/// ContentView is the three-pane library window: sidebar, note list, editor.
struct ContentView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Scene phase, driving the privacy cover while the vault is open.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        platformRoot
        #if os(iOS)
            // The app switcher snapshot must never show decrypted content; a cover takes
            // its place the moment the app stops being active while the vault is open.
            .overlay {
                if scenePhase != .active, model.vaultUnlocked {
                    ZStack {
                        Rectangle().fill(.regularMaterial).ignoresSafeArea()
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                    }
                }
            }
        #endif
        .searchable(text: $model.searchText, placement: searchPlacement, prompt: "Search notes")
        .onChange(of: model.searchText) { model.runSearch() }
        .onChange(of: model.selectedPath) { oldValue, _ in
            if let oldValue { model.discardIfEmpty(oldValue) }
        }
        .onChange(of: model.pathStack) { _, newValue in
            // Popping back to the list on iPhone is where an untouched new note should fall away.
            // onDisappear alone is unreliable across a NavigationStack pop, so discard here too.
            if newValue.isEmpty, let path = model.selectedPath { model.discardIfEmpty(path) }
        }
        .fileImporter(
            isPresented: $model.libraryPickerPresented,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result { model.openPickedLibrary(at: url) }
        }
        .sheet(isPresented: $model.settingsVisible) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.unlockPromptVisible) {
            UnlockView(model: model)
        }
        .sheet(isPresented: $model.conflictReviewVisible) {
            ConflictReviewView(model: model)
        }
        .sheet(isPresented: $model.insightsVisible) {
            InsightsView(model: model)
        }
        .sheet(
            isPresented: $model.onboardingVisible,
            onDismiss: { model.completeOnboardingDismissal() }
        ) {
            OnboardingView { openSecurity in
                model.requestOnboardingFinish(openingSecurity: openSecurity)
            }
        }
        .sheet(isPresented: $model.memoRequested) {
            RecordMemoView { audio, transcript, problem in
                model.createAudioMemoNote(audio: audio, transcript: transcript, problem: problem)
            }
        }
        #if os(iOS)
            .sheet(isPresented: $model.scanRequested) {
                CameraPicker { data in model.scanImageToNote(data) }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $model.documentScanRequested) {
                DocumentScanView { pages in
                    model.createScannedDocumentNote(pages: pages)
                }
                .ignoresSafeArea()
            }
        #else
            // Two `.fileImporter` modifiers on one view conflict on macOS: only the outermost
            // presents, which left the Open Library picker declared above dead on click. Hosting
            // the scan importer on its own background node keeps the root's importer the only one.
            .background {
                Color.clear.fileImporter(
                    isPresented: $model.scanRequested, allowedContentTypes: [.image]
                ) { result in
                    if case .success(let url) = result {
                        let accessing = url.startAccessingSecurityScopedResource()
                        if let data = try? Data(contentsOf: url) { model.scanImageToNote(data) }
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                }
            }
        #endif
        #if os(macOS)
            .overlay(alignment: .top) {
                if model.paletteVisible {
                    CommandPalette(model: model)
                        .padding(.top, 48)
                        .transition(.opacity)
                }
            }
        #else
            .sheet(isPresented: $model.paletteVisible) {
                CommandPalette(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        #endif
        .alert(
            "Skerry",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Three-pane split view on macOS, stack navigation on iPhone and iPad.
    @ViewBuilder
    private var platformRoot: some View {
        #if os(macOS)
            NavigationSplitView(columnVisibility: columnVisibility) {
                SidebarView(model: model)
            } content: {
                NoteListView(model: model)
            } detail: {
                EditorView(model: model)
            }
            .frame(minWidth: 900, minHeight: 500)
        #else
            NavigationStack(path: $model.pathStack) {
                NoteListView(model: model)
                    .navigationDestination(for: String.self) { path in
                        EditorDetail(model: model, path: path)
                    }
            }
        #endif
    }

    #if os(macOS)
        /// Collapses to the editor alone in focus mode, all three panes otherwise.
        private var columnVisibility: Binding<NavigationSplitViewVisibility> {
            Binding(
                get: { model.focusMode ? .detailOnly : .all },
                set: { model.focusMode = $0 == .detailOnly }
            )
        }
    #endif

    /// Sidebar placement on macOS, default field on iOS.
    private var searchPlacement: SearchFieldPlacement {
        #if os(macOS)
            .sidebar
        #else
            .automatic
        #endif
    }
}

/// SidebarView lists smart views and the folder tree of the open library.
struct SidebarView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Whether the new-folder name prompt is showing.
    @State private var newFolderPrompt = false
    /// Name typed into the new-folder prompt.
    @State private var newFolderName = ""
    /// Tag being renamed; nil when the prompt is closed.
    @State private var renameTagTarget: String?
    /// Name typed into the rename-tag prompt.
    @State private var renameTagText = ""
    /// Sidebar row currently under a dragged note, keyed by kind and name, for highlight.
    @State private var dropHighlight: String?

    var body: some View {
        List(selection: sidebarBinding) {
            Section("Library") {
                Label("All Notes", systemImage: "note.text").tag(SidebarItem.all)
                Label("Starred", systemImage: "star").tag(SidebarItem.starred)
                Label("Tasks", systemImage: "checklist").tag(SidebarItem.todo)
                Label("Archived", systemImage: "archivebox").tag(SidebarItem.archived)
                Label("Recently Deleted", systemImage: "trash").tag(SidebarItem.trash)
            }
            if !model.folders.isEmpty {
                Section("Folders") {
                    ForEach(model.folders, id: \.self) { folder in
                        Label(folder.components(separatedBy: "/").last ?? folder,
                              systemImage: "folder")
                            .padding(.leading, CGFloat(depth(of: folder)) * 12)
                            .tag(SidebarItem.folder(folder))
                            .listRowBackground(dropRowBackground(for: "folder:\(folder)"))
                            .dropDestination(for: String.self) { paths, _ in
                                for path in paths { model.moveNote(path, toFolder: folder) }
                                return !paths.isEmpty
                            } isTargeted: { targeted in
                                setDropHighlight("folder:\(folder)", targeted)
                            }
                    }
                }
            }
            if !model.smartFolders.isEmpty {
                Section("Smart Folders") {
                    ForEach(model.smartFolders) { folder in
                        Button {
                            model.runSmartFolder(folder)
                        } label: {
                            Label(folder.name, systemImage: "sparkle.magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete Smart Folder", role: .destructive) {
                                model.removeSmartFolder(folder.name)
                            }
                        }
                    }
                }
            }
            if !model.tagTree.isEmpty {
                Section("Tags") {
                    ForEach(model.tagTree, id: \.name) { node in
                        Label {
                            Text(node.name.components(separatedBy: "/").last ?? node.name)
                        } icon: {
                            TagDot(tag: node.name)
                        }
                        .padding(.leading, CGFloat(node.depth) * 12)
                        .badge(node.count)
                        .tag(SidebarItem.tag(node.name))
                        .listRowBackground(dropRowBackground(for: "tag:\(node.name)"))
                        .dropDestination(for: String.self) { paths, _ in
                            for path in paths { model.addTag(node.name, to: path) }
                            return !paths.isEmpty
                        } isTargeted: { targeted in
                            setDropHighlight("tag:\(node.name)", targeted)
                        }
                        .contextMenu {
                            Button("Rename Tag...", systemImage: "pencil") {
                                renameTagText = node.name
                                renameTagTarget = node.name
                            }
                        }
                    }
                }
            }
        }
        .alert(
            "Rename Tag",
            isPresented: Binding(
                get: { renameTagTarget != nil },
                set: { if !$0 { renameTagTarget = nil } }
            )
        ) {
            TextField("Tag", text: $renameTagText)
            Button("Rename") {
                if let renameTagTarget {
                    model.renameTag(renameTagTarget, to: renameTagText)
                }
                renameTagTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTagTarget = nil }
        } message: {
            Text("Renames the tag everywhere, nested tags included. Renaming onto an "
                + "existing tag merges them.")
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open Library", systemImage: "books.vertical") {
                    model.libraryPickerPresented = true
                }
                .help("Open a library folder")
                Button("New Folder", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    newFolderPrompt = true
                }
                .disabled(model.store == nil)
                .help("Create a folder in the current folder")
                Button("Insights", systemImage: "chart.bar.xaxis") {
                    model.insightsVisible = true
                }
                .disabled(model.store == nil)
                .help("Library statistics and writing streaks")
                Button("Settings", systemImage: "gearshape") {
                    model.settingsVisible = true
                }
                .disabled(model.store == nil)
                .help("Open settings and backup")
            }
        }
        .alert("New Folder", isPresented: $newFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") { model.createFolder(named: newFolderName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a folder inside the current selection.")
        }
    }

    /// Optional-selection proxy: platform list APIs clear to nil, the model falls back to All.
    private var sidebarBinding: Binding<SidebarItem?> {
        Binding(
            get: { model.sidebarSelection },
            set: { model.sidebarSelection = $0 ?? .all }
        )
    }

    /// Nesting depth of a folder path, zero for top-level folders.
    private func depth(of folder: String) -> Int {
        folder.components(separatedBy: "/").count - 1
    }

    /// Records which sidebar row a dragged note is hovering, so it can be highlighted, and
    /// clears the highlight when the note leaves that row.
    private func setDropHighlight(_ key: String, _ targeted: Bool) {
        if targeted {
            dropHighlight = key
        } else if dropHighlight == key {
            dropHighlight = nil
        }
    }

    /// Accent wash for a sidebar row that a dragged note is hovering, nil for the default.
    private func dropRowBackground(for key: String) -> Color? {
        dropHighlight == key ? Style.selectionFill : nil
    }
}
