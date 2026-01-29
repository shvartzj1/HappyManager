import Foundation

struct FolderConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String
    var instanceCount: Int
    var isEnabled: Bool

    init(path: String, instanceCount: Int = 1, isEnabled: Bool = true) {
        self.id = UUID()
        self.path = path
        self.instanceCount = instanceCount
        self.isEnabled = isEnabled
    }

    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

struct InstanceStatus: Identifiable {
    let id: UUID
    let folderId: UUID
    let instanceIndex: Int
    var isRunning: Bool
    var restartCount: Int
    var lastError: String?
    var pid: Int32?
    var sessionName: String?

    init(id: UUID, folderId: UUID, instanceIndex: Int) {
        self.id = id
        self.folderId = folderId
        self.instanceIndex = instanceIndex
        self.isRunning = false
        self.restartCount = 0
        self.lastError = nil
        self.pid = nil
        self.sessionName = nil
    }
}

class ConfigStore: ObservableObject {
    @Published var folders: [FolderConfig] = []
    @Published var launchAtLogin: Bool = false

    private let configURL: URL

    static let shared = ConfigStore()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("HappyManager")
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        configURL = appFolder.appendingPathComponent("config.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode([FolderConfig].self, from: data) else {
            return
        }
        folders = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: configURL)
    }

    func addFolder(_ path: String) {
        guard !folders.contains(where: { $0.path == path }) else { return }
        folders.append(FolderConfig(path: path))
        save()
    }

    func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        save()
    }

    func updateFolder(_ folder: FolderConfig) {
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
            save()
        }
    }
}
