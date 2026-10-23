import SkerryKit
import SwiftUI

/// InsightsView is the library statistics sheet: sizes, streaks, tasks, and tags.
struct InsightsView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss
    /// Summary computed once when the sheet opens.
    @State private var summary = InsightsSummary()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statGrid
                    streakPanel
                    if summary.openTasks + summary.doneTasks > 0 { taskPanel }
                    if !summary.topTags.isEmpty { tagPanel }
                    if summary.readableCount < summary.noteCount {
                        Text("\(summary.noteCount - summary.readableCount) sealed "
                            + "notes count toward totals but stay unread.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Insights")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { summary = model.computeInsights() }
        #if os(macOS)
            .frame(minWidth: 440, minHeight: 460)
        #endif
    }

    /// Headline numbers: notes, words, tags, encrypted.
    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
            statTile("Notes", value: summary.noteCount, icon: "note.text")
            statTile("Words", value: summary.wordCount, icon: "text.alignleft")
            statTile("Tags", value: summary.tagCount, icon: "number")
            statTile("Encrypted", value: summary.encryptedCount, icon: "lock.shield")
        }
    }

    /// One stat tile with an icon, a number, and its label.
    private func statTile(_ label: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.tint)
            Text(value, format: .number)
                .font(.title2.weight(.semibold))
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Writing streaks: the current run, the record, and the span of the library.
    private var streakPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Writing Streak", systemImage: "flame")
                .font(.headline)
            HStack(spacing: 16) {
                streakFigure(summary.streaks.current, caption: "Current")
                streakFigure(summary.streaks.longest, caption: "Longest")
                streakFigure(summary.streaks.activeDays, caption: "Days written")
            }
            if let first = summary.firstNoteDate {
                Text("Writing since \(first, format: .dateTime.day().month(.wide).year())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// One streak number with its caption.
    private func streakFigure(_ value: Int, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value == 1 ? "1 day" : "\(value) days")
                .font(.title3.weight(.semibold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Task progress across the library.
    private var taskPanel: some View {
        let total = summary.openTasks + summary.doneTasks
        return VStack(alignment: .leading, spacing: 8) {
            Label("Tasks", systemImage: "checklist")
                .font(.headline)
            ProgressView(value: Double(summary.doneTasks), total: Double(total))
            Text("\(summary.doneTasks) of \(total) done, \(summary.openTasks) open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The most-used tags with their note counts.
    private var tagPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Top Tags", systemImage: "number")
                .font(.headline)
            ForEach(summary.topTags, id: \.name) { tag in
                HStack {
                    Text(tag.name)
                        .font(.callout)
                    Spacer()
                    Text(tag.count, format: .number)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
