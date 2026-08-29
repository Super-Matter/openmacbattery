import SwiftUI
import AppKit
import OpenMacBatteryCore

struct SettingsView: View {
    @State private var daemonRunning: Bool = DaemonInstaller.isRunning()
    @State private var working: Bool = false
    @State private var message: LocalizedStringKey? = nil

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background tracking")
                            .font(.headline)
                        Text(daemonRunning
                             ? "On — apps are sampled every minute."
                             : "Off — no new data being collected.")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Toggle("", isOn: Binding(get: { daemonRunning },
                                                 set: { newVal in toggleDaemon(newVal) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                if let m = message {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Tracking")
            }

            Section {
                LinkButton(title: "Open log (Console.app)", systemImage: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: DaemonInstaller.logPath))
                }
                LinkButton(title: "Open error log", systemImage: "exclamationmark.bubble") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: DaemonInstaller.errorLogPath))
                }
                LinkButton(title: "Open data folder", systemImage: "folder") {
                    let dbDir = (Database.defaultPath() as NSString).deletingLastPathComponent
                    NSWorkspace.shared.open(URL(fileURLWithPath: dbDir))
                }
            } header: {
                Text("Diagnostics")
            }

            Section {
                Button(role: .destructive) {
                    DaemonInstaller.uninstall()
                    daemonRunning = false
                    message = "Background tracking removed."
                } label: {
                    Label("Remove background tracking entirely", systemImage: "trash")
                }
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
        .onAppear { daemonRunning = DaemonInstaller.isRunning() }
    }

    private func toggleDaemon(_ enable: Bool) {
        working = true
        message = nil
        Task.detached {
            do {
                if enable {
                    try DaemonInstaller.install(binaryPath: embeddedCLIPath())
                    await MainActor.run {
                        daemonRunning = true; working = false
                        message = "Enabled."
                    }
                } else {
                    DaemonInstaller.uninstall()
                    await MainActor.run {
                        daemonRunning = false; working = false
                        message = "Disabled."
                    }
                }
            } catch {
                await MainActor.run {
                    working = false
                    message = "Error"
                }
            }
        }
    }
}

struct LinkButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
