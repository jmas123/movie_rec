//
//  ErrorMessage.swift
//  Binged
//
//  What to show a person when something failed.
//
//  **Why this exists.** The social view models reached for
//  `String(describing: error)`, which renders a Swift case dump — a reader
//  offline saw the literal text `transport("Could not reach the server.")`,
//  with the readable sentence visible but wrapped in syntax. Both error types
//  already carry a written-for-humans `description`; this picks it.
//
//  Deliberately not a protocol check. `CustomStringConvertible` is conformed to
//  by almost everything, including types whose `description` is a debug dump,
//  so matching on it would reintroduce the same problem less obviously.
//

import Foundation

// MARK: - ErrorMessage

enum ErrorMessage {

    /// A sentence to put in front of a user.
    ///
    /// Falls back to `String(describing:)` for anything unrecognised, which is
    /// ugly but never empty — a blank alert is worse than a technical one.
    static func text(for error: Error) -> String {
        if let social = error as? SocialError { return social.description }
        if let supabase = error as? SupabaseError { return supabase.description }
        if let auth = error as? AuthError { return auth.description }
        return String(describing: error)
    }
}
