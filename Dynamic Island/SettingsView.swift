import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onRecheckAutomation: () -> Void

    var body: some View {
        ScrollView {
            Form {
            Section("AI chat monitoring") {
                Text("The island watches open Claude, ChatGPT, and Gemini tabs in Google Chrome and drops a banner when a reply finishes. It does not call those APIs. For instant alerts, install the bundled Chrome helper (one-time). Until then it polls via AppleScript — enable View → Developer → Allow JavaScript from Apple Events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Reply detection") {
                    Text(settings.chromeHelperConnected ? "Helper (instant)" : "Polling")
                        .foregroundStyle(settings.chromeHelperConnected ? Color.secondary : Color.orange)
                }

                LabeledContent("Helper") {
                    Text(settings.chromeHelperStatus)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                Button("Install Chrome Helper…") {
                    _ = ChromeHelperInstaller.install(openExtensionsPage: true)
                }

                Text("In Chrome: turn on Developer mode → Load unpacked → select the Dynamic Island ChromeHelper folder that opens in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Automation") {
                    Text(automationStatusText)
                        .foregroundStyle(settings.automationDenied ? .orange : .secondary)
                }

                LabeledContent("Last check") {
                    Text(settings.chromePollStatus)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                Button("Preview Claude") {
                    NotificationCenter.default.post(
                        name: .previewChatReady,
                        object: nil,
                        userInfo: ["provider": ChatProvider.claude.rawValue]
                    )
                }
                Button("Preview ChatGPT") {
                    NotificationCenter.default.post(
                        name: .previewChatReady,
                        object: nil,
                        userInfo: ["provider": ChatProvider.chatgpt.rawValue]
                    )
                }
                Button("Preview Gemini") {
                    NotificationCenter.default.post(
                        name: .previewChatReady,
                        object: nil,
                        userInfo: ["provider": ChatProvider.gemini.rawValue]
                    )
                }
                if settings.automationDenied {
                    Text("macOS blocked this app from controlling Google Chrome. Enable it in System Settings → Privacy & Security → Automation, then Recheck.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Automation Settings") {
                        settings.openAutomationSettings()
                    }
                    Button("Recheck permission") {
                        onRecheckAutomation()
                    }
                }

                if settings.needsChromeJavaScriptFromAppleEvents {
                    Text("Chrome is blocking page reads. In Google Chrome’s menu bar, turn on View → Developer → Allow JavaScript from Apple Events, then send a message again.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Recheck after enabling") {
                        onRecheckAutomation()
                    }
                }
            }

            Section("Battery") {
                Text("Plug in to show Charging; at 20% and 10% unplugged the island shows Low Battery. Use these to preview the banners.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview Charging") {
                    NotificationCenter.default.post(name: .previewCharging, object: nil)
                }
                Button("Preview Low Battery") {
                    NotificationCenter.default.post(name: .previewLowBattery, object: nil)
                }
            }

            Section("Sound & brightness") {
                Text("Volume and brightness keys always change the level. When Accessibility is granted, the island shows the banner and hides the gray macOS HUD. Grant Accessibility in System Settings if the status below is orange — the app will not show Apple’s permission sheet on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Keyboard HUD") {
                    Text(settings.mediaKeysCaptured ? "Island only" : "System HUD still showing")
                        .foregroundStyle(settings.mediaKeysCaptured ? Color.secondary : Color.orange)
                }
                if !settings.mediaKeysCaptured {
                    Button("Open Accessibility Settings") {
                        settings.openAccessibilitySettings()
                    }
                    Button("Recheck after enabling") {
                        VolumeBrightnessMonitor.shared.retryMediaKeyTap()
                    }
                }
                Button("Preview Sound") {
                    NotificationCenter.default.post(name: .previewSound, object: nil)
                }
                Button("Preview Brightness") {
                    NotificationCenter.default.post(name: .previewBrightness, object: nil)
                }
            }

            Section("Focus") {
                Text("Turning Focus on or off in Control Center shows a short island banner: Focus mode on the left, On or Off on the right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview Focus On") {
                    NotificationCenter.default.post(
                        name: .previewFocusMode,
                        object: nil,
                        userInfo: ["isOn": true]
                    )
                }
                Button("Preview Focus Off") {
                    NotificationCenter.default.post(
                        name: .previewFocusMode,
                        object: nil,
                        userInfo: ["isOn": false]
                    )
                }
            }

            Section("File shelf") {
                Text("Drop a screenshot, recording, or any Finder file onto the notch to hold it. Drag it out later to copy it somewhere else. The island never deletes the original file. Drag-out copies by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Hold dropped files in the notch", isOn: $settings.shelfEnabled)
                Toggle("Remove held items after a while", isOn: $settings.shelfAutoExpireEnabled)
                    .disabled(!settings.shelfEnabled)
                if settings.shelfAutoExpireEnabled {
                    Picker("Remove after", selection: $settings.shelfAutoExpireMinutes) {
                        Text("15 minutes").tag(15)
                        Text("1 hour").tag(60)
                        Text("6 hours").tag(360)
                        Text("24 hours").tag(1440)
                    }
                    .disabled(!settings.shelfEnabled)
                }
                Text("Preview the holding tray on the notch. Sample files are references only and are not your real screenshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview held files") {
                    NotificationCenter.default.post(name: .previewShelfHold, object: nil)
                }
                Button("Preview drop-here") {
                    NotificationCenter.default.post(name: .previewShelfDrop, object: nil)
                }
                Button("Clear shelf preview") {
                    NotificationCenter.default.post(name: .previewShelfClear, object: nil)
                }
            }

            Section("Screen recording") {
                Text("Screen Recording: red dot while capturing, hover to expand and stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview Screen Recording") {
                    NotificationCenter.default.post(name: .previewScreenRecording, object: nil)
                }
            }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private var automationStatusText: String {
        if settings.automationDenied {
            return "Denied"
        }
        if settings.automationGranted {
            return "Granted"
        }
        return "Not granted yet"
    }
}
