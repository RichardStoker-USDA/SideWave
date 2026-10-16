// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

enum RefineValidation {
    private static let singular: Set<String> = ["i", "me", "my", "mine", "myself"]
    private static let plural: Set<String> = ["we", "us", "our", "ours", "ourselves"]

    private static func perspective(_ text: String) -> (singular: Bool, plural: Bool) {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return (!words.isDisjoint(with: singular), !words.isDisjoint(with: plural))
    }

    static func speakerPreservationInstruction(for text: String) -> String? {
        let person = perspective(text)
        if person.plural && !person.singular {
            return "The speaker uses first-person plural pronouns. Preserve we, us, and our wherever they occur in the dictated text."
        }
        if person.singular && !person.plural {
            return "The speaker uses first-person singular pronouns. Preserve I, me, and my wherever they occur in the dictated text."
        }
        return nil
    }

    /// Catch an unrequested switch between one speaker and a group.
    /// Mixed-person input and translation need a broader semantic check.
    static func changesSpeakerNumber(input: String, output: String) -> Bool {
        let before = perspective(input)
        let after = perspective(output)
        return (before.plural && !before.singular && after.singular && !after.plural)
            || (before.singular && !before.plural && after.plural && !after.singular)
    }
}
