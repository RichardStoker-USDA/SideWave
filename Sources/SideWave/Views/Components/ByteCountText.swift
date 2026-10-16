// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

extension Int64 {
    /// File size such as "593.5 MB". Zero reads "0 bytes" rather than "Zero KB".
    var byteCountText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Swift.max(0, self))
    }
}
