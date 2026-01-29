import SwiftUI
import Combine

class TerminalViewModel: ObservableObject {
    let instanceId: UUID
    @Published var strippedOutput: String = ""
    @Published var byteCount: Int = 0

    private var cancellable: AnyCancellable?
    private var lastRawLength: Int = 0
    private static let ansiRegex: NSRegularExpression? = {
        let pattern = "\u{001B}\\[[0-9;]*[a-zA-Z]|\u{001B}\\][^\u{007}]*\u{007}|\u{001B}[()][AB012]|\u{001B}=[0-9]*"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    init(instanceId: UUID) {
        self.instanceId = instanceId

        // Observe changes to output buffer with throttling
        cancellable = ProcessManager.shared.$outputBuffers
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] buffers in
                guard let self = self else { return }
                let raw = buffers[instanceId] ?? ""

                // Only reprocess if content actually changed
                if raw.count != self.lastRawLength {
                    self.lastRawLength = raw.count
                    self.byteCount = raw.count
                    self.strippedOutput = Self.stripAnsi(raw)
                }
            }

        // Initial load
        let raw = ProcessManager.shared.outputBuffers[instanceId] ?? ""
        self.lastRawLength = raw.count
        self.byteCount = raw.count
        self.strippedOutput = Self.stripAnsi(raw)
    }

    private static func stripAnsi(_ text: String) -> String {
        guard let regex = ansiRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}

struct TerminalWindowView: View {
    let instanceId: UUID
    let title: String
    @StateObject private var viewModel: TerminalViewModel
    @ObservedObject var processManager = ProcessManager.shared
    @State private var autoScroll = true

    init(instanceId: UUID, title: String) {
        self.instanceId = instanceId
        self.title = title
        self._viewModel = StateObject(wrappedValue: TerminalViewModel(instanceId: instanceId))
    }

    var isRunning: Bool {
        processManager.statuses[instanceId]?.isRunning ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(viewModel.strippedOutput.isEmpty ? "Waiting for output..." : viewModel.strippedOutput)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(viewModel.strippedOutput.isEmpty ? .gray : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                        .id("bottom")
                }
                .background(Color.black)
                .onChange(of: viewModel.strippedOutput) { _ in
                    if autoScroll {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            // Status bar
            HStack {
                Circle()
                    .fill(isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(isRunning ? "Running" : "Stopped")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Text("\(viewModel.byteCount) bytes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
