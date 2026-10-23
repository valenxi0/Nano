import AppKit
import SwiftUI

extension NanoSetupChecklist {
    @MainActor
    static func current(
        settings: NanoSettings,
        viewModel: IslandViewModel,
        fullDiskAccess: Bool,
        accessibilityTrusted: Bool = NanoAccessibilityPermission.isTrusted,
        hooksInstalled: Bool = !AgentHookBridge.installedHookConfigURLs().isEmpty
    ) -> NanoSetupChecklist {
        NanoSetupChecklist(Facts(
            agentsEnabled: settings.isEnabled(.agents),
            hookableAgentsFound: !AgentHookBridge.installationProviders(settings.enabledAgentProviders).isEmpty,
            hooksInstalled: hooksInstalled,
            accessibilityTrusted: accessibilityTrusted,
            voiceEnabled: settings.isEnabled(.voiceDictation),
            microphoneAuthorized: viewModel.voiceDictation.microphoneAuthorization == .authorized,
            voiceModelReady: viewModel.voiceDictation.modelStore.isReady(settings.voiceDictationEngine),
            systemNotificationsEnabled: settings.isNotificationEnabled(.system),
            fullDiskAccess: fullDiskAccess
        ))
    }

    /// Permission items resolve in place. Hooks and models need their own
    /// screen, so callers route those.
    @MainActor
    static func perform(_ item: Item, viewModel: IslandViewModel) {
        switch item {
        case .allowMicrophone:
            if viewModel.voiceDictation.microphoneAuthorization == .notDetermined {
                viewModel.voiceDictation.requestMicrophoneAccess()
            } else {
                NanoPrivacySettings.open(NanoPermissionKind.microphone.settingsAnchor)
            }
        case .allowFullDiskAccess:
            NanoPrivacySettings.open(NanoPermissionKind.fullDisk.settingsAnchor)
        case .allowSessionJump, .allowAutoPaste:
            if !NanoAccessibilityPermission.requestIfNeeded() {
                NanoPrivacySettings.open(NanoPermissionKind.accessibility.settingsAnchor)
            }
        case .connectAgents, .downloadVoiceModel:
            break
        }
    }
}

struct NanoSetupChecklistRow: View {
    let item: NanoSetupChecklist.Item
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.isOptional ? Color.secondary : SettingsChrome.accent)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((item.isOptional ? Color.secondary : SettingsChrome.accent).opacity(0.12))
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 13, weight: .semibold))
                    if item.isOptional {
                        Text("Optional").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
        }
        .padding(.vertical, 10)
    }

    private var actionTitle: String {
        switch item {
        case .connectAgents: "Connect"
        case .downloadVoiceModel: "Download"
        case .allowFullDiskAccess: "Open"
        default: "Allow"
        }
    }
}

/// Persistent reminder in Settings for setup the user skipped. It appears
/// only while something required is still open.
struct NanoSetupChecklistCard: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    let open: (SettingsDestination) -> Void

    @State private var fullDiskAccess = true

    var body: some View {
        let checklist = NanoSetupChecklist.current(
            settings: settings,
            viewModel: viewModel,
            fullDiskAccess: fullDiskAccess
        )
        Group {
            if settings.onboardingCompleted, checklist.hasRequiredItems {
                SettingsCard(spacing: 0) {
                    SettingsGroupTitle(title: "Finish setting up", detail: "A few things from setup are still open.")
                        .padding(.bottom, 6)
                    ForEach(Array(checklist.items.enumerated()), id: \.element) { index, item in
                        NanoSetupChecklistRow(item: item) {
                            switch item {
                            case .connectAgents: open(.agents)
                            case .downloadVoiceModel: open(.voiceDictation)
                            default: NanoSetupChecklist.perform(item, viewModel: viewModel)
                            }
                        }
                        if index < checklist.items.count - 1 { Divider().opacity(0.45) }
                    }
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        fullDiskAccess = await Task.detached(priority: .utility) {
            NotificationCenterStore.storeIsReadable || NanoFullDiskAccess.hasAccess
        }.value
    }
}
