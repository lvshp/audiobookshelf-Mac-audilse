import Foundation
import AudilseCore

/// A search result opens a temporary filter, without changing saved preferences.
struct LibraryBrowseNavigation: Hashable, Identifiable {
    let id = UUID()
    let partition: AccountPartition
    let client: ObjectIdentifier?
    let libraryID: String
    let filter: LibraryBrowseFilter

    @MainActor func isCurrent(in store: AppStore, libraryID expected: String) -> Bool {
        guard libraryID == expected, store.route == .library(libraryID),
              !store.isDemo, !store.isConnecting, store.user?.isActive == true,
              store.partition == partition, store.client.map(ObjectIdentifier.init) == client,
              let library = store.libraries.first(where: { $0.id == libraryID }) else { return false }
        return filter.isAvailable(mediaType: library.mediaType, user: store.user)
    }
}

extension LibraryBrowserPreferences {
    func applying(temporaryFilter: LibraryBrowseFilter?, library: Library, user: UserAccount?, version: String?) -> Self {
        var effective = self
        if let temporaryFilter { effective.options.filter = temporaryFilter }
        effective.normalize(library: library, user: user, version: version)
        return effective
    }
}
