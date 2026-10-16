// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

struct KeyboardHint: Equatable {
    let label: String
    let keys: String
}

struct TutorialStep: Identifiable, Equatable {
    let id: Int
    let title: String
    let body: String
    let icon: String
    var keyboardHints: [KeyboardHint]? = nil
}
