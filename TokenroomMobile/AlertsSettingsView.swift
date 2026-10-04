import SwiftUI
import UserNotifications

struct AlertsSettingsView: View {
    @Bindable var store: MobileStore
    @State private var permission: UNAuthorizationStatus?
    @State private var permissionError: String?
    @State private var requestingPermission = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            if let permission, permission != .authorized, permission != .provisional, permission != .ephemeral {
                Section {
                    Label(permission == .denied ? "Notifications are off for Tokenroom" : "Notifications aren't on yet", systemImage: "bell.slash")
                    Button(permission == .denied ? "Open Settings" : "Turn On Notifications") {
                        if permission == .denied {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                openURL(url)
                            }
                        } else {
                            requestPermission()
                        }
                    }
                    .disabled(requestingPermission)
                } footer: {
                    Text(permissionError ?? "Tokenroom can't alert you until notifications are allowed.")
                }
            }

            Section {
                ForEach(AlertPreferences.supportedThresholds, id: \.self) { level in
                    Toggle("\(level)% used", isOn: threshold(level, \.sessionThresholds))
                }
                Toggle("Before it runs out", isOn: $store.alertPreferences.sessionRunsOut)
            } header: {
                Text("5-hour limits")
            } footer: {
                Text("\"Before it runs out\" alerts when the pace so far would use the limit up before it resets, once at least half is used.")
            }

            Section {
                ForEach(AlertPreferences.supportedThresholds, id: \.self) { level in
                    Toggle("\(level)% used", isOn: threshold(level, \.thresholds))
                }
                Toggle(isOn: $store.alertPreferences.limitRunsOut) {
                    Text("Before it runs out")
                    Text("At least a day early")
                }
            } header: {
                Text("Weekly and monthly limits")
            }

            Section {
                Toggle("A busy window resets", isOn: $store.alertPreferences.resets)
                Toggle("Banked resets", isOn: $store.alertPreferences.banked)
                Toggle("A balance or budget runs low", isOn: $store.alertPreferences.lowBalance)
                Toggle("New models from labs you follow", isOn: $store.alertPreferences.newModels)
            } header: {
                Text("Also notify me when")
            } footer: {
                Text("Once per window, whichever device notices first. \"A busy window resets\" means one that reached 80%. Banked resets alert when one is added and before it expires. Low balance needs a reference or budget in API Keys. Your Macs share these choices through iCloud; a change on either applies to both.")
            }

            Section {
                Toggle("Quiet Hours", isOn: $store.alertPreferences.quietHours)
                if store.alertPreferences.quietHours {
                    Picker("From", selection: $store.alertPreferences.quietStartHour) {
                        ForEach(0..<24, id: \.self) { Text(hourText($0)).tag($0) }
                    }
                    Picker("To", selection: $store.alertPreferences.quietEndHour) {
                        ForEach(0..<24, id: \.self) { Text(hourText($0)).tag($0) }
                    }
                }
            } footer: {
                Text("During quiet hours only 95% alerts, limits that run out within the hour, and banked resets about to expire come through; the rest arrive when quiet hours end. Your Macs follow these hours too.")
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await checkPermission() }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings with notifications turned on.
            if phase == .active {
                Task { await checkPermission() }
            }
        }
    }

    private func checkPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if permission == .authorized || permission == .provisional || permission == .ephemeral {
            permissionError = nil
        }
    }

    private func requestPermission() {
        guard !requestingPermission else { return }
        requestingPermission = true
        permissionError = nil
        Task {
            defer { requestingPermission = false }
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                permissionError = "Couldn't turn on notifications. Try again or allow notifications for Tokenroom in Settings."
            }
            await checkPermission()
        }
    }

    private func threshold(_ level: Int, _ keyPath: WritableKeyPath<AlertPreferences, [Int]>) -> Binding<Bool> {
        Binding(
            get: { store.alertPreferences[keyPath: keyPath].contains(level) },
            set: { isOn in
                var levels = Set(store.alertPreferences[keyPath: keyPath])
                if isOn { levels.insert(level) } else { levels.remove(level) }
                store.alertPreferences[keyPath: keyPath] = levels.sorted()
            }
        )
    }

    private func hourText(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
    }
}
