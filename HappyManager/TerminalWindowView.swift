import SwiftUI
import SwiftTerm
import Combine

// NSViewRepresentable wrapper for SwiftTerm's TerminalView
struct SwiftTermView: NSViewRepresentable {
    let instanceId: UUID
    @ObservedObject var processManager: ProcessManager

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.configureNativeColors()

        // Store reference for updates
        context.coordinator.terminalView = terminalView
        context.coordinator.lastLength = 0

        // Feed existing output
        if let existingData = processManager.outputBuffers[instanceId]?.data(using: .utf8) {
            terminalView.feed(byteArray: ArraySlice(existingData))
            context.coordinator.lastLength = existingData.count
        }

        return terminalView
    }

    func updateNSView(_ terminalView: TerminalView, context: Context) {
        // Feed new data incrementally
        guard let fullOutput = processManager.outputBuffers[instanceId],
              let fullData = fullOutput.data(using: .utf8) else { return }

        let currentLength = fullData.count
        let lastLength = context.coordinator.lastLength

        if currentLength > lastLength {
            // Only feed the new data
            let newData = fullData.suffix(from: lastLength)
            terminalView.feed(byteArray: ArraySlice(newData))
            context.coordinator.lastLength = currentLength
        } else if currentLength < lastLength {
            // Buffer was truncated (rolling buffer), re-feed everything
            let terminal = terminalView.getTerminal()
            terminal.resetToInitialState()
            terminalView.feed(byteArray: ArraySlice(fullData))
            context.coordinator.lastLength = currentLength
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var terminalView: TerminalView?
        var lastLength: Int = 0
    }
}

struct TerminalWindowView: View {
    let instanceId: UUID
    let title: String
    @ObservedObject var processManager = ProcessManager.shared

    var isRunning: Bool {
        processManager.statuses[instanceId]?.isRunning ?? false
    }

    var byteCount: Int {
        processManager.outputBuffers[instanceId]?.count ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal view
            SwiftTermView(instanceId: instanceId, processManager: processManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status bar
            HStack {
                Circle()
                    .fill(isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(isRunning ? "Running" : "Stopped")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(byteCount) bytes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 500)
    }
}
