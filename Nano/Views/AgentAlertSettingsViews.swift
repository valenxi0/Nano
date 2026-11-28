import AppKit
import SwiftUI

/// Sounds, quiet conditions and reminders on the Agents settings page.
struct AgentAlertSettingsSections: View {
    @ObservedObject var settings: NanoSettings
    let alerts: AgentAlertCenter

    /// Usage alerts get their sound with the usage settings themselves.
    private static let soundEvents: [AgentAlertEvent] = [.approval, .question, .completion]

    var body: some View {
        Group {
            SettingsSection(
                "Sounds",
                footer: "Plays when an agent card appears. Cards show either way."
            ) {
                SettingsToggleRow(
                    "Play sounds",
                    subtitle: "When an agent needs you or finishes.",
                    isOn: $settings.agentAlerts.soundsEnabled
                )
                ForEach(Self.soundEvents) { event in
                    SettingsRow(event.title) {
                        soundControls(for: event)
                    }
                    .disabled(!settings.agentAlerts.soundsEnabled)
                }
            }
            .settingsAnchor("agents.alerts.sounds")

            SettingsSection(
                "Quiet",
                footer: "Quiet mutes sounds and reminders. Cards still show."
            ) {
                SettingsToggleRow("Quiet hours", isOn: $settings.agentAlerts.quietSchedule.isEnabled)
                SettingsRow("Hours") {
                    HStack(spacing: 6) {
                        timePicker("From", minutes: $settings.agentAlerts.quietSchedule.startMinute)
                        Text("to").foregroundStyle(.secondary)
                        timePicker("To", minutes: $settings.agentAlerts.quietSchedule.endMinute)
                    }
                }
                .disabled(!settings.agentAlerts.quietSchedule.isEnabled)
                SettingsToggleRow(
                    "While the screen is locked",
                    isOn: $settings.agentAlerts.quietWhenScreenLocked
                )
                SettingsToggleRow(
                    "While another app uses the microphone",
                    subtitle: "Calls and meetings. Dictating with Quill doesn't count.",
                    isOn: $settings.agentAlerts.quietWhenMicrophoneInUse
                )
            }
            .settingsAnchor("agents.alerts.quiet")

            SettingsSection(
                "Usage alerts",
                footer: "Checked whenever usage refreshes. One alert per window until it resets."
            ) {
                SettingsToggleRow(
                    "Alert when a limit runs low",
                    subtitle: "Shows a card when a 5h, 7d or plan window passes the line.",
                    isOn: $settings.agentAlerts.usageAlertsEnabled
                )
                Group {
                    SettingsRow("Alert at") {
                        Picker("Alert at", selection: $settings.agentAlerts.usageThreshold) {
                            ForEach(AgentAlertPreferences.usageThresholdChoices, id: \.self) { percent in
                                Text("\(percent)% used").tag(percent)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    SettingsToggleRow(
                        "Tell me when it resets",
                        isOn: $settings.agentAlerts.usageResetAlerts
                    )
                    SettingsRow(AgentAlertEvent.usage.title) {
                        soundControls(for: .usage)
                    }
                    .disabled(!settings.agentAlerts.soundsEnabled)
                }
                .disabled(!settings.agentAlerts.usageAlertsEnabled)
            }
            .settingsAnchor("agents.alerts.usage")

            SettingsSection("Reminders") {
                SettingsToggleRow(
                    "Remind me about unanswered requests",
                    subtitle: "Shows the approval or question again with its sound, up to \(AgentAlertPreferences.maximumReminders) times.",
                    isOn: $settings.agentAlerts.remindersEnabled
                )
                SettingsRow("Every") {
                    Picker("Every", selection: $settings.agentAlerts.reminderMinutes) {
                        ForEach(AgentAlertPreferences.reminderChoices, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .disabled(!settings.agentAlerts.remindersEnabled)
            }
            .settingsAnchor("agents.alerts.reminders")
        }
    }

    private func soundControls(for event: AgentAlertEvent) -> some View {
        let current = settings.agentAlerts.sound(for: event)
        return HStack(spacing: 6) {
            Menu(current.title) {
                Button("None") { set(.none, for: event) }
                Divider()
                ForEach(AgentAlertSound.systemNames, id: \.self) { name in
                    Button(name) { set(.system(name), for: event) }
                }
                Divider()
                Button("Choose File…") { chooseFile(for: event) }
                if current != event.defaultSound {
                    Button("Use Default (\(event.defaultSound.title))") { set(event.defaultSound, for: event) }
                }
            }
            .fixedSize()
            Button {
                alerts.preview(current)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(current == .none)
            .help("Play \(current.title)")
            .accessibilityLabel("Play \(event.title) sound")
        }
        .controlSize(.small)
    }

    private func set(_ sound: AgentAlertSound, for event: AgentAlertEvent) {
        settings.agentAlerts.setSound(sound, for: event)
        alerts.preview(sound)
    }

    private func chooseFile(for event: AgentAlertEvent) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a sound for “\(event.title)”"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(.file(url.path), for: event)
    }

    private func timePicker(_ label: String, minutes: Binding<Int>) -> some View {
        DatePicker(
            label,
            selection: Binding(
                get: {
                    Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60))
                },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .fixedSize()
    }
}
