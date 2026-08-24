//
//  WatchlistView.swift
//  Binged
//
//  Everything queued, and something to do with it.
//
//  The watchlist was a five-item rail on Home and nothing else: no full list,
//  no count, no way off it. A sixth queued title was simply unreachable, and
//  the only action available on any of them was Mark Watched from the detail
//  screen.
//

import SwiftUI

// MARK: - WatchlistView

struct WatchlistView: View {

    @Environment(MediaLibraryViewModel.self) private var library

    var onBrowse: (() -> Void)?

    @State private var pendingRemoval: MediaItem?

    var body: some View {
        List {
            if library.allWantToWatch.isEmpty {
                EmptyStateView(
                    systemImage: "bookmark",
                    message: "Nothing on your watchlist yet.",
                    style: .inline,
                    actionTitle: onBrowse == nil ? nil : "Find something to watch",
                    action: onBrowse
                )
            } else {
                Section {
                    ForEach(library.allWantToWatch) { item in
                        NavigationLink {
                            MediaDetailView(item: item)
                        } label: {
                            MediaRow(item: item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingRemoval = item
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                } footer: {
                    Text(countPhrase)
                }
            }
        }
        .navigationTitle("Watchlist")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.title)?" } ?? "",
            isPresented: removalPrompt,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingRemoval { library.remove(item) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This takes it off your watchlist. Nothing is ranked or scored.")
        }
    }

    private var countPhrase: String {
        let count = library.allWantToWatch.count
        return count == 1 ? "1 title" : "\(count) titles"
    }

    private var removalPrompt: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    NavigationStack {
        WatchlistView()
            .environment(MediaLibraryViewModel.previewInMemory())
    }
}
#endif
