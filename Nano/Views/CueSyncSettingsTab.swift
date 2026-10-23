import AppKit
import SwiftUI

/// Cue › Sync: connected apps, and which folder syncs with which list.
struct CueSyncSettingsTab: View {
    @ObservedObject var sync: CueSyncEngine
    @ObservedObject var store: CueStore
    @State private var connectError: String?
    @State private var isConnecting = false
    @State private var showsServerForm = false
    @State private var serverURL = ""
    @State private var serverToken = ""
    @State private var waitsForSignIn = false
    @State private var copiedGuide = false
    @State private var showsTodoistForm = false
    @State private var todoistToken = ""

    private var remindersConnected: Bool {
        sync.connectedDestinations.contains { $0.id == RemindersDestination.record.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let held = sync.heldDeletes {
                SettingsBanner(
                    title: "Sync paused",
                    detail: "The last sync would delete \(held.count) to-dos at once. Continue if that's what you meant.",
                    action: "Continue",
                    perform: sync.continueHeldDeletes
                )
            }
            ForEach(sync.notices, id: \.self) { notice in
                SettingsBanner(title: "Sync changed", detail: notice, action: "OK") {
                    sync.dismissNotice(notice)
                }
            }

            if !sync.connectedDestinations.isEmpty {
                SettingsSection("Connected") {
                    ForEach(sync.connectedDestinations) { record in
                        SettingsRow(
                            record.name,
                            symbol: Self.symbol(for: record),
                            subtitle: statusLine(for: record),
                            subtitleIsWarning: sync.statuses[record.id]?.error != nil
                        ) {
                            Button("Disconnect") {
                                if record.kind != RemindersDestination.kind { CueSyncKeychain.setToken(nil, for: record.id) }
                                sync.disconnect(record.id)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            SettingsSection("Add an app", footer: showsServerForm || showsTodoistForm ? nil : connectError) {
                if !remindersConnected {
                    SettingsRow(
                        "Apple Reminders",
                        symbol: Self.symbol(for: RemindersDestination.record),
                        subtitle: "Two-way sync with Reminders lists, and your iPhone through iCloud."
                    ) {
                        Button(isConnecting ? "Connecting…" : "Connect") { connectReminders() }
                            .controlSize(.small)
                            .disabled(isConnecting)
                    }
                }
                if !sync.connectedDestinations.contains(where: { $0.id == TodoistDestination.record.id }) {
                    // Row and form are one item, so no divider falls between them.
                    VStack(spacing: 0) {
                        SettingsRow(
                            "Todoist",
                            symbol: Self.symbol(for: TodoistDestination.record),
                            subtitle: "Two-way sync with Todoist projects. Uses your personal API token."
                        ) {
                            if !showsTodoistForm {
                                Button("Connect…") {
                                    connectError = nil
                                    showsServerForm = false
                                    showsTodoistForm = true
                                }
                                .controlSize(.small)
                            }
                        }
                        if showsTodoistForm {
                            todoistForm
                        }
                    }
                }
                VStack(spacing: 0) {
                    SettingsRow(
                        "Custom",
                        symbol: "point.3.connected.trianglepath.dotted",
                        subtitle: "Your own app, or any app with tasks. Give its developer or coding agent the setup guide, then connect it here."
                    ) {
                        HStack(spacing: 6) {
                            Button(copiedGuide ? "Copied" : "Copy Setup Guide") { copyGuide() }
                                .help("Copies a Markdown guide that tells a coding agent how to add Cue sync to an app")
                                .disabled(CueSyncGuide.text == nil)
                            if !showsServerForm {
                                Button("Connect…") {
                                    connectError = nil
                                    showsTodoistForm = false
                                    showsServerForm = true
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                    if showsServerForm {
                        serverForm
                    }
                }
            }

            if !sync.twoWayDestinations.isEmpty {
                SettingsSection(
                    "Folders",
                    footer: "To-dos sync with every app. Apps that take them also get prompts, ideas, links and images; with the rest, use Send to… on the cue."
                ) {
                    folderRow(name: "Inbox", folderID: nil, color: .secondary)
                    ForEach(store.folders) { folder in
                        folderRow(name: folder.name, folderID: folder.id, color: folder.color)
                    }
                }
            }
        }
        .task {
            for record in sync.connectedDestinations {
                await sync.refresh(record.id)
            }
        }
    }

    private func folderRow(name: String, folderID: UUID?, color: Color) -> some View {
        let link = sync.folderLink(for: folderID)
        let label = link.map { link in
            let app = sync.connectedDestinations.first { $0.id == link.destinationID }?.name ?? "App"
            return "\(app) › \(link.projectName)"
        } ?? "Not synced"
        return HStack(spacing: 11) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu(label) {
                Button("Not synced") { sync.unlink(folderID: folderID) }
                ForEach(sync.twoWayDestinations) { record in
                    Section(record.name) {
                        ForEach(sync.projects[record.id] ?? []) { project in
                            Button(project.name) {
                                sync.link(folderID: folderID, destinationID: record.id, project: project)
                            }
                        }
                    }
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
    }

    private var serverForm: some View {
        SyncConnectForm(
            note: waitsForSignIn
                ? "Finish signing in in your browser, then come back here."
                : "No token? Leave it empty. If the app asks you to sign in, your browser opens.",
            error: connectError,
            isConnecting: isConnecting,
            canConnect: !serverURL.trimmingCharacters(in: .whitespaces).isEmpty,
            cancel: {
                showsServerForm = false
                connectError = nil
            },
            connect: connectServer
        ) {
            SyncFormField(label: "Address", prompt: "http://localhost:8765/mcp", text: $serverURL, focusesOnAppear: true)
            SyncFormField(label: "Token", prompt: "Optional", text: $serverToken, isSecure: true)
        }
    }

    private var todoistForm: some View {
        SyncConnectForm(
            note: "Find it in Todoist under Settings > Integrations > Developer.",
            link: URL(string: "https://app.todoist.com/app/settings/integrations/developer"),
            error: connectError,
            isConnecting: isConnecting,
            canConnect: !todoistToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            cancel: {
                showsTodoistForm = false
                connectError = nil
            },
            connect: connectTodoist
        ) {
            SyncFormField(label: "API token", prompt: "Paste your token", text: $todoistToken, isSecure: true, focusesOnAppear: true)
        }
    }

    private func copyGuide() {
        guard let guide = CueSyncGuide.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(guide, forType: .string)
        copiedGuide = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedGuide = false
        }
    }

    private func connectTodoist() {
        connectError = nil
        let token = todoistToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = TodoistDestination(token: token)
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                _ = try await destination.listProjects()
                CueSyncKeychain.setToken(token, for: TodoistDestination.record.id)
                sync.connect(TodoistDestination.record, destination: destination)
                showsTodoistForm = false
                todoistToken = ""
            } catch {
                connectError = error.localizedDescription
            }
        }
    }

    private func connectServer() {
        connectError = nil
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            connectError = "That isn't a server address."
            return
        }
        do {
            try MCPTaskDestination.validate(url)
        } catch {
            connectError = error.localizedDescription
            return
        }
        let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = MCPTaskDestination.recordID(for: url)
        let save: (MCPCredentials) -> Void = { CueSyncKeychain.setToken($0.encoded(), for: id) }
        isConnecting = true
        Task {
            defer {
                isConnecting = false
                waitsForSignIn = false
            }
            do {
                var destination = MCPTaskDestination(id: id, client: MCPClient(url: url, token: token))
                let info: DestinationInfo
                do {
                    info = try await destination.verify()
                    CueSyncKeychain.setToken(token, for: id)
                } catch MCPError.unauthorized where token.isEmpty {
                    // The server wants a sign-in.
                    waitsForSignIn = true
                    let credentials = try await MCPOAuth.signIn(to: url)
                    waitsForSignIn = false
                    save(credentials)
                    destination = MCPTaskDestination(
                        id: id,
                        client: MCPClient(url: url, credentials: credentials, onCredentialsChange: save)
                    )
                    info = try await destination.verify()
                }
                sync.connect(
                    CueSyncState.Destination(id: id, kind: MCPTaskDestination.kind, name: info.name, settings: ["url": url.absoluteString]),
                    destination: destination
                )
                showsServerForm = false
                serverURL = ""
                serverToken = ""
            } catch {
                connectError = error.localizedDescription
            }
        }
    }

    private static func symbol(for record: CueSyncState.Destination) -> String {
        switch record.kind {
        case RemindersDestination.kind: "checklist"
        case TodoistDestination.kind: "checkmark.circle"
        default: "point.3.connected.trianglepath.dotted"
        }
    }

    /// "Two-way · 127.0.0.1:3790 · Synced just now", or what needs doing.
    private func statusLine(for record: CueSyncState.Destination) -> String {
        let status = sync.statuses[record.id]
        if let error = status?.error { return error }
        let twoWay = status?.info?.twoWay ?? true
        var parts = [twoWay ? "Two-way" : "Send only"]
        switch (status?.info?.acceptsAllKinds ?? false, status?.info?.acceptsImages ?? false) {
        case (true, true): parts.append("Prompts and images too")
        case (true, false): parts.append("Prompts too")
        case (false, true): parts.append("Images too")
        case (false, false): break
        }
        if record.kind == MCPTaskDestination.kind,
           let url = record.settings["url"].flatMap(URL.init(string:)), let host = url.host {
            parts.append(url.port.map { "\(host):\($0)" } ?? host)
        }
        if twoWay, !sync.state.folderLinks.contains(where: { $0.destinationID == record.id }) {
            parts.append("Link a folder below to start syncing")
        } else if status?.isSyncing == true {
            parts.append("Syncing…")
        } else if let last = status?.lastSync {
            parts.append("Synced \(Self.relative(last))")
        }
        return parts.joined(separator: " · ")
    }

    private static func relative(_ date: Date) -> String {
        let now = Date()
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    private func connectReminders() {
        connectError = nil
        isConnecting = true
        let reminders = RemindersDestination()
        Task {
            defer { isConnecting = false }
            do {
                if try await reminders.requestAccess() {
                    sync.connect(RemindersDestination.record, destination: reminders)
                } else {
                    connectError = "Nano isn't allowed to use Reminders. Turn it on in System Settings > Privacy & Security > Reminders."
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } catch {
                connectError = error.localizedDescription
            }
        }
    }
}

/// A connect form that opens under its app's row: labeled fields, a note,
/// an inline error, then Cancel and Connect.
struct SyncConnectForm<Fields: View>: View {
    let note: String
    var link: URL?
    let error: String?
    let isConnecting: Bool
    let canConnect: Bool
    let cancel: () -> Void
    let connect: () -> Void
    @ViewBuilder let fields: Fields

    /// Lines up with the row title: 12 padding, 24 icon tile, 11 spacing.
    static var inset: CGFloat { 47 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                fields
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 4) {
                    Text(note)
                    if let link {
                        Link("Open", destination: link)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(isConnecting ? "Connecting…" : "Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConnecting || !canConnect)
            }
            .controlSize(.small)
        }
        .padding(.leading, Self.inset)
        .padding(.trailing, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }
}

/// A label and a plain rounded field. The prompt is shown verbatim, so an
/// example address is not turned into a link.
struct SyncFormField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var isSecure = false
    var focusesOnAppear = false
    @FocusState private var focused: Bool

    private var promptText: Text {
        Text(verbatim: prompt).foregroundStyle(Color.primary.opacity(0.3))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Group {
                if isSecure {
                    SecureField(text: $text, prompt: promptText) { Text(label) }
                } else {
                    TextField(text: $text, prompt: promptText) { Text(label) }
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($focused)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? SettingsChrome.accent : Color.primary.opacity(0.12), lineWidth: focused ? 1.5 : 0.5)
            }
            .animation(.easeOut(duration: 0.12), value: focused)
        }
        .onAppear {
            guard focusesOnAppear else { return }
            Task { @MainActor in focused = true }
        }
    }
}

/// `docs/cue-sync.md`, bundled with the app: what an app needs to add for
/// Cue to sync with it, written for the coding agent who adds it.
enum CueSyncGuide {
    static var text: String? {
        Bundle.main.url(forResource: "cue-sync", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
