import Darwin

/// Unbuffered stdout output
enum Stdout {
    /// Configure stdout for unbuffered output (call once at startup)
    static func setUnbuffered() {
        setbuf(stdout, nil)
    }

    /// Print a line to stdout (with newline, flushed immediately)
    static func print(_ message: String) {
        fputs(message + "\n", stdout)
    }
}

/// Unbuffered stderr output
enum Stderr {
    /// Configure stderr for unbuffered output (call once at startup)
    static func setUnbuffered() {
        setbuf(stderr, nil)
    }

    /// Print a line to stderr (with newline)
    static func print(_ message: String) {
        fputs(message + "\n", stderr)
    }
}
