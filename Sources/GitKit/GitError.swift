import Foundation

public enum GitError: Error, Sendable, Equatable {
    case launchFailed(String)
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)
    case timedOut(command: String)
}
