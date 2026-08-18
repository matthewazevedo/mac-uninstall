import Foundation

/// What one removal did, in enough detail to undo it.
///
/// The Trash and the quarantine folder already hold the files; what they do not hold
/// is where each one came from. Finder's Put Back covers the first, but only for items
/// it moved itself and only until the Trash is emptied, and nothing at all covers the
/// second. A receipt is the missing half.
public struct RemovalReceipt: Sendable, Codable, Identifiable, Equatable {

    public struct Item: Sendable, Codable, Equatable {
        /// Where the item lived before the removal.
        public var originalPath: String
        /// Where it is now: in the Trash, or in the quarantine folder.
        public var currentPath: String
        /// True when putting it back needs elevation.
        public var wasQuarantined: Bool

        public init(originalPath: String, currentPath: String, wasQuarantined: Bool) {
            self.originalPath = originalPath
            self.currentPath = currentPath
            self.wasQuarantined = wasQuarantined
        }
    }

    public var id: String
    public var date: Date
    /// The app whose footprint this was, for the sentence the UI has to write.
    public var appName: String
    public var items: [Item]

    public init(
        id: String = UUID().uuidString,
        date: Date = Date(),
        appName: String,
        items: [Item]
    ) {
        self.id = id
        self.date = date
        self.appName = appName
        self.items = items
    }

    /// Builds a receipt from a report.
    ///
    /// Returns `nil` when nothing ended up anywhere it could be recovered from, since
    /// a receipt that cannot restore anything is only a way to offer an undo that does
    /// nothing.
    public init?(report: RemovalReport, appName: String, date: Date = Date()) {
        let items = report.restorable.compactMap { outcome -> Item? in
            guard let location = outcome.currentLocation else { return nil }
            return Item(
                originalPath: outcome.url.path,
                currentPath: location.path,
                wasQuarantined: outcome.wasQuarantined
            )
        }
        guard !items.isEmpty else { return nil }
        self.init(date: date, appName: appName, items: items)
    }
}

/// Reads and writes receipts, newest first.
public struct ReceiptStore: Sendable {

    /// How many removals are kept. Receipts are a few kilobytes each and only matter
    /// while the files they point at still exist, so this is about not growing without
    /// bound rather than about space.
    public static let keepCount = 20

    public let directory: URL

    public init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacUninstall/Receipts")
    ) {
        self.directory = directory
    }

    public func save(_ receipt: RemovalReceipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: url(for: receipt), options: .atomic)
        prune()
    }

    /// Every receipt on disk, newest first.
    public func all() -> [RemovalReceipt] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(RemovalReceipt.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    /// The most recent removal that still has something to put back.
    public func latestRestorable() -> RemovalReceipt? {
        all().first { isRestorable($0) }
    }

    /// True while at least one item is still where the removal left it. Emptying the
    /// Trash makes a receipt useless, and offering an undo that cannot work is worse
    /// than not offering one.
    public func isRestorable(_ receipt: RemovalReceipt) -> Bool {
        receipt.items.contains { FileManager.default.fileExists(atPath: $0.currentPath) }
    }

    public func delete(_ receipt: RemovalReceipt) {
        try? FileManager.default.removeItem(at: url(for: receipt))
    }

    private func url(for receipt: RemovalReceipt) -> URL {
        directory.appending(path: "\(receipt.id).json")
    }

    private func prune() {
        for receipt in all().dropFirst(Self.keepCount) { delete(receipt) }
    }
}
