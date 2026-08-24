//
//  StoreRecoveryView.swift
//  Binged
//
//  What the app shows when it cannot open its own database.
//
//  **Why a screen and not a crash.** This replaced a `fatalError`, which on a
//  shipped build is an immediate termination the user experiences as "the app
//  does not launch any more" with no explanation and nothing to do.
//
//  **Why a screen and not an empty library.** The tempting alternative — fall
//  back to a fresh store and carry on — is worse than crashing. The user would
//  find their rankings gone, conclude the data was lost, and start ranking
//  again over the top of a store that still exists on disk and is still
//  recoverable. This screen is deliberately a dead end: it does not offer to
//  reset anything, because the data is far more likely to be intact than not.
//

import SwiftUI

// MARK: - StoreRecoveryView

struct StoreRecoveryView: View {

    let message: String

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text("Binged can't open your library")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Your rankings are still on this device. The app could not read "
                 + "them this time, which usually means it needs an update rather "
                 + "than a reinstall.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Named explicitly, because "reinstall the app" is the one action
            // that would actually destroy the data this screen is protecting.
            Text("Please don't delete the app — that would erase the library. "
                 + "Update to the latest version, or get in touch.")
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)

            if let supportEmail = SupportLinks.supportEmail {
                Link("Contact support", destination: supportEmail)
                    .font(.callout.weight(.semibold))
            }

            DisclosureGroup("Technical details") {
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.footnote)
            .padding(.top, Spacing.sm)
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    StoreRecoveryView(
        message: "SwiftDataError(_error: .loadIssueModelContainer)"
    )
}
#endif
