import AppIntents
import CoreSpotlight
import SwiftUI

@available(iOS 18.0, *)
extension HomebaseEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = [category, notes, owner, storeName].joined(separator: "\n")
        attributes.startDate = date
        return attributes
    }
}

@MainActor enum HomebaseDiscovery {
    private static var pending: [Item]?
    private static var task: Task<Void, Never>?
    private static var lastIndexed: [Item]?
    static func schedule(_ items: [Item]) {
        guard #available(iOS 18.0, *) else { return }
        pending = items
        guard task == nil else { return }
        task = Task {
            try? await Task.sleep(for: .seconds(1))
            while let batch = pending {
                pending = nil
                guard batch != lastIndexed else { continue }
                do {
                    let index = CSSearchableIndex.default()
                    let visible = EventRecurrence.visibleItems(batch).filter { !$0.deleted }
                    try await index.deleteAppEntities(ofType: HomebaseEntity.self)
                    #if compiler(>=6.3)
                    if #available(iOS 27.0, *) {
                        try await index.deleteAppEntities(ofType: HouseholdReminder.self)
                        try await index.deleteAppEntities(ofType: HouseholdEvent.self)
                        try await index.indexAppEntities(visible.filter { [.task, .dinner, .grocery].contains($0.kind) }.map(HouseholdReminder.init))
                        try await index.indexAppEntities(visible.filter { $0.kind == .event }.map(HouseholdEvent.init))
                        try await index.indexAppEntities(visible.filter { [.bill, .meal].contains($0.kind) }.map(HomebaseEntity.init))
                    } else { try await index.indexAppEntities(visible.map(HomebaseEntity.init)) }
                    #else
                    try await index.indexAppEntities(visible.map(HomebaseEntity.init))
                    #endif
                    lastIndexed = batch
                } catch {
                    // Indexing is best-effort; direct Siri queries still use the current Store.
                    // A future persist retries without interfering with household sync.
                }
            }
            task = nil
        }
    }
}

extension View {
    @ViewBuilder func homebaseAssistantContext(_ item: Item) -> some View {
        #if compiler(>=6.3)
        if #available(iOS 27.0, *), item.kind == .event { self.appEntityIdentifier(EntityIdentifier(for: HouseholdEvent.self, identifier: item.id)) }
        else if #available(iOS 27.0, *), [.task, .dinner, .grocery].contains(item.kind) { self.appEntityIdentifier(EntityIdentifier(for: HouseholdReminder.self, identifier: item.id)) }
        else if #available(iOS 18.4, *) { self.appEntityIdentifier(EntityIdentifier(for: HomebaseEntity.self, identifier: item.id)) }
        else { self }
        #else
        if #available(iOS 18.4, *) { self.appEntityIdentifier(EntityIdentifier(for: HomebaseEntity.self, identifier: item.id)) } else { self }
        #endif
    }
}
