import AppKit
import Foundation
import QuickLookThumbnailing

struct TrayItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL

    init(url: URL) {
        self.id = UUID()
        self.url = url.standardizedFileURL
    }

    var name: String {
        url.lastPathComponent
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// On an external disk that isn't plugged in right now. Such a file is
    /// not missing, so it stays held until its volume is back.
    var isOnUnmountedVolume: Bool {
        let parts = url.pathComponents
        guard parts.count > 3, parts[1] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(parts[2])")
    }
}

/// Files held for later. The tray keeps references, never copies: the
/// originals stay where they are, and one that moves or is deleted drops out.
/// Text, links, and images have no file of their own, so the tray writes one
/// into its Clippings folder and owns it.
@MainActor
final class TrayStore: ObservableObject {
    @Published private(set) var items: [TrayItem] = [] {
        didSet { selection.formIntersection(items.map(\.id)) }
    }
    /// Items picked on the shelf. Dragging, AirDrop, and Compress act on
    /// these when there are any, everything otherwise.
    @Published var selection: Set<TrayItem.ID> = []
    /// True while a zip is being written.
    @Published private(set) var isCompressing = false
    /// A few seconds of feedback in the tray's footer.
    @Published private(set) var message: String?
    private var messageTask: Task<Void, Never>?
    /// True while the footer offers Undo for a removal.
    @Published private(set) var canUndo = false
    private var discarded: [(index: Int, item: TrayItem)] = []
    /// Counts drops, including ones that only brought duplicates, so the
    /// island can tell a drop from a drag that was carried away.
    private(set) var dropCount = 0

    /// Where held paths survive a restart. Nil keeps them in memory only.
    private let storageURL: URL?
    let clippingsDirectory: URL

    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nano/Tray/items.json")
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        clippingsDirectory = storageURL?.deletingLastPathComponent()
            .appendingPathComponent("Clippings", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("NanoTrayClippings-\(UUID().uuidString)", isDirectory: true)
        load()
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        dropCount += 1
        return hold(urls)
    }

    @discardableResult
    private func hold(_ urls: [URL]) -> Int {
        var seenPaths = Set(items.map { $0.url.path })
        let accepted = urls
            .map(\.standardizedFileURL)
            .filter(\.isFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { seenPaths.insert($0.path).inserted }

        items.append(contentsOf: accepted.map(TrayItem.init))
        // The shelf growing is the confirmation; only a drop that added nothing says so.
        if accepted.isEmpty { say("Already in the tray") }
        save()
        return accepted.count
    }

    /// Pasteboard types the tray can hold, for drop targets and drag detection.
    static let holdableTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string]

    /// A drop on the Hold target.
    func accept(_ pasteboard: NSPasteboard) -> Bool {
        let urls = holdables(on: pasteboard, into: clippingsDirectory)
        guard !urls.isEmpty else { return false }
        add(urls)
        return true
    }

    /// AirDrop shares what was dropped on it and holds nothing. Clippings for
    /// it go to a temporary folder rather than the tray's own.
    func airDrop(_ pasteboard: NSPasteboard) -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoAirDrop-\(UUID().uuidString)", isDirectory: true)
        return sendViaAirDrop(holdables(on: pasteboard, into: directory))
    }

    /// Holds whatever is on the clipboard: files, an image (a screenshot
    /// taken to the clipboard, say), a link, or text.
    func pasteFromClipboard() {
        let urls = holdables(on: .general, into: clippingsDirectory)
        if urls.isEmpty {
            say("Nothing on the clipboard to hold")
        } else {
            hold(urls)
        }
    }

    /// Files stay the originals. Anything else becomes a clipping. An image
    /// wins over a link, because an image dragged out of a browser carries
    /// both, and the picture is what was meant.
    private func holdables(on pasteboard: NSPasteboard, into directory: URL) -> [URL] {
        let files = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !files.isEmpty {
            return files
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return [Self.writeImage(data, into: directory)].compactMap { $0 }
        }
        let links = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter(Self.isWebLink)
        if !links.isEmpty {
            return links.compactMap { Self.writeLink($0, into: directory) }
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            // An address dragged as text is still a link. Text that only
            // starts with one is text.
            if !text.contains(where: \.isWhitespace), let url = URL(string: text), Self.isWebLink(url) {
                return [Self.writeLink(url, into: directory)].compactMap { $0 }
            }
            return [Self.writeText(text, into: directory)].compactMap { $0 }
        }
        return []
    }

    func remove(_ item: TrayItem) {
        discard([item.id], message: "Removed \(item.name)")
    }

    /// The trash button: the selection, or everything.
    func discardSelectionOrAll() {
        if selection.isEmpty {
            clear()
        } else {
            let count = selection.count
            discard(selection, message: count == 1 ? "Removed 1 item" : "Removed \(count) items")
        }
    }

    /// After a drag out. Clippings stay on disk because the receiver may still
    /// be copying them; `load()` sweeps them up on the next launch.
    func remove(urls: [URL]) {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        items.removeAll { paths.contains($0.url.path) }
        save()
    }

    func clear() {
        let count = items.count
        discard(Set(items.map(\.id)), message: count == 1 ? "Cleared 1 item" : "Cleared \(count) items")
    }

    /// Clippings exist nowhere else, so a removal waits a few seconds behind
    /// Undo before their files go.
    private func discard(_ ids: Set<TrayItem.ID>, message text: String) {
        guard !ids.isEmpty else { return }
        purgeDiscarded()
        discarded = items.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { (index: $0.offset, item: $0.element) }
        items.removeAll { ids.contains($0.id) }
        save()
        canUndo = true
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.purgeDiscarded()
        }
    }

    func undoDiscard() {
        messageTask?.cancel()
        message = nil
        canUndo = false
        let restored = discarded.filter(\.item.exists)
        discarded = []
        for entry in restored.sorted(by: { $0.index < $1.index }) {
            items.insert(entry.item, at: min(entry.index, items.count))
        }
        save()
    }

    /// Ends the Undo offer now and deletes what it was holding back.
    func commitDiscard() {
        messageTask?.cancel()
        message = nil
        purgeDiscarded()
    }

    private func purgeDiscarded() {
        discarded.forEach { deleteIfClipping($0.item.url) }
        discarded = []
        canUndo = false
    }

    /// The selected items' files, or nil when nothing is selected.
    var selectedURLs: [URL]? {
        selection.isEmpty ? nil : items.filter { selection.contains($0.id) }.map(\.url)
    }

    /// What acting on `item` covers: the whole selection when it's part of it.
    func urls(actingOn item: TrayItem) -> [URL] {
        selection.contains(item.id) ? (selectedURLs ?? [item.url]) : [item.url]
    }

    /// Zips `urls`, or everything held, into one archive in the Clippings
    /// folder and holds it. The originals are untouched, and Clear deletes
    /// the archive like any clipping.
    func compressToZip(_ urls: [URL]? = nil) {
        let files = urls ?? items.map(\.url)
        guard !files.isEmpty, !isCompressing else { return }
        let destination = Self.uniqueURL(named: Self.zipName(for: files), in: clippingsDirectory)
        isCompressing = true
        Task {
            let succeeded = await Self.zip(files, to: destination)
            isCompressing = false
            if succeeded {
                hold([destination])
            } else {
                say("Couldn't compress")
            }
        }
    }

    /// "Report.zip" for one item, "Swans and 2 more.zip" for several.
    nonisolated static func zipName(for urls: [URL]) -> String {
        let first = urls.first.map { $0.deletingPathExtension().lastPathComponent } ?? "Archive"
        return urls.count == 1 ? "\(first).zip" : "\(first) and \(urls.count - 1) more.zip"
    }

    /// `name`, or "name 2", "name 3"… if taken.
    nonisolated static func uniqueURL(named name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    /// Links each item into a scratch folder under its own name and zips
    /// that, so items from different folders sit side by side in the archive
    /// without being copied first. `zip` follows the links.
    nonisolated private static func zip(_ files: [URL], to destination: URL) async -> Bool {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("NanoZip-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            var names: [String] = []
            for file in files {
                let name = uniqueURL(named: file.lastPathComponent, in: staging).lastPathComponent
                try manager.createSymbolicLink(at: staging.appendingPathComponent(name), withDestinationURL: file)
                names.append(name)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = staging
            // "--" so a name starting with a dash is not read as an option.
            process.arguments = ["-r", "-q", "-X", destination.path, "--"] + names
            return await withCheckedContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus == 0)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: false)
                }
            }
        } catch {
            return false
        }
    }

    /// Drops files that were moved or deleted since they were held.
    func pruneMissing() {
        let present = items.filter { $0.exists || $0.isOnUnmountedVolume }
        guard present.count != items.count else { return }
        items = present
        save()
    }

    func reveal(_ item: TrayItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: TrayItem) {
        NSWorkspace.shared.open(item.url)
    }

    func open(_ item: TrayItem, with application: URL) {
        NSWorkspace.shared.open(
            [item.url],
            withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    /// Puts the file itself on the clipboard, so Finder pastes a copy.
    func copy(_ item: TrayItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item.url as NSURL])
        say("Copied \(item.name)")
    }

    /// Shares exactly `urls`, or everything held when nil. The AirDrop picker
    /// is a window of Nano's, so Nano has to come forward for it to show.
    @discardableResult
    func sendViaAirDrop(_ urls: [URL]? = nil) -> Bool {
        let files = urls ?? items.map(\.url)
        guard !files.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: files)
        else {
            say("AirDrop is unavailable")
            return false
        }

        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: files)
        say("Opening AirDrop")
        return true
    }

    private func say(_ text: String) {
        purgeDiscarded()
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func deleteIfClipping(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL.path
            == clippingsDirectory.standardizedFileURL.path
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func load() {
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        items = paths
            .map { TrayItem(url: URL(fileURLWithPath: $0)) }
            .filter { $0.exists || $0.isOnUnmountedVolume }
        sweepClippings()
    }

    /// Clippings no longer held: dragged out with removal on, or left over
    /// from a crash.
    private func sweepClippings() {
        let held = Set(items.map(\.url.lastPathComponent))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: clippingsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where !held.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func save() {
        guard let storageURL,
              let data = try? JSONEncoder().encode(items.map(\.url.path))
        else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
    }

    // MARK: Turning drops into files

    private nonisolated static func isWebLink(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    /// A `.webloc`, so Finder, Safari, and every other app open it as the link.
    nonisolated static func writeLink(_ url: URL, into directory: URL) -> URL? {
        let base = url.host(percentEncoded: false) ?? "Link"
        let plist = ["URL": url.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return nil }
        return write(data, name: base, extension: "webloc", into: directory)
    }

    /// Stored as PNG whatever it arrived as, so every app can read it.
    nonisolated static func writeImage(_ data: Data, into directory: URL) -> URL? {
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        return write(png, name: "Image \(stamp())", extension: "png", into: directory)
    }

    /// Named after its first line, so it can be told apart in the tray.
    nonisolated static func writeText(_ text: String, into directory: URL) -> URL? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var base = String(firstLine.prefix(40))
        // Cut at the last whole word rather than mid-word.
        if firstLine.count > 40, let space = base.lastIndex(of: " ") {
            base = String(base[..<space])
        }
        base = base.nilIfBlank ?? "Text \(stamp())"
        return write(Data(text.utf8), name: base, extension: "txt", into: directory)
    }

    private nonisolated static func write(_ data: Data, name: String, extension ext: String, into directory: URL) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var url = directory.appendingPathComponent(safe).appendingPathExtension(ext)
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(safe) \(copy)").appendingPathExtension(ext)
            copy += 1
        }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    private nonisolated static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: .now)
    }
}

/// Quick Look previews for held files, shared by the module and the widget.
/// Images, PDFs, and videos show their contents; everything else gets the
/// icon Finder would draw.
@MainActor
enum TrayThumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, side))
    }

    static func load(_ url: URL, side: CGFloat) async -> NSImage? {
        if let image = cached(url, side: side) { return image }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: 2,
            representationTypes: .all
        )
        let image: CGImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
        guard let image else { return nil }
        let nsImage = NSImage(cgImage: image, size: CGSize(width: side, height: side))
        cache.setObject(nsImage, forKey: key(url, side))
        return nsImage
    }

    private static func key(_ url: URL, _ side: CGFloat) -> NSString {
        "\(url.path)|\(Int(side))" as NSString
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
