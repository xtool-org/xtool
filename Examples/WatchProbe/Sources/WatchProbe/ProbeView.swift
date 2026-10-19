import Foundation
import SwiftUI
import WatchKit

struct ProbeView: View {
    @AppStorage("probe.tapCount") private var tapCount = 0
    @State private var startedAt: Date?
    @State private var accumulated: TimeInterval = 0
    @State private var connectionMessage = "Ready to check"
    @State private var checkingConnection = false
    @State private var connectionSucceeded: Bool?

    var body: some View {
        TabView {
            counterPage
            timerPage
            connectionPage
        }
        .tabViewStyle(.verticalPage)
    }

    private var counterPage: some View {
        VStack(spacing: 8) {
            Label("Watch Probe", systemImage: "applewatch")
                .font(.headline)
                .foregroundStyle(.cyan)

            Text("\(tapCount)")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel("\(tapCount) taps")

            Button {
                withAnimation { tapCount += 1 }
                WKInterfaceDevice.current().play(.click)
            } label: {
                Label("Tap +1", systemImage: "plus")
            }
            .tint(.cyan)

            Button("Reset") { tapCount = 0 }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)

            Text("Swipe up for more tests")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }

    private var timerPage: some View {
        VStack(spacing: 10) {
            Label("Timer", systemImage: "stopwatch")
                .font(.headline)
                .foregroundStyle(.orange)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(ProbeTimer.formatted(elapsed(at: context.date)))
                    .font(.system(size: 38, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }

            Button(startedAt == nil ? "Start" : "Pause") {
                if let start = startedAt {
                    accumulated += max(0, Date().timeIntervalSince(start))
                    startedAt = nil
                } else {
                    startedAt = .now
                }
                WKInterfaceDevice.current().play(.click)
            }
            .tint(.orange)

            Button("Reset") {
                startedAt = nil
                accumulated = 0
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Session timer")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }

    private var connectionPage: some View {
        VStack(spacing: 10) {
            Label("Connection", systemImage: "network")
                .font(.headline)
                .foregroundStyle(.green)

            if checkingConnection {
                ProgressView()
            } else {
                Image(systemName: connectionIcon)
                    .font(.system(size: 30))
                    .foregroundStyle(connectionSucceeded == true ? .green : .secondary)
            }

            Text(connectionMessage)
                .font(.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Check internet") {
                Task { await checkConnection() }
            }
            .tint(.green)
            .disabled(checkingConnection)

            Text("Uses apple.com\nBuild 0.1.2 · xtool")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 6)
    }

    private var connectionIcon: String {
        switch connectionSucceeded {
        case true: "checkmark.circle.fill"
        case false: "exclamationmark.circle"
        case nil: "globe"
        }
    }

    private func elapsed(at date: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    @MainActor
    private func checkConnection() async {
        guard !checkingConnection else { return }
        checkingConnection = true
        connectionSucceeded = nil
        connectionMessage = "Connecting…\nKeep this screen open"
        defer { checkingConnection = false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<400).contains(response.statusCode) else {
                connectionSucceeded = false
                connectionMessage = "Server unavailable. Try again."
                return
            }
            connectionSucceeded = true
            connectionMessage = "Connected · HTTP \(response.statusCode)"
            WKInterfaceDevice.current().play(.success)
        } catch {
            connectionSucceeded = false
            let failure = error as NSError
            connectionMessage = "\(failure.localizedDescription)\nCode: \(failure.code)"
        }
    }
}

enum ProbeTimer {
    static func formatted(_ elapsed: TimeInterval) -> String {
        let seconds = Int(max(0, elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
