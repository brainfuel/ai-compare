import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

@main
struct AI_ToolsApp: App {
    private let modelContainer: ModelContainer
    private let viewModel: PlaygroundViewModel
    private let compareViewModel: CompareViewModel

    init() {
        let schema = Schema([
            ConversationRecord.self,
            MessageRecord.self,
            CompareConversationRecord.self,
            CompareRunRecord.self,
        ])
        do {
            modelContainer = try ModelContainer(for: schema)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        let context      = modelContainer.mainContext
        let mediaURL     = Self.mediaStoreDirectoryURL()
        let store        = mediaURL.flatMap { ConversationStore(context: context, mediaStoreDirectoryURL: $0) }
        let compareStore = CompareConversationStore(context: context, mediaStoreDirectoryURL: mediaURL)

        viewModel        = PlaygroundViewModel(conversationStoreFactory: { store })
        compareViewModel = CompareViewModel(conversationStore: compareStore)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel, compareViewModel: compareViewModel)
                .tint(AppTheme.brandTint)
                .background(AppTheme.canvasBackground)
        }
        .modelContainer(modelContainer)
#if os(macOS)
        .defaultSize(width: 1320, height: 860)
#endif
    }

    private static func mediaStoreDirectoryURL() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "AITools", isDirectory: true)
            .appendingPathComponent("GeneratedMedia", isDirectory: true)
    }
}
