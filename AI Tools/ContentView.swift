import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case single
    case compare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: return "Single"
        case .compare: return "Compare"
        }
    }
}

struct ThemeGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.headline)
            configuration.content
        }
        .padding(10)
        .background(AppTheme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.cardBorder, lineWidth: 1)
        )
    }
}

struct ContentView: View {
    @StateObject private var viewModel: PlaygroundViewModel
    @StateObject private var compareViewModel: CompareViewModel
    @State private var workspaceMode: WorkspaceMode = .single

    init(viewModel: PlaygroundViewModel, compareViewModel: CompareViewModel) {
        _viewModel        = StateObject(wrappedValue: viewModel)
        _compareViewModel = StateObject(wrappedValue: compareViewModel)
    }

    var body: some View {
        NavigationSplitView {
            ConversationSidebarView(
                viewModel: viewModel,
                compareViewModel: compareViewModel,
                workspaceMode: $workspaceMode
            )
        } detail: {
            WorkspaceDetailView(
                viewModel: viewModel,
                compareViewModel: compareViewModel,
                workspaceMode: $workspaceMode,
                continueProviderInSingle: continueProviderInSingle
            )
        }
        .background(AppTheme.canvasBackground)
        .tint(AppTheme.brandTint)
#if os(macOS)
        .frame(minWidth: 1180, minHeight: 760)
        .navigationSplitViewColumnWidth(min: 280, ideal: 320)
#elseif os(iOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
#endif
        .task {
            await viewModel.loadOnLaunchIfNeeded()
            await compareViewModel.loadOnLaunchIfNeeded()
        }
        .onChange(of: workspaceMode) { _, mode in
            guard mode == .compare else { return }
            compareViewModel.reloadFromStorage(includeSecureStorage: true)
        }
    }

    private func continueProviderInSingle(_ provider: AIProvider) {
        guard let importedConversation = compareViewModel.makeSingleConversation(for: provider) else {
            compareViewModel.errorMessage = "No \(provider.displayName) compare history to move yet."
            return
        }
        viewModel.importConversation(importedConversation)
        workspaceMode = .single
        // historySearch is cleared by ConversationSidebarView's onChange(of: workspaceMode)
    }
}
