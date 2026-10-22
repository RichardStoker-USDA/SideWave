// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Storage for supported Refine models, including legacy choices.
struct ModelStorageSection: View {
    @Bindable var appState: AppState

    @State private var entries: [ModelCacheInventory.Entry] = []
    @State private var pendingDelete: ModelCacheInventory.Entry?
    @State private var deleteError: String?
    @State private var completeness: [String: Bool] = [:]
    @State private var isChecking = false
    @State private var hasChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Cached Models")
                    .font(.callout.weight(.medium))
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.mini).accessibilityLabel("Checking cached models")
                }
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .adaptiveSecondary()
                }
                .buttonStyle(.plain)
                .help("Refresh cached models list")
                .accessibilityLabel("Refresh cached models list")
                .disabled(isChecking)
            }

            if !hasChecked {
                Text("Checking downloaded model files…")
                    .settingsCaption()
            } else if entries.isEmpty {
                Text("No Gemma models are cached. Choosing a Gemma model downloads it here. Apple Intelligence uses models managed by macOS.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        VStack(alignment: .leading, spacing: Spacing.xxxs) {
                            Text(entry.displayName)
                                .font(.callout)
                            Text(entry.bytes.byteCountText)
                                .font(.caption.monospacedDigit())
                                .adaptiveSecondary()
                            Text(entry.repoID)
                                .font(.caption2)
                                .adaptiveTertiary()
                            Text(completeness[entry.repoID].map { $0 ? "Files verified" : "Incomplete cache. Prepare to resume or repair." } ?? "Checking files…")
                                .font(.caption).adaptiveSecondary()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer()
                        if completeness[entry.repoID] == false, let backend = backend(for: entry) {
                            Button("Prepare") {
                                guard !cacheMutationBlocked else { return }
                                appState.dictationCleanupBackend = backend.rawValue
                                appState.dictationFormatter.unloadModel()
                                appState.dictationCleanupEnabled = true
                                appState.dictationFormatter.enable()
                            }
                            .buttonStyle(.bordered).disabled(cacheMutationBlocked)
                            .help("Select this model and download only missing or damaged files")
                        }
                        Button(role: .destructive) {
                            pendingDelete = entry
                        } label: {
                            Text("Delete")
                        }
                        .actionButton()
                        .disabled(cacheMutationBlocked)
                        .accessibilityLabel("Delete \(entry.displayName)")
                    }
                    if entry != entries.last {
                        Divider()
                    }
                }

                Text("Total: \(entries.reduce(Int64(0)) { $0 + $1.bytes }.byteCountText)")
                    .font(.caption2.monospacedDigit())
                    .adaptiveTertiary()
                Text(cacheMutationBlocked
                     ? "Wait for dictation and Refine to finish before deleting a model."
                     : "These cached files may also be used by other applications.")
                    .settingsCaption()
            }
        }
        .padding(Spacing.md)
        .settingsCardStyle()
        .onAppear { refresh() }
        .onChange(of: appState.dictationFormatter.state) { _, state in
            if state == .ready { refresh() }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.displayName ?? "model")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: Visibility.visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                delete(entry)
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { entry in
            Text("This removes \(entry.bytes.byteCountText) from the shared model cache. Other applications may use these files too. The model downloads again the next time it is needed.")
        }
        .alert(
            "Couldn't delete model",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func delete(_ entry: ModelCacheInventory.Entry) {
        defer {
            pendingDelete = nil
            refresh()
        }
        guard !cacheMutationBlocked else {
            deleteError = "Wait for dictation and Refine to finish, then try again."
            return
        }
        do {
            try ModelCacheInventory.delete(entry)
        } catch {
            deleteError = error.localizedDescription
            return
        }
        // Only unload the service whose model we actually deleted. Deleting an
        // unrelated folder (e.g. a legacy Llama tier) must not tear down the
        // other service's loaded model and cancel an in-flight refine.
        if repoMatches(entry.repoID, appState.dictationFormatter.activeBackend.huggingFaceRepoID) {
            appState.dictationFormatter.unloadModel()
        }
        if repoMatches(entry.repoID, appState.formatterService.selectedBackend.registryConfig?.name) {
            appState.formatterService.unloadModel()
        }
    }

    /// True when a service's backend resolves to the repo we just deleted.
    /// Runs both sides through the custom-owner rewrite so a user-pointed
    /// mirror still matches the on-disk folder name the inventory reports.
    private func repoMatches(_ deletedRepoID: String, _ backendRepoID: String?) -> Bool {
        guard let backendRepoID, !backendRepoID.isEmpty else { return false }
        return ModelDownloadManager.resolveRepoID(backendRepoID).caseInsensitiveCompare(deletedRepoID) == .orderedSame
    }

    private var cacheMutationBlocked: Bool {
        if appState.isDictationBusy || appState.isProcessingAgenticEdit || appState.formatterService.state.isBusy {
            return true
        }
        switch appState.dictationFormatter.state {
        case .downloading, .loading, .generating: return true
        default: return false
        }
    }

    private func refresh() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let result = await Task.detached(priority: .utility) {
                let entries = ModelCacheInventory.listRefineModels()
                var completeness: [String: Bool] = [:]
                for entry in entries {
                    completeness[entry.repoID] = ModelSnapshotValidation.cachedSnapshot(repoID: entry.repoID)
                        .map { ModelSnapshotValidation.invalidFiles(at: $0).isEmpty } ?? false
                }
                return (entries, completeness)
            }.value
            entries = result.0
            completeness = result.1
            hasChecked = true
            isChecking = false
        }
    }

    private func backend(for entry: ModelCacheInventory.Entry) -> DictationFormatterService.Backend? {
        DictationFormatterService.Backend.allCases.first { repoMatches(entry.repoID, $0.huggingFaceRepoID) }
    }
}
