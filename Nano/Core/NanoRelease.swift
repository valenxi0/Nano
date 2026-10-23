import AppKit
import Foundation
import ServiceManagement

/// The running build, for the About card, bug reports, and update checks.
enum NanoAppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// "macOS 26.1 (25B78)".
    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        let build = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return build.isEmpty ? "macOS \(number)" : "macOS \(number) (\(build))"
    }
}

enum NanoLinks {
    static let repository = "valenxi0/Nano"

    /// One-time tips. Optional; nothing in Nano is unlocked by them.
    static let tip = URL(string: "https://ko-fi.com/valenxi")!
    static let sourceCode = URL(string: "https://github.com/valenxi0/Nano")!
    static let otherProjects = URL(string: "https://github.com/valenxi0?tab=repositories")!

    /// What the update checker reads: the newest published release, skipping
    /// drafts and prereleases. See `NanoUpdateChecker.Feed`.
    static let updateFeed = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// The bug form, with the version fields already filled in. Issue forms
    /// take a field's value from a query item named after its `id`.
    static var reportBug: URL {
        newIssue(template: "bug_report.yml", fields: [
            "version": "\(NanoAppInfo.version) (\(NanoAppInfo.build))",
            "macos-version": NanoAppInfo.macOSVersion,
        ])
    }

    static var requestFeature: URL {
        newIssue(template: "feature_request.yml", fields: [:])
    }

    private static func newIssue(template: String, fields: [String: String]) -> URL {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")!
        components.queryItems = [URLQueryItem(name: "template", value: template)]
            + fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
}

/// Opening Nano at login. The system's login-item record is the only source
/// of truth, so nothing is mirrored into Nano's own settings.
@MainActor
final class NanoLoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled }

    /// Registered, but the user switched Nano off under Login Items.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct NanoUpdate: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let pageURL: URL
    let notes: String?

    static let preview = NanoUpdate(
        version: "1.0.1",
        downloadURL: URL(string: "https://github.com/valenxi0/Nano/releases/download/v1.0.1/Nano-1.0.1.dmg")!,
        pageURL: URL(string: "https://github.com/valenxi0/Nano/releases/tag/v1.0.1")!,
        notes: "## What's new\n- Faster tray and a quieter Mixer"
    )
}

@MainActor
final class NanoUpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case current(checkedAt: Date)
        case noReleases(checkedAt: Date)
        case available(NanoUpdate)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let settings: NanoSettings
    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?
    private var task: Task<Void, Never>?

    /// Automatic checks run at most this often.
    static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckedKey = "updates.lastCheckedAt"

    init(settings: NanoSettings, defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.settings = settings
        self.defaults = defaults
        self.session = session
    }

    var available: NanoUpdate? {
        if case let .available(update) = status { return update }
        return nil
    }

    var lastCheckedAt: Date? {
        defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    /// Checks now if the last automatic check is a day old, then re-evaluates
    /// every few hours for Macs that stay awake for days.
    func start() {
        checkIfDue()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer.tolerance = 30 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkIfDue() {
        guard settings.checksForUpdates else { return }
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < Self.interval { return }
        checkNow()
    }

    func checkNow() {
        guard status != .checking else { return }
        status = .checking
        task = Task { [weak self] in
            guard let self else { return }
            let result = await Self.fetchLatest(from: NanoLinks.updateFeed, session: session)
            // Only an answer counts as a check. After a failure the time stays
            // as it was, so the next tick tries again.
            switch result {
            case let .success(update?):
                defaults.set(Date(), forKey: Self.lastCheckedKey)
                status = Self.isVersion(update.version, newerThan: NanoAppInfo.version)
                    ? .available(update)
                    : .current(checkedAt: Date())
            case .success(nil):
                defaults.set(Date(), forKey: Self.lastCheckedKey)
                status = .noReleases(checkedAt: Date())
            case let .failure(message):
                status = .failed(message)
            }
        }
    }

    func download() {
        guard let update = available, Self.isSecure(update.downloadURL) else { return }
        NSWorkspace.shared.open(update.downloadURL)
    }

    /// The feed is only trusted to send the browser to an https address.
    nonisolated static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    /// Compares dotted numbers, ignoring a leading "v": 0.10.0 is newer than 0.9.2.
    /// A prerelease comes before its release, so 1.0.0-beta.1 is not newer
    /// than 1.0.0. Build metadata after "+" is ignored.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> (numbers: [Int], prerelease: [String]) {
            let trimmed = String(version.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" })
            let withoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            let numbers = (pieces.first ?? "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
            let prerelease = pieces.count > 1 ? pieces[1].split(separator: ".").map(String.init) : []
            return (numbers, prerelease)
        }
        let lhs = parts(candidate)
        let rhs = parts(current)
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left > right }
        }
        // Same numbers. A release beats a prerelease of itself.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return lhs.prerelease.isEmpty && !rhs.prerelease.isEmpty
        }
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            guard index < lhs.prerelease.count else { return false }
            guard index < rhs.prerelease.count else { return true }
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber > rightNumber
            case (_?, nil): return false
            case (nil, _?): return true
            case (nil, nil): return left > right
            }
        }
        return false
    }

    struct Feed: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }

        var dmg: URL? {
            assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadURL
        }
    }

    private enum FetchResult: Sendable {
        case success(NanoUpdate?)
        case failure(String)
    }

    /// A 404 means no release is published yet (or the repository is private).
    private nonisolated static func fetchLatest(from url: URL, session: URLSession) async -> FetchResult {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nano/\(NanoAppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .success(nil) }
            guard code == 200 else { return .failure("The update server answered \(code)") }
            let feed = try JSONDecoder().decode(Feed.self, from: data)
            let download = feed.dmg ?? feed.htmlURL
            guard isSecure(download), isSecure(feed.htmlURL) else {
                return .failure("The update information couldn't be read")
            }
            let notes = feed.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(NanoUpdate(
                version: feed.tagName.drop { $0 == "v" || $0 == "V" }.description,
                downloadURL: download,
                pageURL: feed.htmlURL,
                notes: notes?.isEmpty == false ? notes : nil
            ))
        } catch is DecodingError {
            return .failure("The update information couldn't be read")
        } catch {
            return .failure("Couldn't reach GitHub")
        }
    }
}
