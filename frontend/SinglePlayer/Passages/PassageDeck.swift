import Foundation

/// A shuffle bag of passage IDs: every passage in the pool is dealt once, in
/// random order, before any passage repeats. When the bag runs out it is
/// refilled with a fresh shuffle whose first passage is never the one dealt
/// last, so a repeat is never back to back.
///
/// The remaining bag and the last passage dealt are saved in `defaults`
/// (one bag per `name`), so the order carries across rounds and launches.
/// Used from the round's main-actor code only.
final class PassageDeck {
    private let defaults: UserDefaults
    private let bagKey: String
    private let lastKey: String
    private let shuffle: ([Passage.ID]) -> [Passage.ID]

    init(name: String,
         defaults: UserDefaults,
         shuffle: @escaping ([Passage.ID]) -> [Passage.ID] = { $0.shuffled() }) {
        self.defaults = defaults
        self.bagKey = SettingsStorage.prefix + "passageDeck.\(name).bag"
        self.lastKey = SettingsStorage.prefix + "passageDeck.\(name).last"
        self.shuffle = shuffle
    }

    /// The next passage from the bag, skipping the IDs in `excluding` (the
    /// passages on screen, most recent last). Skipped passages stay in the
    /// bag for a later deal. Returns nil only for an empty pool.
    func deal(from pool: [Passage.ID], excluding: [Passage.ID]) -> Passage.ID? {
        guard !pool.isEmpty else { return nil }
        let poolSet = Set(pool)
        let excluded = Set(excluding)
        // IDs no longer in the pool (a passage removed in an update) drop out.
        var bag = (defaults.stringArray(forKey: bagKey) ?? []).filter { poolSet.contains($0) }
        var index = bag.firstIndex { !excluded.contains($0) }

        if index == nil {
            // Empty, or only passages on screen left: those stay first in line,
            // and a fresh shuffle of the rest of the pool follows them.
            let leftover = Set(bag)
            bag += shuffle(pool.filter { !leftover.contains($0) })
            let last = defaults.string(forKey: lastKey)
            index = bag.firstIndex { !excluded.contains($0) && $0 != last }
                ?? bag.firstIndex { !excluded.contains($0) }
                ?? bag.firstIndex { $0 != excluding.last }
        }

        let id = bag.remove(at: index ?? 0)
        defaults.set(bag, forKey: bagKey)
        defaults.set(id, forKey: lastKey)
        return id
    }
}
