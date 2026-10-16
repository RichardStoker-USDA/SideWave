// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

/// Holds a task so a closure created before the task can still reach it, for example to cancel it.
final class TaskBox<Success: Sendable, Failure: Error>: @unchecked Sendable {
    var task: Task<Success, Failure>?
}
