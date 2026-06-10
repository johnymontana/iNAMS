import SwiftUI
import iNAMSKit

/// The panel's content: Capture and Search tabs.
struct PaletteView: View {
    @ObservedObject var appState: AppState
    @State private var tab: Tab
    let dismiss: () -> Void

    enum Tab {
        case capture
        case search
    }

    init(appState: AppState, mode: PaletteMode, dismiss: @escaping () -> Void) {
        self.appState = appState
        self.dismiss = dismiss
        _tab = State(initialValue: mode == .capture ? .capture : .search)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Capture").tag(Tab.capture)
                    Text("Search").tag(Tab.search)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Spacer()

                if let workspace = appState.selectedWorkspace {
                    Text(workspace.name ?? workspace.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch tab {
            case .capture:
                CaptureTab(appState: appState, dismiss: dismiss)
            case .search:
                SearchTab(appState: appState)
            }
        }
        .padding(16)
        .frame(width: 600, height: 360)
        .onExitCommand { dismiss() }
    }
}

private struct CaptureTab: View {
    @ObservedObject var appState: AppState
    let dismiss: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Jot a memory… it lands in this workspace's Quick Capture conversation")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 16)
                            .padding(.leading, 13)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                if appState.pendingCount > 0 {
                    Label("\(appState.pendingCount) pending sync", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = appState.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private func save() {
        let note = text
        text = ""
        dismiss()
        Task { await appState.capture(note) }
    }
}

private struct SearchTab: View {
    @ObservedObject var appState: AppState
    @State private var query = ""
    @State private var results = AppState.SearchResults()
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search messages and entities…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onChange(of: query) { _, newValue in
                        debounceSearch(newValue)
                    }
                if !results.searchType.isEmpty {
                    Text(results.searchType)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
            }

            List {
                if !results.messages.isEmpty {
                    Section("Messages") {
                        ForEach(results.messages) { hit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.content ?? "")
                                    .lineLimit(2)
                                HStack {
                                    if let conv = hit.conversationId {
                                        Text("conversation \(String(conv.prefix(8)))…")
                                    }
                                    if let score = hit.score {
                                        Text(String(format: "%.2f", score))
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !results.entities.isEmpty {
                    Section("Entities") {
                        ForEach(results.entities) { hit in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(hit.name ?? hit.id).fontWeight(.medium)
                                    if let type = hit.type {
                                        Text(type)
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .background(Capsule().fill(.quaternary))
                                    }
                                }
                                if let description = hit.description, !description.isEmpty {
                                    Text(description).font(.caption).lineLimit(1)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if results.messages.isEmpty && results.entities.isEmpty && !query.isEmpty {
                    Text("No results").foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
        .onAppear { focused = true }
    }

    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            results = await appState.search(query)
        }
    }
}
