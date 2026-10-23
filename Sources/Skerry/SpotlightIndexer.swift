import CoreSpotlight
import Foundation
import SkerryKit

/// SpotlightIndexer mirrors plain, unlocked notes into the system search index so notes
/// surface in Spotlight. Locked and encrypted notes never reach it.
enum SpotlightIndexer {
    /// Domain grouping every Skerry item, so a full refresh can clear it in one call.
    private static let domain = "com.dcadolph.skerry.notes"

    /// One note's worth of indexable fields.
    struct Entry: Sendable {
        /// Library-relative path, the stable identity and deep-link target.
        var path: String
        /// Display title.
        var title: String
        /// Body excerpt for the result subtitle.
        var preview: String
        /// Tags exposed as keywords.
        var tags: [String]
    }

    /// Replaces the whole Skerry domain with the given entries, off the main thread.
    static func reindex(_ entries: [Entry]) {
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            let items = entries.map { entry -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .text)
                attributes.title = entry.title
                attributes.contentDescription = entry.preview
                attributes.keywords = entry.tags
                return CSSearchableItem(
                    uniqueIdentifier: entry.path,
                    domainIdentifier: domain,
                    attributeSet: attributes
                )
            }
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items, completionHandler: nil)
        }
    }

    /// Removes everything, for library switches.
    static func removeAll() {
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domain], completionHandler: nil)
    }

    /// The note path a Spotlight result activity points at, nil for foreign activities.
    static func path(from activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType else { return nil }
        return activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    }
}
