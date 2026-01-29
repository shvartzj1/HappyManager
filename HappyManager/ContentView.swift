import SwiftUI
import ServiceManagement

struct ContentView: View {
    @ObservedObject var configStore = ConfigStore.shared
    @ObservedObject var processManager = ProcessManager.shared
    @State private var showingFolderPicker = false
    @State private var launchAtLogin = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "face.smiling.inverse")
                    .font(.title2)
                    .foregroundColor(.green)
                Text("Happy Manager")
                    .font(.headline)
                Spacer()
                StatusBadge(running: processManager.runningCount, total: processManager.totalCount)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Folder list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(configStore.folders) { folder in
                        FolderRow(folder: folder)
                    }

                    if configStore.folders.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No folders configured")
                                .foregroundColor(.secondary)
                            Text("Add a dev folder to get started")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 300)

            Divider()

            // Actions
            VStack(spacing: 12) {
                Button(action: { showingFolderPicker = true }) {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 12) {
                    Button(action: { processManager.startAll() }) {
                        Label("Start All", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: { processManager.stopAll() }) {
                        Label("Stop All", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(newValue)
                    }

                Divider()

                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit Happy Manager")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .frame(width: 380)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    // Access security-scoped resource
                    if url.startAccessingSecurityScopedResource() {
                        configStore.addFolder(url.path)
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                processManager.startAll()
            case .failure(let error):
                print("Folder selection error: \(error)")
            }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set launch at login: \(error)")
        }
    }
}

struct StatusBadge: View {
    let running: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(running == total && total > 0 ? Color.green : (running > 0 ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text("\(running)/\(total)")
                .font(.caption)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct FolderRow: View {
    @ObservedObject var configStore = ConfigStore.shared
    @ObservedObject var processManager = ProcessManager.shared
    let folder: FolderConfig

    @State private var isExpanded = false

    var folderStatuses: [InstanceStatus] {
        processManager.statuses.values.filter { $0.folderId == folder.id }.sorted { $0.instanceIndex < $1.instanceIndex }
    }

    var runningCount: Int {
        folderStatuses.filter { $0.isRunning }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { folder.isEnabled },
                    set: { newValue in
                        var updated = folder
                        updated.isEnabled = newValue
                        configStore.updateFolder(updated)
                        if newValue {
                            processManager.startAll()
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.folderName)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Text(folder.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Instance count stepper
                HStack(spacing: 4) {
                    Text("×")
                        .foregroundColor(.secondary)
                    Stepper(value: Binding(
                        get: { folder.instanceCount },
                        set: { newValue in
                            var updated = folder
                            updated.instanceCount = max(1, min(10, newValue))
                            configStore.updateFolder(updated)
                            processManager.startAll()
                        }
                    ), in: 1...10) {
                        Text("\(folder.instanceCount)")
                            .monospacedDigit()
                            .frame(width: 20)
                    }
                    .labelsHidden()
                }

                // Status indicator
                Circle()
                    .fill(runningCount == folder.instanceCount ? Color.green : (runningCount > 0 ? Color.orange : Color.red))
                    .frame(width: 10, height: 10)

                // Expand button
                Button(action: { withAnimation { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                // Remove button
                Button(action: {
                    // Stop instances first
                    for status in folderStatuses {
                        processManager.stopInstance(instanceId: status.id)
                    }
                    configStore.removeFolder(folder.id)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)

            if isExpanded {
                Divider()

                VStack(spacing: 4) {
                    ForEach(folderStatuses) { status in
                        InstanceRow(status: status, folderName: folder.folderName)
                    }

                    if folderStatuses.isEmpty {
                        Text("No instances")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(10)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct InstanceRow: View {
    @ObservedObject var processManager = ProcessManager.shared
    let status: InstanceStatus
    let folderName: String

    var body: some View {
        HStack {
            Circle()
                .fill(status.isRunning ? Color.green : Color.red)
                .frame(width: 6, height: 6)

            Text("Instance \(status.instanceIndex + 1)")
                .font(.caption)

            if let pid = status.pid {
                Text("PID: \(pid)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if status.restartCount > 0 {
                Text("(\(status.restartCount) restarts)")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            Spacer()

            if let error = status.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }

            Button(action: {
                AppDelegate.shared?.openTerminalWindow(
                    instanceId: status.id,
                    title: "\(folderName) - Instance \(status.instanceIndex + 1)"
                )
            }) {
                Image(systemName: "terminal")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Button(action: {
                processManager.restartInstance(instanceId: status.id)
            }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
