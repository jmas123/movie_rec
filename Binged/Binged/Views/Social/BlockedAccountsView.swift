//
//  BlockedAccountsView.swift
//  Binged
//
//  Who you have blocked, and how to stop.
//
//  **Why this is a release concern and not a nicety.** The app could block from
//  three places and unblock from none — `SocialService.unblock` existed with no
//  caller, and there was no way to even see who was blocked. Blocking somebody
//  by mistake was permanent. App Store guideline 1.2 asks for a way to block
//  abusive users; a block with no exit is a trap rather than a control.
//
//  The list comes from the `blocked_accounts()` function rather than a query,
//  because blocking is mutual invisibility and `profiles_select` hides a
//  blocked profile from the blocker too. See the migration for why that is the
//  right shape.
//

import SwiftUI

// MARK: - BlockedAccountsView

struct BlockedAccountsView: View {

    let service: SocialService?

    @State private var people: [UserProfile] = []
    @State private var phase: Phase = .loading
    @State private var inFlight: Set<UUID> = []
    @State private var lastError: String?

    private enum Phase: Equatable {
        case loading, blocked, empty
        case error(String)
    }

    var body: some View {
        List {
            switch phase {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
                    .accessibilityLabel("Loading blocked accounts")
            case .empty:
                EmptyStateView(
                    systemImage: "hand.raised",
                    message: "You haven't blocked anyone.",
                    style: .inline
                )
            case .error(let message):
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    message: message,
                    style: .inline,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
            case .blocked:
                Section {
                    ForEach(people) { person in
                        HStack {
                            // No route: their profile is unreadable while the
                            // block stands, which is the block working.
                            UserRow(profile: person)
                            Spacer(minLength: Spacing.sm)
                            Button("Unblock") { Task { await unblock(person) } }
                                .buttonStyle(.bordered)
                                .font(.caption.weight(.semibold))
                                .disabled(inFlight.contains(person.id))
                                .accessibilityLabel("Unblock \(person.name)")
                        }
                    }
                } footer: {
                    Text("Unblocking lets them see your published ranking and "
                         + "follow you again. It does not restore any follow "
                         + "that the block removed.")
                }
            }
        }
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .alert("Something went wrong", isPresented: errorPrompt) {
            Button("OK") { lastError = nil }
        } message: {
            Text(lastError ?? "")
        }
        .task { await load() }
    }

    // MARK: Behaviour

    private func load() async {
        guard let service else {
            phase = .empty
            return
        }
        do {
            let found = try await service.blockedAccounts()
            people = found
            phase = found.isEmpty ? .empty : .blocked
        } catch {
            phase = .error(ErrorMessage.text(for: error))
        }
    }

    private func unblock(_ person: UserProfile) async {
        guard let service, !inFlight.contains(person.id) else { return }
        inFlight.insert(person.id)
        defer { inFlight.remove(person.id) }

        do {
            try await service.unblock(person.id)
            people.removeAll { $0.id == person.id }
            if people.isEmpty { phase = .empty }
        } catch {
            // Not optimistic: leaving a row that is still blocked is honest,
            // and removing one that is not would say the block was lifted when
            // it was not.
            lastError = ErrorMessage.text(for: error)
        }
    }

    private var errorPrompt: Binding<Bool> {
        Binding(get: { lastError != nil }, set: { if !$0 { lastError = nil } })
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    NavigationStack {
        BlockedAccountsView(service: MockSocialService())
    }
}
#endif
