import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An app a setting can be scoped to.
struct VoiceDictationAppChoice: Identifiable, Hashable, Sendable {
    var bundleID: String
    var name: String

    var id: String { bundleID }

    /// Running apps plus the apps Quill has typed into, by name.
    @MainActor
    static func candidates(stats: VoiceDictationStatsStore, history: VoiceDictationHistoryStore) -> [Self] {
        var byID: [String: Self] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { continue }
            byID[bundleID] = Self(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
        for app in stats.apps() where byID[app.bundleID] == nil {
            byID[app.bundleID] = Self(bundleID: app.bundleID, name: app.name)
        }
        for entry in history.entries {
            guard let bundleID = entry.bundleID, byID[bundleID] == nil else { continue }
            byID[bundleID] = Self(bundleID: bundleID, name: entry.appName ?? bundleID)
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Any app on disk, from an open panel.
    @MainActor
    static func chooseFromDisk() -> Self? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier
        else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return Self(bundleID: bundleID, name: name)
    }
}

struct VoiceDictationAppIconView: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }
}

/// A button that opens a searchable list of apps. With `allAppsTitle`, the
/// first row clears the choice.
struct VoiceDictationAppPickerButton<Label: View>: View {
    let candidates: [VoiceDictationAppChoice]
    var allAppsTitle: String?
    let onPick: (VoiceDictationAppChoice?) -> Void
    @ViewBuilder let label: () -> Label

    @State private var isOpen = false
    @State private var query = ""

    var body: some View {
        Button {
            query = ""
            isOpen = true
        } label: {
            label()
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if candidates.count > 6 {
                    TextField("Search apps", text: $query)
                        .textFieldStyle(.roundedBorder)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if let allAppsTitle, query.isEmpty {
                            row(icon: AnyView(Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)), title: allAppsTitle) {
                                pick(nil)
                            }
                            Divider().padding(.vertical, 3)
                        }
                        ForEach(filtered) { app in
                            row(icon: AnyView(VoiceDictationAppIconView(bundleID: app.bundleID)), title: app.name) {
                                pick(app)
                            }
                        }
                        if filtered.isEmpty {
                            Text("No app matches.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(6)
                        }
                    }
                }
                .frame(maxHeight: 260)
                Divider()
                Button("Other app…") {
                    isOpen = false
                    if let app = VoiceDictationAppChoice.chooseFromDisk() { onPick(app) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 6)
            }
            .padding(10)
            .frame(width: 260)
        }
    }

    private var filtered: [VoiceDictationAppChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private func pick(_ app: VoiceDictationAppChoice?) {
        isOpen = false
        onPick(app)
    }

    private func row(icon: AnyView, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon.frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
