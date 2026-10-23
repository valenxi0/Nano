import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import UniformTypeIdentifiers

/// What a cue is for. Guessed at capture time and changeable afterwards; it
/// only drives the label and how the text is drawn, never what a cue can do.
enum CueKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case todo
    case prompt
    case idea
    case link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: "To-do"
        case .prompt: "Prompt"
        case .idea: "Idea"
        case .link: "Link"
        }
    }

    /// A single URL is a link; long or multi-line text reads as a prompt.
    static func guess(for text: String) -> CueKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeLink(trimmed) {
            return .link
        }
        if trimmed.count >= 120 || trimmed.contains("\n") {
            return .prompt
        }
        return .todo
    }

    /// Endings common enough to call a bare `host/path` an address. A file
    /// path like `Nano.app/Contents` or a fraction like `1.5/2` is not one.
    private static let linkEndings: Set<String> = [
        "com", "org", "net", "io", "dev", "ai", "co", "edu", "gov", "me", "so", "xyz",
        "site", "info", "tech", "cloud", "page", "gg", "tv", "fm", "uk", "de", "fr", "es", "ca", "us",
    ]

    private static func looksLikeLink(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: text)?.host?.isEmpty == false
        }
        guard let slash = lowered.firstIndex(of: "/") else { return false }
        let labels = lowered[..<slash].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty), let ending = labels.last else { return false }
        return linkEndings.contains(String(ending))
    }
}

struct CueItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var kind: CueKind
    /// Nil is the Inbox.
    var folderID: UUID?
    /// File names inside the store's Images folder.
    var images: [String]
    var sourceApp: String?
    var createdAt: Date
    var completedAt: Date?
    /// Last edit to the text, kind, done state or folder, made in Cue. Sync
    /// compares it with the other app's edit time when both sides changed.
    var updatedAt: Date

    var isDone: Bool { completedAt != nil }

    /// First line, for places that only have room for one.
    var headline: String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return images.isEmpty ? "Empty cue" : "Image" }
        return trimmed
    }
}

extension CueItem {
    /// Libraries saved before `updatedAt` existed use the latest date they have.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        kind = try container.decode(CueKind.self, forKey: .kind)
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        images = try container.decode([String].self, forKey: .images)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? max(createdAt, completedAt ?? createdAt)
    }
}

enum CueFolderSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case project
    case stash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "Projects"
        case .stash: "Stash"
        }
    }
}

struct CueFolder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var section: CueFolderSection
    var colorIndex: Int
    /// A project directory. It is shown as the folder's path, and a folder
    /// made from one takes its name.
    var linkedPath: String?

    static let palette: [(Double, Double, Double)] = [
        (0.31, 0.49, 1.00),
        (1.00, 0.70, 0.34),
        (0.50, 0.84, 0.60),
        (0.84, 0.55, 0.96),
        (1.00, 0.45, 0.45),
        (0.35, 0.80, 0.85),
    ]

    var linkedDisplayPath: String? {
        linkedPath.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }
}

/// Which list the island is showing.
enum CueScope: Hashable, Sendable {
    case inbox
    case folder(UUID)

    var folderID: UUID? {
        if case let .folder(id) = self { return id }
        return nil
    }
}

/// A capture in progress. Images are PNG data until the cue is saved.
struct CueDraft: Equatable {
    var text: String
    var kind: CueKind?
    var images: [Data]
    var scope: CueScope
    var sourceApp: String?
    var pulledFromSelection: Bool
    /// Opened by the shortcut from another app: saving hands focus back.
    var returnsFocus: Bool

    var resolvedKind: CueKind { kind ?? CueKind.guess(for: text) }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }
}

struct CueToast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    /// Set when the action was completing a cue, so Undo can reopen it.
    var reopens: UUID?
    /// Set when the action deleted cues, so Undo can put them back.
    var restores = false
    /// Set when the action deleted a folder, so Undo can put it back.
    var restoresFolder = false

    var isUndoable: Bool { reopens != nil || restores || restoresFolder }
}

@MainActor
final class CueStore: ObservableObject {
    @Published private(set) var folders: [CueFolder] = []
    @Published private(set) var items: [CueItem] = []
    @Published var scope: CueScope = .inbox
    @Published var searchQuery = ""
    @Published var draft: CueDraft?
    @Published var editingItemID: UUID?
    @Published var showsDone = false
    @Published private(set) var toast: CueToast?
    @Published private(set) var errorMessage: String?

    let directoryURL: URL
    var imagesURL: URL { directoryURL.appendingPathComponent("Images", isDirectory: true) }
    private var fileURL: URL { directoryURL.appendingPathComponent("cue.json") }
    private var toastTask: Task<Void, Never>?
    /// Deleted cues whose Undo is still on offer, with where each one sat.
    /// Their images stay on disk until the offer runs out.
    private var removed: [(index: Int, item: CueItem)] = []
    /// A deleted folder whose Undo is still on offer, and the cues it held.
    private var removedFolder: (index: Int, folder: CueFolder, items: Set<UUID>)?
    /// True when `cue.json` exists but couldn't be read. Nothing is written
    /// while it is, so the unread library is never replaced by an empty one.
    private(set) var libraryIsUnreadable = false
    private let imageCache = NSCache<NSString, NSImage>()
    private let pasteRelay = CuePasteRelay()
    /// Called after the library changes in Cue, and when an Undo offer runs
    /// out. Not called for changes sync applies itself.
    var onChange: (() -> Void)?

    /// Cues sync must leave alone for now: deleted ones whose Undo is still on
    /// offer, and the cues of a deleted folder whose Undo is still on offer.
    var pendingUndoIDs: Set<UUID> {
        Set(removed.map(\.item.id)).union(removedFolder?.items ?? [])
    }

    /// A deleted folder whose Undo is still on offer.
    var pendingUndoFolderID: UUID? { removedFolder?.folder.id }

    private struct Snapshot: Codable {
        var folders: [CueFolder]
        var items: [CueItem]
        var scope: UUID?
    }

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectory
        load()
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Nano", isDirectory: true)
            .appendingPathComponent("Cue", isDirectory: true)
    }

    // MARK: Reading

    func folder(_ id: UUID?) -> CueFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    func title(for scope: CueScope) -> String {
        switch scope {
        case .inbox: "Inbox"
        case let .folder(id): folder(id)?.name ?? "Inbox"
        }
    }

    func folders(in section: CueFolderSection) -> [CueFolder] {
        folders.filter { $0.section == section }
    }

    func openItems(in scope: CueScope) -> [CueItem] {
        filtered(items.filter { $0.folderID == scope.folderID && !$0.isDone })
    }

    /// Most recently finished first.
    func doneItems(in scope: CueScope) -> [CueItem] {
        filtered(items.filter { $0.folderID == scope.folderID && $0.isDone })
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func openCount(in scope: CueScope) -> Int {
        items.lazy.filter { $0.folderID == scope.folderID && !$0.isDone }.count
    }

    var totalOpenCount: Int {
        items.lazy.filter { !$0.isDone }.count
    }

    var doneCount: Int {
        items.lazy.filter(\.isDone).count
    }

    func doneCount(in scope: CueScope) -> Int {
        items.lazy.filter { $0.folderID == scope.folderID && $0.isDone }.count
    }

    private func filtered(_ list: [CueItem]) -> [CueItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return list }
        return list.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private static func normalized(_ path: String) -> String {
        var value = (path as NSString).expandingTildeInPath
        value = URL(fileURLWithPath: value).standardizedFileURL.path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    // MARK: Folders

    @discardableResult
    func addFolder(named name: String, section: CueFolderSection, linkedPath: String? = nil) -> CueFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = CueFolder(
            id: UUID(),
            name: trimmed.isEmpty ? "Untitled" : trimmed,
            section: section,
            colorIndex: folders.count % CueFolder.palette.count,
            linkedPath: linkedPath.map(Self.normalized)
        )
        folders.append(folder)
        save()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateFolder(id) { $0.name = trimmed }
    }

    func setFolderColor(_ id: UUID, index: Int) {
        updateFolder(id) { $0.colorIndex = index % CueFolder.palette.count }
    }

    func setFolderSection(_ id: UUID, section: CueFolderSection) {
        updateFolder(id) { $0.section = section }
    }

    func linkFolder(_ id: UUID, to path: String?) {
        updateFolder(id) { $0.linkedPath = path.map(Self.normalized) }
    }

    /// Cues in a deleted folder go to the Inbox; nothing is thrown away.
    func deleteFolder(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        purgeRemoved()
        let folder = folders.remove(at: index)
        let members = items.indices.filter { items[$0].folderID == id }.map { items[$0].id }
        for index in items.indices where items[index].folderID == id {
            items[index].folderID = nil
        }
        if scope == .folder(id) { scope = .inbox }
        save()
        removedFolder = (index, folder, Set(members))
        present(CueToast(message: "Folder \u{201C}\(folder.name)\u{201D} deleted", restoresFolder: true), seconds: 5)
    }

    private func restoreRemovedFolder() {
        guard let entry = removedFolder else { return }
        removedFolder = nil
        folders.insert(entry.folder, at: min(entry.index, folders.count))
        for index in items.indices where entry.items.contains(items[index].id) {
            items[index].folderID = entry.folder.id
        }
        save()
    }

    func moveFolder(_ id: UUID, by offset: Int) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let section = folders[index].section
        let peers = folders.indices.filter { folders[$0].section == section }
        guard let position = peers.firstIndex(of: index) else { return }
        let target = position + offset
        guard peers.indices.contains(target) else { return }
        folders.swapAt(index, peers[target])
        save()
    }

    private func updateFolder(_ id: UUID, _ change: (inout CueFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        change(&folders[index])
        save()
    }

    // MARK: Cues

    @discardableResult
    func add(
        text: String,
        kind: CueKind? = nil,
        images: [Data] = [],
        scope: CueScope,
        sourceApp: String? = nil
    ) -> CueItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = images.compactMap(storeImage)
        guard !trimmed.isEmpty || !names.isEmpty else { return nil }
        let now = Date()
        let item = CueItem(
            id: UUID(),
            text: trimmed,
            kind: kind ?? CueKind.guess(for: trimmed),
            folderID: folder(scope.folderID)?.id,
            images: names,
            sourceApp: sourceApp,
            createdAt: now,
            completedAt: nil,
            updatedAt: now
        )
        // New cues join the end of the list: the order is the order of work.
        items.append(item)
        save()
        return item
    }

    func update(_ id: UUID, text: String? = nil, kind: CueKind? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || !items[index].images.isEmpty else { return }
            items[index].text = trimmed
        }
        if let kind { items[index].kind = kind }
        items[index].updatedAt = Date()
        save()
    }

    func setDone(_ id: UUID, _ done: Bool, announce: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].isDone != done else { return }
        items[index].completedAt = done ? Date() : nil
        items[index].updatedAt = Date()
        save()
        if announce, done {
            showToast("Marked done", reopens: id)
        }
    }

    func move(_ id: UUID, to scope: CueScope) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.folderID = folder(scope.folderID)?.id
        item.updatedAt = Date()
        items.append(item)
        save()
    }

    /// Drag reordering: `id` takes `target`'s place in the list.
    func reorder(_ id: UUID, before target: UUID) {
        guard id != target,
              let from = items.firstIndex(where: { $0.id == id }),
              items.contains(where: { $0.id == target }) else { return }
        let item = items.remove(at: from)
        let to = items.firstIndex(where: { $0.id == target }) ?? items.endIndex
        items.insert(item, at: from <= to ? min(to + 1, items.endIndex) : to)
        save()
    }

    func moveToTop(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        guard let first = items.firstIndex(where: { $0.folderID == item.folderID && !$0.isDone }),
              first != index else { return }
        items.remove(at: index)
        items.insert(item, at: first)
        save()
    }

    /// `undoable` keeps the cue for a few seconds behind an Undo toast.
    func delete(_ id: UUID, undoable: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if editingItemID == id { editingItemID = nil }
        remove(at: [index], message: "Cue deleted", undoable: undoable)
    }

    func removeImage(_ name: String, from id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].images.removeAll { $0 == name }
        removeImages([name])
        save()
    }

    func clearCompleted(in scope: CueScope? = nil, undoable: Bool = false) {
        let doomed = items.indices.filter {
            items[$0].isDone && (scope == nil || items[$0].folderID == scope?.folderID)
        }
        guard !doomed.isEmpty else { return }
        remove(
            at: doomed,
            message: doomed.count == 1 ? "Cleared 1 done cue" : "Cleared \(doomed.count) done cues",
            undoable: undoable
        )
    }

    private func remove(at indices: [Int], message: String, undoable: Bool) {
        // An earlier Undo offer ends here.
        purgeRemoved()
        let taken = indices.map { (index: $0, item: items[$0]) }
        let ids = Set(taken.map { $0.item.id })
        items.removeAll { ids.contains($0.id) }
        save()
        if undoable {
            removed = taken
            present(CueToast(message: message, restores: true), seconds: 5)
        } else {
            taken.forEach { removeImages($0.item.images) }
        }
    }

    /// Puts deleted cues back where they were.
    private func restoreRemoved() {
        for entry in removed.sorted(by: { $0.index < $1.index }) {
            var item = entry.item
            // Its folder may have been deleted in the meantime.
            if folder(item.folderID) == nil { item.folderID = nil }
            items.insert(item, at: min(entry.index, items.count))
        }
        removed = []
        save()
    }

    private func purgeRemoved() {
        let ended = !removed.isEmpty || removedFolder != nil
        removed.forEach { removeImages($0.item.images) }
        removed = []
        removedFolder = nil
        if ended { onChange?() }
    }

    // MARK: Sync

    /// A change that came from another app through sync.
    enum SyncEdit {
        case insert(CueItem)
        /// Skipped when the cue was edited in Cue after `expected`; the next
        /// sync pass sends that newer edit out instead.
        case update(id: UUID, expected: Date, text: String?, done: Bool?, folderID: UUID??, kind: CueKind? = nil)
        case delete(UUID)
    }

    private var applyingSync = false

    /// Applies one sync pass's changes and saves once. `updatedAt` is left
    /// alone: these edits were made in the other app, not in Cue.
    func applySyncEdits(_ edits: [SyncEdit]) {
        guard !edits.isEmpty, !libraryIsUnreadable else { return }
        for edit in edits {
            switch edit {
            case var .insert(item):
                guard !items.contains(where: { $0.id == item.id }) else { continue }
                if folder(item.folderID) == nil { item.folderID = nil }
                items.append(item)
            case let .update(id, expected, text, done, folderID, kind):
                guard let index = items.firstIndex(where: { $0.id == id }),
                      items[index].updatedAt <= expected else { continue }
                if let text, !text.isEmpty { items[index].text = text }
                if let kind { items[index].kind = kind }
                if let done, done != items[index].isDone {
                    items[index].completedAt = done ? Date() : nil
                }
                if let folderID, folderID != items[index].folderID {
                    var item = items.remove(at: index)
                    item.folderID = folder(folderID)?.id
                    items.append(item)
                }
            case let .delete(id):
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                if editingItemID == id { editingItemID = nil }
                removeImages(items.remove(at: index).images)
            }
        }
        applyingSync = true
        save()
        applyingSync = false
    }

    // MARK: Pasteboard

    /// Text first, then any images, so a terminal takes the prompt and an app
    /// that accepts images can take those too.
    func copy(_ id: UUID, markDone: Bool) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let images = item.images.compactMap { image(named: $0) }
        // Most apps take either the text or the image from a clipboard that
        // holds both. With Accessibility, the text goes on the clipboard and
        // the images follow the user's paste.
        if item.text.isEmpty || images.isEmpty || !pasteRelay.arm(text: item.text, images: images) {
            pasteRelay.disarm()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            var objects: [NSPasteboardWriting] = []
            if !item.text.isEmpty { objects.append(item.text as NSString) }
            objects.append(contentsOf: images)
            pasteboard.writeObjects(objects)
        }

        if markDone {
            setDone(id, true)
            showToast(item.kind == .prompt ? "Prompt copied and marked done" : "Copied and marked done", reopens: id)
        } else {
            showToast(item.kind == .prompt ? "Prompt copied" : "Copied")
        }
    }

    func copyImage(_ name: String) {
        guard let image = image(named: name) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showToast("Image copied")
    }

    func undoToast() {
        guard let toast else { return }
        if let id = toast.reopens { setDone(id, false) }
        if toast.restores { restoreRemoved() }
        if toast.restoresFolder { restoreRemovedFolder() }
        dismissToast()
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
        purgeRemoved()
    }

    func showToast(_ message: String, reopens: UUID? = nil) {
        // A passing message does not take away an Undo still on offer.
        if reopens == nil, toast?.isUndoable == true { return }
        purgeRemoved()
        present(CueToast(message: message, reopens: reopens), seconds: 4)
    }

    private func present(_ toast: CueToast, seconds: Int) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.purgeRemoved()
        }
    }

    // MARK: Capture

    func beginCapture(
        text: String = "",
        images: [Data] = [],
        sourceApp: String? = nil,
        pulledFromSelection: Bool = false,
        returnsFocus: Bool = false
    ) {
        editingItemID = nil
        // A draft left behind when the island closed is picked up again, not replaced.
        if let existing = draft, !existing.isEmpty {
            draft?.returnsFocus = returnsFocus
            return
        }
        draft = CueDraft(
            text: text,
            kind: nil,
            images: images,
            scope: scope,
            sourceApp: sourceApp,
            pulledFromSelection: pulledFromSelection,
            returnsFocus: returnsFocus
        )
    }

    /// Saves the draft. `keepOpen` starts a fresh one in the same folder.
    @discardableResult
    func commitDraft(keepOpen: Bool = false) -> CueItem? {
        guard let current = draft else { return nil }
        let item = add(
            text: current.text,
            kind: current.kind,
            images: current.images,
            scope: current.scope,
            sourceApp: current.sourceApp
        )
        scope = current.scope
        if keepOpen {
            draft = CueDraft(
                text: "",
                kind: nil,
                images: [],
                scope: current.scope,
                sourceApp: current.sourceApp,
                pulledFromSelection: false,
                returnsFocus: current.returnsFocus
            )
        } else {
            draft = nil
        }
        if item != nil {
            showToast("Saved to \(title(for: current.scope))")
        }
        return item
    }

    func cancelDraft() {
        draft = nil
    }

    /// PNG data for any image the pasteboard or a drop can offer.
    static func imageData(from pasteboard: NSPasteboard) -> [Data] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL], !urls.isEmpty {
            return urls.compactMap { NSImage(contentsOf: $0).flatMap(pngData) }
        }
        let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []
        return images.compactMap(pngData)
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Images

    func imageURL(named name: String) -> URL {
        imagesURL.appendingPathComponent(name)
    }

    func image(named name: String) -> NSImage? {
        if let cached = imageCache.object(forKey: name as NSString) { return cached }
        guard let image = NSImage(contentsOf: imageURL(named: name)) else { return nil }
        imageCache.setObject(image, forKey: name as NSString)
        return image
    }

    private func storeImage(_ data: Data) -> String? {
        let name = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
            try data.write(to: imageURL(named: name), options: .atomic)
            return name
        } catch {
            errorMessage = "Couldn't save an image: \(error.localizedDescription)"
            return nil
        }
    }

    private func removeImages(_ names: [String]) {
        for name in names {
            imageCache.removeObject(forKey: name as NSString)
            try? FileManager.default.removeItem(at: imageURL(named: name))
        }
    }

    func reveal() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            folders = snapshot.folders
            items = snapshot.items
            if let id = snapshot.scope, folders.contains(where: { $0.id == id }) {
                scope = .folder(id)
            }
        } catch {
            libraryIsUnreadable = true
            setAsideUnreadableLibrary()
            errorMessage = "Cue couldn't read its library, so changes are not being saved: \(error.localizedDescription)"
        }
    }

    /// Copies an unreadable `cue.json` next to itself, once, so it can be
    /// repaired by hand whatever happens to the original.
    private func setAsideUnreadableLibrary() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        guard !names.contains(where: { $0.hasPrefix("cue.json.bad-") }) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let copy = directoryURL.appendingPathComponent("cue.json.bad-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: fileURL, to: copy)
    }

    /// Small enough to write whole on every change, and nothing is lost if
    /// Nano quits a moment later.
    func save() {
        guard !libraryIsUnreadable else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Snapshot(folders: folders, items: items, scope: scope.folderID))
            try data.write(to: fileURL, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "Cue couldn't save: \(error.localizedDescription)"
        }
        if !applyingSync { onChange?() }
    }
}

/// Pastes a copied cue's images right after its text. The clipboard holds the
/// text; when the user pastes it into another app, each image is pasted behind
/// it and the text is put back, so every paste of the cue is the whole cue.
/// Needs Accessibility to see the paste and to send the ones that follow.
@MainActor
final class CuePasteRelay {
    private var text = ""
    private var images: [NSImage] = []
    /// The clipboard's change count while it still holds the cue's text.
    private var armedCount: Int?
    private var monitor: Any?
    private var isRelaying = false

    func arm(text: String, images: [NSImage]) -> Bool {
        guard NanoAccessibilityPermission.isTrusted,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        self.text = text
        self.images = images
        armedCount = write([text as NSString])
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let keyCode = event.keyCode
                let flags = event.modifierFlags.rawValue
                Task { @MainActor in
                    self?.keyDown(keyCode: keyCode, flags: NSEvent.ModifierFlags(rawValue: flags))
                }
            }
        }
        return monitor != nil
    }

    func disarm() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        armedCount = nil
        images = []
        text = ""
    }

    static func isPaste(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == UInt16(kVK_ANSI_V) && flags.contains(.command) && !flags.contains(.control)
    }

    private func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard !isRelaying, Self.isPaste(keyCode: keyCode, flags: flags) else { return }
        // Something else was copied since: the cue is no longer what pastes.
        guard NSPasteboard.general.changeCount == armedCount else { return disarm() }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        isRelaying = true
        Task { @MainActor in
            // Let the app read the text before the clipboard changes under it.
            try? await Task.sleep(for: .milliseconds(220))
            for image in images {
                write([image])
                Self.sendPaste(to: pid)
                try? await Task.sleep(for: .milliseconds(350))
            }
            if armedCount != nil { armedCount = write([text as NSString]) }
            isRelaying = false
        }
    }

    @discardableResult
    private func write(_ objects: [NSPasteboardWriting]) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
        return pasteboard.changeCount
    }

    private static func sendPaste(to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.postToPid(pid)
        }
    }
}

/// Reads the selection in the frontmost app through Accessibility, so a
/// capture can start with the text the user was looking at.
enum CueSelectionReader {
    static func frontmostSelection() -> (text: String?, appName: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName
        guard AXIsProcessTrusted(), let pid = app?.processIdentifier else { return (nil, name) }

        let element = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return (nil, name)
        }
        var selected: CFTypeRef?
        // The type check above guarantees this cast.
        let focusedElement = focused as! AXUIElement
        guard AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else {
            return (nil, name)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? nil : trimmed, name)
    }
}
