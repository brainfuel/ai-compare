import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
import PhotosUI
#endif

protocol SidebarConversationSummarizing: Identifiable where ID == UUID {
    var title: String { get }
    var updatedAt: Date { get }
}

extension SavedConversation: SidebarConversationSummarizing {}
extension CompareConversation: SidebarConversationSummarizing {}

// MARK: - Sidebar

struct ConversationSidebarView: View {
    @ObservedObject var viewModel: PlaygroundViewModel
    @ObservedObject var compareViewModel: CompareViewModel
    @Binding var workspaceMode: WorkspaceMode
    @State private var historySearch = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if workspaceMode == .single {
                            viewModel.startNewChat()
                        } else {
                            compareViewModel.startNewThread()
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(workspaceMode == .single ? "New Chat" : "New Compare")
                .buttonStyle(.borderedProminent)

                Spacer()

                Button(role: .destructive) {
                    if workspaceMode == .single {
                        viewModel.deleteSelectedConversation()
                    } else {
                        compareViewModel.deleteSelectedConversation()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(workspaceMode == .single ? "Delete Chat" : "Delete Compare")
                .buttonStyle(.bordered)
                .disabled(
                    workspaceMode == .single
                        ? viewModel.selectedConversationID == nil
                        : compareViewModel.selectedConversationID == nil
                )
            }

            TextField(workspaceMode == .single ? "Search History" : "Search Compares", text: $historySearch)
                .textFieldStyle(.roundedBorder)

            if workspaceMode == .single && viewModel.selectedConversationID == nil {
                newChatButton(title: "New Chat", icon: "plus.bubble", action: { viewModel.startNewChat() })
            } else if workspaceMode == .compare && compareViewModel.selectedConversationID == nil {
                newChatButton(title: "New Compare", icon: "rectangle.3.group.bubble.left", action: { compareViewModel.startNewThread() })
            }

            List {
                if workspaceMode == .single {
                    conversationList(
                        conversations: viewModel.filteredConversations(query: historySearch),
                        selectedConversationID: viewModel.selectedConversationID,
                        selectAction: { viewModel.selectConversation($0) }
                    )
                } else {
                    conversationList(
                        conversations: compareViewModel.filteredConversations(query: historySearch),
                        selectedConversationID: compareViewModel.selectedConversationID,
                        selectAction: { compareViewModel.selectConversation($0) }
                    )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(AppTheme.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .animation(
                .easeInOut(duration: 0.2),
                value: workspaceMode == .single
                    ? viewModel.savedConversations.map(\.id)
                    : compareViewModel.savedConversations.map(\.id)
            )
        }
        .padding(8)
        .background(AppTheme.surfaceGrouped)
        .frame(minWidth: 280)
        .onChange(of: workspaceMode) { _, _ in
            historySearch = ""
        }
    }

    @ViewBuilder
    private func newChatButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            HStack {
                Image(systemName: icon)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.brandTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    @ViewBuilder
    private func conversationList<Conversation: SidebarConversationSummarizing>(
        conversations: [Conversation],
        selectedConversationID: UUID?,
        selectAction: @escaping (UUID) -> Void
    ) -> some View {
        ForEach(conversations) { conversation in
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectAction(conversation.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .lineLimit(1)
                    Text(conversation.updatedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .listRowBackground(selectedConversationID == conversation.id ? AppTheme.brandTint.opacity(0.14) : Color.clear)
        }
    }
}

// MARK: - Workspace detail

struct WorkspaceDetailView: View {
    @ObservedObject var viewModel: PlaygroundViewModel
    @ObservedObject var compareViewModel: CompareViewModel
    @Binding var workspaceMode: WorkspaceMode
    let continueProviderInSingle: (AIProvider) -> Void
    @State private var showingUsageStats = false
    @State private var showingSynthesis = false

    var body: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $workspaceMode) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if workspaceMode == .single {
                SingleWorkspaceView(viewModel: viewModel)
            } else {
                CompareWorkspaceView(
                    compareViewModel: compareViewModel,
                    continueProviderInSingle: continueProviderInSingle
                )
            }
        }
        .padding([.horizontal, .top])
        .background(AppTheme.canvasBackground)
#if os(macOS)
        .frame(minWidth: 760)
#endif
        .navigationTitle("AI Compare")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            if workspaceMode == .single {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingUsageStats = true
                    } label: {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                    }
                    .help("Usage Stats")
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSynthesis = true
                    } label: {
                        Label("Synthesise", systemImage: "wand.and.stars")
                    }
                    .help("Synthesise all responses")
                    .disabled(compareViewModel.runs.isEmpty || compareViewModel.isSending)
                }
            }
        }
        .sheet(isPresented: $showingSynthesis) {
            CompareSynthesisView(compareViewModel: compareViewModel)
        }
        .sheet(isPresented: $showingUsageStats) {
            UsageStatsSheet(
                modelID: viewModel.modelID,
                sessionInputTokens: viewModel.sessionInputTokens,
                sessionOutputTokens: viewModel.sessionOutputTokens,
                windows: viewModel.usageTimeWindows
            )
        }
    }
}

// MARK: - Single chat workspace

struct SingleWorkspaceView: View {
    @ObservedObject var viewModel: PlaygroundViewModel
    @AppStorage("singleConnectionExpanded") private var isConnectionExpanded = true

    var body: some View {
        VStack(spacing: 12) {
            SingleConfigurationSection(viewModel: viewModel, isExpanded: $isConnectionExpanded)
            Divider()
            SingleMessagesSection(viewModel: viewModel, onScroll: collapseConnection)
            SingleComposerSection(viewModel: viewModel)
        }
    }

    private func collapseConnection() {
        guard isConnectionExpanded else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isConnectionExpanded = false
        }
    }
}

private struct ConnectionContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SingleConfigurationSection: View {
    @ObservedObject var viewModel: PlaygroundViewModel
    @Binding var isExpanded: Bool
    @State private var isKeyHidden = true
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 18)
                        Text("Connection").font(.headline)
                        if !isExpanded {
                            Text("\(viewModel.selectedProvider.displayName) · \(viewModel.modelID.isEmpty ? "no model" : viewModel.modelID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .transition(.opacity)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    connectionContent
                }
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: ConnectionContentHeightKey.self, value: g.size.height)
                    }
                )
                .frame(height: isExpanded ? measuredHeight : 0, alignment: .top)
                .opacity(isExpanded ? 1 : 0)
                .clipped()
                .allowsHitTesting(isExpanded)
                .onPreferenceChange(ConnectionContentHeightKey.self) { newValue in
                    if newValue > 0 { measuredHeight = newValue }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
        }
        .groupBoxStyle(ThemeGroupBoxStyle())
    }

    @ViewBuilder
    private var connectionContent: some View {
        Group {
            Picker("Provider", selection: $viewModel.selectedProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.selectedProvider) { _, newValue in
                    // Skip when the change came from importConversation —
                    // otherwise selectProvider would clobber the imported modelID.
                    guard !viewModel.isImportingConversation else { return }
                    Task {
                        await viewModel.selectProvider(newValue)
                    }
                }

                HStack {
                    if isKeyHidden {
                        SecureField(viewModel.providerAPIKeyPlaceholder, text: apiKeyBinding)
                    } else {
                        TextField(viewModel.providerAPIKeyPlaceholder, text: apiKeyBinding)
                    }
                    Button(isKeyHidden ? "Show" : "Hide") {
                        isKeyHidden.toggle()
                    }
                }

                HStack {
                    Button("Load Models") {
                        Task {
                            await viewModel.refreshModels()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isLoading || viewModel.currentAPIKey.isEmpty || !viewModel.canLoadModels)

                    if viewModel.availableModels.isEmpty {
                        Text(viewModel.currentAPIKey.isEmpty ? "Enter API key to load models" : "Load models to choose one")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !viewModel.availableModels.isEmpty {
                    Picker("Available Models", selection: modelSelectionBinding) {
                        ForEach(viewModel.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                }

                TextField("System Instructions (optional)", text: $viewModel.systemInstruction, axis: .vertical)
                    .lineLimit(2...5)
        }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { viewModel.currentAPIKey },
            set: { viewModel.updateCurrentAPIKey($0) }
        )
    }

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: { viewModel.modelID },
            set: { viewModel.selectModel($0) }
        )
    }
}

struct SingleMessagesSection: View {
    @ObservedObject var viewModel: PlaygroundViewModel
    var onScroll: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConversationView(
                messages: viewModel.messages,
                streamingText: viewModel.isLoading ? viewModel.streamingText : nil,
                onScroll: onScroll
            )

            if viewModel.isLoading && viewModel.streamingText.isEmpty {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                    Text("Thinking...")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
        }
    }
}

struct SingleComposerSection: View {
    @ObservedObject var viewModel: PlaygroundViewModel
    @State private var prompt = ""
    @State private var isDropTargeted = false
    @State private var showingFileImporter = false
    @FocusState private var inputFocused: Bool
#if os(iOS)
    @State private var photoItem: PhotosPickerItem?
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.pendingAttachments.isEmpty {
                AttachmentStripView(
                    attachments: viewModel.pendingAttachments,
                    removeAction: { viewModel.removeAttachment(id: $0) }
                )
            }

            composerEditor

            HStack {
                statusView
                Spacer()
                Button("Attach") { showingFileImporter = true }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isLoading)
#if os(iOS)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "camera")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoading)
                .onChange(of: photoItem) { _, item in
                    Task { await loadPhoto(item, add: { viewModel.addAttachments(fromResult: $0) }) }
                }
#endif
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        viewModel.isLoading ||
                        !viewModel.canSendRequests ||
                        (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingAttachments.isEmpty)
                    )
            }
        }
        .padding(8)
        .background(AppTheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.cardBorder, lineWidth: 1)
        )
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            viewModel.addAttachments(fromResult: result)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let errorMessage = viewModel.errorMessage {
            Button { copyToClipboard(errorMessage) } label: {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Click to copy error")
        } else {
            Text("Ready").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var composerEditor: some View {
        Group {
#if os(macOS)
            AttachmentDropTextEditor(text: $prompt, isDropTargeted: $isDropTargeted) { urls in
                viewModel.addAttachments(fromResult: .success(urls))
            }
#else
            TextEditor(text: $prompt).focused($inputFocused).padding(8)
#endif
        }
        .frame(minHeight: 90, maxHeight: 150)
        .overlay(alignment: .topLeading) {
            if prompt.isEmpty {
                Text("Ask a question…")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? AppTheme.brandTint : AppTheme.cardBorder,
                        lineWidth: isDropTargeted ? 2 : 1)
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !viewModel.pendingAttachments.isEmpty else { return }
        prompt = ""
        inputFocused = false
        Task { await viewModel.send(text: text) }
    }
}

// MARK: - Column header button style

private struct ColumnHeaderIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .imageScale(.medium)
            .foregroundStyle(isEnabled ? AppTheme.brandTint : Color.secondary)
            .opacity(configuration.isPressed ? 0.65 : 1.0)
    }
}

private struct ColumnCheckboxToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .imageScale(.medium)
                .foregroundStyle(configuration.isOn ? AppTheme.brandTint : Color.secondary)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1.0 : 0.4)
    }
}

// MARK: - Compare workspace

struct CompareWorkspaceView: View {
    @ObservedObject var compareViewModel: CompareViewModel
    let continueProviderInSingle: (AIProvider) -> Void
    @State private var expandedProvider: AIProvider? = nil
    @State private var isAnimating = false

    private let animationDuration: TimeInterval = 0.18

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(AIProvider.allCases) { provider in
                    if expandedProvider == nil || expandedProvider == provider {
                        CompareProviderColumnView(
                            state: CompareProviderColumnState(
                                provider: provider,
                                displayName: provider.displayName,
                                hasAPIKey: compareViewModel.hasAPIKey(for: provider),
                                selectedModel: compareViewModel.selectedModel(for: provider),
                                availableModels: compareViewModel.modelsForPicker(for: provider),
                                providerStatusMessage: compareViewModel.providerStatusMessage(provider),
                                isEnabled: compareViewModel.isProviderEnabled(provider),
                                canContinueInSingle: compareViewModel.canContinueInSingle(for: provider),
                                isSending: compareViewModel.isSending
                            ),
                            runs: compareViewModel.runsChronological,
                            provider: provider,
                            continueProviderInSingle: continueProviderInSingle,
                            isExpanded: expandedProvider == provider,
                            isAnimating: isAnimating,
                            latestRunID: compareViewModel.latestRunID,
                            onSelectModel: { compareViewModel.selectModel($0, for: provider) },
                            onToggleProviderEnabled: { compareViewModel.setProviderEnabled(provider, $0) },
                            onRefreshModels: { Task { await compareViewModel.refreshModels(for: provider) } },
                            onRetryRun: { runID in compareViewModel.retryProvider(runID: runID, provider: provider) },
                            onToggleExpand: {
                                isAnimating = true
                                withAnimation(.easeOut(duration: animationDuration)) {
                                    expandedProvider = expandedProvider == provider ? nil : provider
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.05) {
                                    isAnimating = false
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            CompareComposerSection(compareViewModel: compareViewModel)
        }
    }
}

struct CompareProviderColumnView: View {
    let state: CompareProviderColumnState
    let runs: [CompareRun]
    let provider: AIProvider
    let continueProviderInSingle: (AIProvider) -> Void
    var isExpanded: Bool = false
    var isAnimating: Bool = false
    let latestRunID: UUID?
    let onSelectModel: (String) -> Void
    let onToggleProviderEnabled: (Bool) -> Void
    let onRefreshModels: () -> Void
    let onRetryRun: (UUID) -> Void
    var onToggleExpand: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(ColumnHeaderIconButtonStyle())
                .help(isExpanded ? "Collapse" : "Expand to full width")

                Text(provider.displayName)
#if os(iOS)
                    .font(.subheadline.weight(.semibold))
#else
                    .font(.headline)
#endif
                    .lineLimit(1)
                    .foregroundStyle(state.isEnabled ? .primary : .secondary)
                Spacer()
                Button {
                    continueProviderInSingle(provider)
                } label: {
                    Image(systemName: "arrow.right.square")
                }
                .buttonStyle(ColumnHeaderIconButtonStyle())
                .help("Open \(provider.displayName) compare history in Single mode")
                .disabled(!state.canContinueInSingle || state.isSending)

                PDFExportButton(filename: "\(provider.displayName)-responses.pdf") {
                    PDFBuilder.compareResponse(
                        provider: provider,
                        runs: runs
                    )
                }
                .buttonStyle(ColumnHeaderIconButtonStyle())
                .disabled(runs.allSatisfy {
                    $0.results[provider]?.state != .success
                })

                if state.hasAPIKey {
                    Toggle(isOn: Binding(
                        get: { state.isEnabled },
                        set: { onToggleProviderEnabled($0) }
                    )) { EmptyView() }
                    .toggleStyle(ColumnCheckboxToggleStyle())
                    .help(state.isEnabled ? "Included in Send All" : "Excluded from Send All")
                    .disabled(state.isSending)

                    Text("Connected")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.85), in: Capsule())
                        .help("API key is configured")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Missing API key")
                }
            }

            HStack(spacing: 4) {
                if state.availableModels.isEmpty {
                    Text("No models cached").font(.caption).foregroundStyle(.secondary)
                } else {
#if os(iOS)
                    // Menu gives us full label control so the selected model
                    // stays on one line and truncates cleanly.
                    Menu {
                        ForEach(state.availableModels, id: \.self) { model in
                            Button(model) { onSelectModel(model) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(state.selectedModel)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(AppTheme.brandTint)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
#else
                    Picker("Model", selection: compareModelBinding) {
                        ForEach(state.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
#endif
                }
#if os(iOS)
                Spacer()
                Button(action: onRefreshModels) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(state.isSending || !state.hasAPIKey)
#else
                Button("Load", action: onRefreshModels)
                .buttonStyle(.bordered)
                .disabled(state.isSending || !state.hasAPIKey)
#endif
            }

            if let message = state.providerStatusMessage, !message.isEmpty {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if isAnimating {
                        // Hide markdown content during resize animation so Textual
                        // doesn't recalculate layout on every frame.
                        Color.clear
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            // Hide runs that were never dispatched to this
                            // provider (e.g. user targeted a single model, or
                            // this provider is missing its key/model).
                            let displayedRuns = runs.filter {
                                $0.results[provider]?.state != .skipped
                            }
                            if displayedRuns.isEmpty {
                                Text(compareEmptyStateMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(displayedRuns) { run in
                                    CompareRunCardView(
                                        run: run,
                                        provider: provider,
                                        isAnimating: isAnimating,
                                        onRetry: state.isSending ? nil : { onRetryRun(run.id) }
                                    ).id(run.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .conditionalTextSelection(!isAnimating)
                .onChange(of: latestRunID) { _, newValue in
                    guard let newValue else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let lastID = runs.last?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(AppTheme.surfaceSecondary)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var compareEmptyStateMessage: String {
        if state.hasAPIKey {
            return "No compare runs yet."
        }
        return "Add an API key in Single mode to start comparing."
    }

    private var compareModelBinding: Binding<String> {
        Binding(
            get: { state.selectedModel },
            set: { onSelectModel($0) }
        )
    }
}

struct CompareProviderColumnState: Equatable {
    let provider: AIProvider
    let displayName: String
    let hasAPIKey: Bool
    let selectedModel: String
    let availableModels: [String]
    let providerStatusMessage: String?
    let isEnabled: Bool
    let canContinueInSingle: Bool
    let isSending: Bool
}

struct CompareRunCardView: View {
    let run: CompareRun
    let provider: AIProvider
    var isAnimating: Bool = false
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.createdAt, format: .dateTime.hour().minute().second())
                .font(.caption2).foregroundStyle(.secondary)

            if !isAnimating {
                InlineConversationView(
                    messages: synthesizedMessages,
                    streamingText: streamingTextIfLoading
                )
            }

            if let result = run.results[provider] {
                switch result.state {
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                        Text("Thinking...").foregroundStyle(.secondary)
                    }
                case .success:
                    EmptyView()
                case .failed:
                    if let error = result.errorMessage {
                        Button { copyToClipboard(error) } label: {
                            Text(error)
                                .font(.caption).foregroundStyle(.red)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain).help("Click to copy error")
                    }
                    if let onRetry {
                        Button {
                            onRetry()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Re-run this provider with the current model")
                    }
                case .skipped:
                    Text(result.errorMessage ?? "Skipped").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(AppTheme.surfaceGrouped)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var result: CompareProviderResult? { run.results[provider] }

    /// Build a synthetic [user, assistant] message pair so the inline
    /// conversation web view can render the prompt + response in one
    /// surface (matches single-mode rendering and selection).
    private var synthesizedMessages: [ChatMessage] {
        var msgs: [ChatMessage] = []
        msgs.append(ChatMessage(
            role: .user,
            text: run.prompt,
            attachments: run.attachments
        ))
        if let r = result {
            // For .loading we feed live text via streamingText; only include a
            // finalized assistant message for non-loading states with content.
            if r.state != .loading {
                let text = r.text
                msgs.append(ChatMessage(
                    role: .assistant,
                    text: text,
                    attachments: [],
                    generatedMedia: r.generatedMedia,
                    inputTokens: r.inputTokens,
                    outputTokens: r.outputTokens,
                    modelID: r.modelID
                ))
            }
        }
        return msgs
    }

    private var streamingTextIfLoading: String? {
        guard let r = result, r.state == .loading else { return nil }
        return r.text.isEmpty ? nil : r.text
    }
}

struct CompareComposerSection: View {
    @ObservedObject var compareViewModel: CompareViewModel
    @State private var prompt = ""
    @State private var isDropTargeted = false
    @State private var showingFileImporter = false
    @State private var sendTarget: AIProvider? = nil
    @FocusState private var inputFocused: Bool
#if os(iOS)
    @State private var photoItem: PhotosPickerItem?
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compareViewModel.pendingAttachments.isEmpty {
                AttachmentStripView(
                    attachments: compareViewModel.pendingAttachments,
                    removeAction: { compareViewModel.removeAttachment(id: $0) }
                )
            }

            Group {
#if os(macOS)
                AttachmentDropTextEditor(text: $prompt, isDropTargeted: $isDropTargeted) { urls in
                    compareViewModel.addAttachments(fromResult: .success(urls))
                }
#else
                TextEditor(text: $prompt).focused($inputFocused).padding(8)
#endif
            }
            .frame(minHeight: 90, maxHeight: 150)
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Ask a question…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDropTargeted ? AppTheme.brandTint : AppTheme.cardBorder,
                            lineWidth: isDropTargeted ? 2 : 1)
            }

            HStack {
                if let errorMessage = compareViewModel.errorMessage {
                    Button { copyToClipboard(errorMessage) } label: {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain).help("Click to copy error")
                } else {
                    Text(compareViewModel.composerStatusLabel).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()

                sendTargetMenu

                Button("Attach") { showingFileImporter = true }
                    .buttonStyle(.bordered)
                    .disabled(compareViewModel.isSending)
#if os(iOS)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "camera")
                }
                .buttonStyle(.bordered)
                .disabled(compareViewModel.isSending)
                .onChange(of: photoItem) { _, item in
                    Task { await loadPhoto(item, add: { compareViewModel.addAttachments(fromResult: $0) }) }
                }
#endif
                if compareViewModel.isSending {
                    Button("Stop") { compareViewModel.cancelSend() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help("Cancel all in-flight requests")
                } else {
                    Button(sendButtonLabel) { send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                            compareViewModel.pendingAttachments.isEmpty
                        )
                }
            }
        }
        .padding(8)
        .background(AppTheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.cardBorder, lineWidth: 1))
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            compareViewModel.addAttachments(fromResult: result)
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !compareViewModel.pendingAttachments.isEmpty else { return }
        prompt = ""
        inputFocused = false
        // If the chosen target is no longer ready (e.g. key removed), fall
        // back to All so the send still goes somewhere.
        let target: AIProvider? = {
            guard let t = sendTarget else { return nil }
            return compareViewModel.readyProviders.contains(t) ? t : nil
        }()
        compareViewModel.startSendCompare(text: text, targetProvider: target)
    }

    private var sendButtonLabel: String {
        if let t = sendTarget, compareViewModel.readyProviders.contains(t) {
            return "Send to \(t.displayName)"
        }
        return "Send All"
    }

    @ViewBuilder
    private var sendTargetMenu: some View {
        let ready = compareViewModel.readyProviders
        Menu {
            Button {
                sendTarget = nil
            } label: {
                if sendTarget == nil {
                    Label("All", systemImage: "checkmark")
                } else {
                    Text("All")
                }
            }
            if !ready.isEmpty { Divider() }
            ForEach(ready, id: \.self) { provider in
                Button {
                    sendTarget = provider
                } label: {
                    if sendTarget == provider {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paperplane")
                    .font(.caption)
                Text(sendTarget?.displayName ?? "All")
                    .font(.body)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which model to send to")
        .disabled(compareViewModel.isSending)
        .onChange(of: ready) { _, newReady in
            // If the chosen target is no longer ready, reset to All.
            if let t = sendTarget, !newReady.contains(t) {
                sendTarget = nil
            }
        }
    }
}

// MARK: - Photo picker helper (iOS)

#if os(iOS)
@MainActor
private func loadPhoto(
    _ item: PhotosPickerItem?,
    add: @escaping (Result<[URL], Error>) -> Void
) async {
    guard let item else { return }
    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jpg")
    guard (try? data.write(to: url)) != nil else { return }
    add(.success([url]))
}
#endif

// MARK: - Shared subviews

/// Horizontal scrolling strip of pending attachment previews.
struct AttachmentStripView: View {
    let attachments: [PendingAttachment]
    let removeAction: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            AttachmentPreview(attachment: attachment)
                                .frame(width: 120, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button { removeAction(attachment.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.65))
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(attachment.name).lineLimit(1).font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(AppTheme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.label).font(.caption).foregroundStyle(.secondary)

            if !message.text.isEmpty {
                Group {
                    MarkdownText(message.text)
                }
                .padding(10)
                .background(message.role == .user ? AppTheme.nodeHuman.opacity(0.2) : AppTheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !message.attachments.isEmpty {
                ForEach(message.attachments) { MessageAttachmentView(attachment: $0) }
            }

            if !message.generatedMedia.isEmpty {
                ForEach(message.generatedMedia) { media in
                    AssistantMediaView(media: media).frame(maxWidth: 420).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            if message.role == .assistant, message.inputTokens > 0 || message.outputTokens > 0 {
                TokenUsageRow(modelID: message.modelID ?? "", inputTokens: message.inputTokens, outputTokens: message.outputTokens)
            }
        }
    }
}

private struct StreamingBubbleView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MessageRole.assistant.label).font(.caption).foregroundStyle(.secondary)
            MarkdownText(text)
                .padding(10)
                .background(AppTheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct TokenUsageRow: View {
    let modelID: String
    let inputTokens: Int
    let outputTokens: Int

    var body: some View {
        HStack(spacing: 10) {
            Label("\(inputTokens.formatted()) in", systemImage: "arrow.up")
            Label("\(outputTokens.formatted()) out", systemImage: "arrow.down")
            if let cost = TokenCostCalculator.cost(for: modelID, inputTokens: inputTokens, outputTokens: outputTokens) {
                Text(costString(cost))
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func costString(_ cost: Double) -> String {
        if cost < 0.0001 { return String(format: "~$%.6f", cost) }
        if cost < 0.01   { return String(format: "~$%.4f", cost) }
        return String(format: "~$%.3f", cost)
    }
}

private struct SessionTokenSummary: View {
    let modelID: String
    let inputTokens: Int
    let outputTokens: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").imageScale(.small)
            Text("Session: \(inputTokens.formatted()) in · \(outputTokens.formatted()) out")
            if let cost = TokenCostCalculator.cost(for: modelID, inputTokens: inputTokens, outputTokens: outputTokens) {
                Text(costString(cost))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func costString(_ cost: Double) -> String {
        if cost < 0.0001 { return String(format: "·~$%.6f", cost) }
        if cost < 0.01   { return String(format: "·~$%.4f", cost) }
        return String(format: "·~$%.3f", cost)
    }
}

private struct UsageTimeWindowSummaryView: View {
    let windows: [UsageTimeWindowSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Usage (estimate)").font(.caption2).foregroundStyle(.tertiary)
            ForEach(windows) { window in
                Text("\(window.label): \(window.inputTokens.formatted()) in · \(window.outputTokens.formatted()) out · \(costString(window.estimatedCost))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func costString(_ cost: Double) -> String {
        if cost < 0.0001 { return String(format: "~$%.6f", cost) }
        if cost < 0.01   { return String(format: "~$%.4f", cost) }
        return String(format: "~$%.3f", cost)
    }
}

struct UsageStatsSheet: View {
    let modelID: String
    let sessionInputTokens: Int
    let sessionOutputTokens: Int
    let windows: [UsageTimeWindowSummary]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Usage Stats", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }

            GroupBox("Current Chat") {
                if sessionInputTokens > 0 || sessionOutputTokens > 0 {
                    SessionTokenSummary(modelID: modelID, inputTokens: sessionInputTokens, outputTokens: sessionOutputTokens)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No token usage yet in this chat.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Rolling Totals") {
                UsageTimeWindowSummaryView(windows: windows)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 250)
    }
}

// MARK: - Compare Synthesis Sheet

struct CompareSynthesisView: View {
    @ObservedObject var compareViewModel: CompareViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider: AIProvider = AIProvider.allCases.first!

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Synthesise Responses")
                        .font(.title2.weight(.semibold))
                    Text("Collapses all model responses into consensus, disagreements, unique points, and suspicious claims.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .success(let result) = compareViewModel.synthesisState {
                    PDFExportButton(filename: "synthesis.pdf") {
                        PDFBuilder.synthesisResult(result)
                    }
                    .buttonStyle(.plain)
                    .font(.title2)
                    .foregroundStyle(AppTheme.brandTint)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Provider picker + run button
            HStack(spacing: 12) {
                Text("Synthesise using")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140)

                // Timestamp of last run
                if let ts = compareViewModel.synthesisTimestamp {
                    Text("Last run \(ts, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
                Button {
                    Task { await compareViewModel.synthesize(using: selectedProvider) }
                } label: {
                    if case .synthesizing = compareViewModel.synthesisState {
                        ProgressView().controlSize(.small)
                    } else {
                        let hasResult: Bool = {
                            if case .success = compareViewModel.synthesisState { return true }
                            return false
                        }()
                        Label(hasResult ? "Re-run" : "Run", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled({
                    if case .synthesizing = compareViewModel.synthesisState { return true }
                    return !compareViewModel.hasAPIKey(for: selectedProvider)
                }())
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(AppTheme.surfaceSecondary)

            // Stale banner — shown when new runs have been added since synthesis ran
            if compareViewModel.isSynthesisStale {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.exclamationmark.fill")
                        .foregroundStyle(.orange)
                    Text("New responses have been added since this was run. Tap Re-run to update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }

            Divider()

            // Result area
            ScrollView {
                switch compareViewModel.synthesisState {
                case .idle:
                    VStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("Pick a model and tap Run to synthesise all responses in this thread.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(48)

                case .synthesizing:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Synthesising…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(48)

                case .failed(let message):
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(48)

                case .success(let result):
                    VStack(alignment: .leading, spacing: 20) {
                        if result.isEmpty {
                            Text("The model returned no structured output. Try again or use a different provider.")
                                .foregroundStyle(.secondary)
                                .padding()
                        } else {
                            if !result.consensus.isEmpty {
                                SynthesisSectionView(
                                    title: "Consensus",
                                    subtitle: "All or most models agree",
                                    icon: "checkmark.seal.fill",
                                    iconColor: .green
                                ) {
                                    ForEach(result.consensus) { item in
                                        SynthesisRowView(text: item.text)
                                    }
                                }
                            }
                            if !result.disagreements.isEmpty {
                                SynthesisSectionView(
                                    title: "Disagreements",
                                    subtitle: "Direct contradictions between models",
                                    icon: "arrow.triangle.2.circlepath",
                                    iconColor: .orange
                                ) {
                                    ForEach(result.disagreements) { d in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(d.topic)
                                                .font(.subheadline.weight(.medium))
                                            ForEach(d.positions, id: \.model) { pos in
                                                HStack(alignment: .top, spacing: 8) {
                                                    Text(pos.model)
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(AppTheme.brandTint)
                                                        .frame(width: 90, alignment: .leading)
                                                    Text(pos.position)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                            }
                                        }
                                        .padding(10)
                                        .background(AppTheme.surfaceSecondary)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            if !result.unique.isEmpty {
                                SynthesisSectionView(
                                    title: "Unique Points",
                                    subtitle: "Only one model mentioned this",
                                    icon: "sparkle",
                                    iconColor: AppTheme.brandTint
                                ) {
                                    ForEach(result.unique) { u in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(u.source)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(AppTheme.brandTint)
                                                .frame(width: 90, alignment: .leading)
                                            Text(u.claim)
                                                .font(.subheadline)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(10)
                                        .background(AppTheme.surfaceSecondary)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            if !result.suspicious.isEmpty {
                                SynthesisSectionView(
                                    title: "Suspicious Claims",
                                    subtitle: "Potentially questionable or unverifiable",
                                    icon: "questionmark.diamond.fill",
                                    iconColor: .red
                                ) {
                                    ForEach(result.suspicious) { item in
                                        SynthesisRowView(text: item.text)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .textSelection(.enabled)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(AppTheme.canvasBackground)
        .onAppear {
            if let first = AIProvider.allCases.first(where: { compareViewModel.hasAPIKey(for: $0) }) {
                selectedProvider = first
            }
        }
    }
}

private struct SynthesisSectionView<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) { content }
        }
        .padding(14)
        .background(AppTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.cardBorder, lineWidth: 1))
    }
}

private struct SynthesisRowView: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)
                .padding(.top, 7)
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func copyToClipboard(_ value: String) {
#if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
#elseif canImport(UIKit)
    UIPasteboard.general.string = value
#endif
}
