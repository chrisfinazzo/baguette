import Testing
import Foundation
@testable import Baguette

@Suite("Logger")
struct LoggerTests {

    // The function only writes to stderr; we don't intercept the FILE*
    // here — calling it just exercises the body so a future change that
    // crashes (e.g. dereferencing a nil format) gets caught.
    @Test func `log prints without throwing`() {
        log("test message")
        log("")
    }

    // Same deal as `log` — the styling decision is covered in
    // TerminalStyleTests; this just exercises the write path.
    @Test func `warn prints without throwing`() {
        warn("test warning")
        warn("")
    }

    @Test func `colour is resolved per file descriptor`() {
        // Under `swift test` stderr is not a terminal, so this also
        // pins that redirected output stays uncoloured.
        _ = terminalColorized(STDERR_FILENO)
        _ = terminalColorized(STDOUT_FILENO)
    }
}
