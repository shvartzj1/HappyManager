import Foundation
import Combine

class ProcessManager: ObservableObject {
    static let shared = ProcessManager()

    @Published var statuses: [UUID: InstanceStatus] = [:]
    @Published var outputBuffers: [UUID: String] = [:]
    private var processes: [UUID: Process] = [:]
    private var ptyReaders: [UUID: DispatchSourceRead] = [:]
    private var masterFds: [UUID: Int32] = [:]
    private let maxBufferSize = 50000  // ~50KB per instance rolling buffer
    private var monitorTimer: Timer?
    private var titleRefreshTimer: Timer?
    private let maxRestartAttempts = 3
    private let configStore = ConfigStore.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Kill any orphaned happy processes from previous runs
        killOrphanedHappyProcesses()

        // Clean up old log files (older than 1 hour)
        cleanupOldLogs(olderThanMinutes: 60)

        // Observe config changes
        configStore.$folders
            .sink { [weak self] _ in
                self?.syncInstances()
            }
            .store(in: &cancellables)

        // Start monitoring timer
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkProcesses()
        }

        // Refresh titles from daemon API every 5 seconds
        titleRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshTitlesFromDaemon()
        }
    }

    // MARK: - Orphan Cleanup

    private func killOrphanedHappyProcesses() {
        // Query daemon for all sessions and kill them
        queryDaemonSessions { [weak self] sessions in
            for session in sessions {
                print("Killing orphaned happy process PID: \(session.pid)")
                // Delete logs for this PID before killing
                self?.deleteLogsForPid(Int32(session.pid))
                kill(Int32(session.pid), SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    kill(Int32(session.pid), SIGKILL)
                }
            }
        }

        // Also kill any node processes running happy that we might have missed
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "happy-coder.*--permission-mode"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let pids = output.split(separator: "\n").compactMap { Int32($0) }
                for pid in pids {
                    print("Killing orphaned node/happy process PID: \(pid)")
                    // Delete logs for this PID before killing
                    deleteLogsForPid(pid)
                    kill(pid, SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        kill(pid, SIGKILL)
                    }
                }
            }
        } catch {
            print("Failed to find orphaned processes: \(error)")
        }
    }

    // MARK: - Log Cleanup

    private func deleteLogsForPid(_ pid: Int32) {
        let logsDir = "\(NSHomeDirectory())/.happy/logs"
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(atPath: logsDir) else { return }

        // Find and delete log files containing this PID
        // Log format: YYYY-MM-DD-HH-MM-SS-pid-XXXXX.log
        let pidPattern = "pid-\(pid)"
        for file in files {
            if file.contains(pidPattern) && file.hasSuffix(".log") {
                let path = "\(logsDir)/\(file)"
                do {
                    try fm.removeItem(atPath: path)
                    print("Deleted log file: \(file)")
                } catch {
                    print("Failed to delete log \(file): \(error)")
                }
            }
        }
    }

    private func deleteLogsForChildPids(parentPid: Int32) {
        // Find all child PIDs and delete their logs
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(parentPid)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let childPids = output.split(separator: "\n").compactMap { Int32($0) }
                for childPid in childPids {
                    deleteLogsForPid(childPid)
                    deleteLogsForChildPids(parentPid: childPid) // Recursive for grandchildren
                }
            }
        } catch {
            print("Failed to find child PIDs for log cleanup: \(error)")
        }
    }

    private func cleanupOldLogs(olderThanMinutes: Int) {
        let logsDir = "\(NSHomeDirectory())/.happy/logs"
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(atPath: logsDir) else { return }

        let cutoffDate = Date().addingTimeInterval(-Double(olderThanMinutes * 60))
        var deletedCount = 0
        var freedBytes: UInt64 = 0

        for file in files {
            guard file.hasSuffix(".log") else { continue }

            let path = "\(logsDir)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date,
                  let fileSize = attrs[.size] as? UInt64 else { continue }

            // Delete if older than cutoff
            if modDate < cutoffDate {
                do {
                    try fm.removeItem(atPath: path)
                    deletedCount += 1
                    freedBytes += fileSize
                } catch {
                    print("Failed to delete old log \(file): \(error)")
                }
            }
        }

        if deletedCount > 0 {
            let freedMB = Double(freedBytes) / 1_000_000
            print("Cleaned up \(deletedCount) old log files, freed \(String(format: "%.1f", freedMB)) MB")
        }
    }

    // MARK: - Daemon API

    private struct DaemonSession {
        let pid: Int
        let happySessionId: String
    }

    private func getDaemonPort() -> Int? {
        let stateFile = "\(NSHomeDirectory())/.happy/daemon.state.json"
        guard let data = FileManager.default.contents(atPath: stateFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["httpPort"] as? Int else {
            return nil
        }
        return port
    }

    private func queryDaemonSessions(completion: @escaping ([DaemonSession]) -> Void) {
        guard let port = getDaemonPort() else {
            completion([])
            return
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/list")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let children = json["children"] as? [[String: Any]] else {
                completion([])
                return
            }

            let sessions = children.compactMap { child -> DaemonSession? in
                guard let pid = child["pid"] as? Int,
                      let sessionId = child["happySessionId"] as? String else {
                    return nil
                }
                return DaemonSession(pid: pid, happySessionId: sessionId)
            }
            completion(sessions)
        }.resume()
    }

    private func refreshTitlesFromDaemon() {
        // For now, titles aren't exposed via daemon API
        // This is a placeholder for future enhancement
        // The daemon /list endpoint returns pid and sessionId but not title
    }

    // MARK: - Instance Management

    func startAllConfigured() {
        syncInstances()
    }

    private func syncInstances() {
        let folders = configStore.folders.filter { $0.isEnabled }

        // Build expected instance IDs
        var expectedIds = Set<UUID>()

        for folder in folders {
            for i in 0..<folder.instanceCount {
                let instanceId = makeInstanceId(folderId: folder.id, index: i)
                expectedIds.insert(instanceId)

                // Start if not already running
                if statuses[instanceId] == nil {
                    var status = InstanceStatus(id: instanceId, folderId: folder.id, instanceIndex: i)
                    statuses[instanceId] = status
                    startInstance(instanceId: instanceId, folder: folder, status: &status)
                    statuses[instanceId] = status
                }
            }
        }

        // Stop instances that shouldn't be running
        for (instanceId, _) in statuses {
            if !expectedIds.contains(instanceId) {
                stopInstance(instanceId: instanceId)
                statuses.removeValue(forKey: instanceId)
            }
        }
    }

    private func makeInstanceId(folderId: UUID, index: Int) -> UUID {
        // Create deterministic UUID based on folder and index
        let string = "\(folderId.uuidString)-\(index)"
        let hash = string.utf8.reduce(0) { $0 &+ UInt64($1) }
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: hash),
            UInt8(truncatingIfNeeded: hash >> 8),
            UInt8(truncatingIfNeeded: hash >> 16),
            UInt8(truncatingIfNeeded: hash >> 24),
            UInt8(truncatingIfNeeded: hash >> 32),
            UInt8(truncatingIfNeeded: hash >> 40),
            UInt8(truncatingIfNeeded: hash >> 48),
            UInt8(truncatingIfNeeded: hash >> 56),
            UInt8(truncatingIfNeeded: hash),
            UInt8(truncatingIfNeeded: hash >> 8),
            UInt8(truncatingIfNeeded: hash >> 16),
            UInt8(truncatingIfNeeded: hash >> 24),
            UInt8(truncatingIfNeeded: hash >> 32),
            UInt8(truncatingIfNeeded: hash >> 40),
            UInt8(truncatingIfNeeded: hash >> 48),
            UInt8(truncatingIfNeeded: hash >> 56)
        ))
    }

    private func startInstance(instanceId: UUID, folder: FolderConfig, status: inout InstanceStatus) {
        // Create pseudo-terminal with proper window size
        var masterFd: Int32 = 0
        var slaveFd: Int32 = 0

        // Set up terminal size (wide for Claude Code)
        var winSize = winsize()
        winSize.ws_row = 50
        winSize.ws_col = 160
        winSize.ws_xpixel = 0
        winSize.ws_ypixel = 0

        // Open PTY master/slave pair with window size
        guard openpty(&masterFd, &slaveFd, nil, nil, &winSize) == 0 else {
            status.isRunning = false
            status.lastError = "Failed to create PTY"
            return
        }

        let process = Process()

        // Use login shell with nvm - use exec to replace shell with happy process
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i", "-l", "-c", "cd '\(folder.path)' && exec happy --permission-mode bypassPermissions"]
        process.currentDirectoryURL = URL(fileURLWithPath: folder.path)

        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["HOME"] = NSHomeDirectory()
        env["COLUMNS"] = "160"
        env["LINES"] = "50"
        let nvmNodePath = "\(NSHomeDirectory())/.nvm/versions/node/v24.3.0/bin"
        if let existingPath = env["PATH"] {
            env["PATH"] = "\(nvmNodePath):\(existingPath)"
        } else {
            env["PATH"] = "\(nvmNodePath):/usr/local/bin:/usr/bin:/bin"
        }
        process.environment = env

        // Connect to PTY slave
        let slaveHandle = FileHandle(fileDescriptor: slaveFd, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleTermination(instanceId: instanceId, exitCode: proc.terminationStatus)
            }
        }

        do {
            try process.run()
            close(slaveFd)

            masterFds[instanceId] = masterFd
            outputBuffers[instanceId] = ""

            // Read PTY output and store in buffer
            let readSource = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: DispatchQueue.global(qos: .background))
            readSource.setEventHandler { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = read(masterFd, &buffer, buffer.count)
                if bytesRead > 0 {
                    let text = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        var existing = self.outputBuffers[instanceId] ?? ""
                        existing += text
                        // Rolling buffer - keep last maxBufferSize chars
                        if existing.count > self.maxBufferSize {
                            existing = String(existing.suffix(self.maxBufferSize))
                        }
                        self.outputBuffers[instanceId] = existing
                    }
                }
            }
            readSource.setCancelHandler { [weak self] in
                close(masterFd)
                // Don't remove output buffer on cancel - keep history visible
            }
            readSource.resume()
            ptyReaders[instanceId] = readSource

            processes[instanceId] = process
            status.isRunning = true
            status.pid = process.processIdentifier
            status.lastError = nil
            print("Started Happy instance \(status.instanceIndex) for \(folder.folderName) (PID: \(process.processIdentifier))")
        } catch {
            close(masterFd)
            close(slaveFd)
            status.isRunning = false
            status.lastError = error.localizedDescription
            print("Failed to start Happy: \(error)")
        }
    }

    func stopInstance(instanceId: UUID) {
        // Cancel PTY reader
        if let reader = ptyReaders[instanceId] {
            reader.cancel()
            ptyReaders.removeValue(forKey: instanceId)
        }
        masterFds.removeValue(forKey: instanceId)

        // Terminate process and children
        if let process = processes[instanceId], process.isRunning {
            let pid = process.processIdentifier

            // Clean up logs for this process and its children
            deleteLogsForChildPids(parentPid: pid)
            deleteLogsForPid(pid)

            killChildProcesses(parentPid: pid)
            kill(pid, SIGTERM)
            process.terminate()

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    self.killChildProcesses(parentPid: pid)
                    kill(pid, SIGKILL)
                }
            }
        }
        processes.removeValue(forKey: instanceId)
    }

    private func killChildProcesses(parentPid: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(parentPid)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let childPids = output.split(separator: "\n").compactMap { Int32($0) }
                for childPid in childPids {
                    killChildProcesses(parentPid: childPid)
                    kill(childPid, SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        kill(childPid, SIGKILL)
                    }
                }
            }
        } catch {
            print("Failed to find child processes: \(error)")
        }
    }

    private func handleTermination(instanceId: UUID, exitCode: Int32) {
        guard var status = statuses[instanceId] else { return }

        status.isRunning = false
        status.pid = nil

        if let reader = ptyReaders[instanceId] {
            reader.cancel()
            ptyReaders.removeValue(forKey: instanceId)
        }
        masterFds.removeValue(forKey: instanceId)

        if exitCode != 0 {
            status.lastError = "Exited with code \(exitCode)"

            if status.restartCount < maxRestartAttempts {
                status.restartCount += 1
                statuses[instanceId] = status

                if let folder = configStore.folders.first(where: { $0.id == status.folderId }), folder.isEnabled {
                    print("Restarting instance (attempt \(status.restartCount)/\(maxRestartAttempts))...")

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard var currentStatus = self?.statuses[instanceId] else { return }
                        self?.startInstance(instanceId: instanceId, folder: folder, status: &currentStatus)
                        self?.statuses[instanceId] = currentStatus
                    }
                }
            } else {
                status.lastError = "Failed after \(maxRestartAttempts) restart attempts"
                statuses[instanceId] = status
            }
        } else {
            statuses[instanceId] = status
        }
    }

    private func checkProcesses() {
        for (instanceId, process) in processes {
            if !process.isRunning {
                if var status = statuses[instanceId] {
                    status.isRunning = false
                    statuses[instanceId] = status
                }
            }
        }
    }

    func restartInstance(instanceId: UUID) {
        guard var status = statuses[instanceId],
              let folder = configStore.folders.first(where: { $0.id == status.folderId }) else {
            return
        }

        stopInstance(instanceId: instanceId)
        status.restartCount = 0
        status.lastError = nil
        status.sessionName = nil
        startInstance(instanceId: instanceId, folder: folder, status: &status)
        statuses[instanceId] = status
    }

    func stopAll() {
        for instanceId in processes.keys {
            stopInstance(instanceId: instanceId)
        }
        statuses.removeAll()
    }

    func startAll() {
        syncInstances()
    }

    var runningCount: Int {
        statuses.values.filter { $0.isRunning }.count
    }

    var totalCount: Int {
        statuses.count
    }

    // Write input to PTY for an instance
    func writeToInstance(instanceId: UUID, data: Data) {
        guard let masterFd = masterFds[instanceId] else { return }
        data.withUnsafeBytes { buffer in
            if let ptr = buffer.baseAddress {
                _ = write(masterFd, ptr, buffer.count)
            }
        }
    }

    // Get the master file descriptor for an instance (for direct access if needed)
    func getMasterFd(instanceId: UUID) -> Int32? {
        return masterFds[instanceId]
    }
}
