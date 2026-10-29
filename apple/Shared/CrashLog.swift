import Foundation

/// A small crash log next to the app's data (Library/Logs/Droprr/crash.log): uncaught exceptions with their
/// stack, and fatal signals with a raw backtrace. The system's own crash reports still exist; this is just
/// easier to find and to attach.
enum CrashLog {
    private static var fd: Int32 = -1

    static var url: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Droprr/crash.log")
    }

    static func install() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        NSSetUncaughtExceptionHandler { exception in
            CrashLog.write("\n=== \(Date()) uncaught exception: \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n")
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig) { number in
                // Only async-signal-safe calls here.
                let header = "\n=== fatal signal \(number)\n"
                header.withCString { _ = Darwin.write(CrashLog.fd, $0, strlen($0)) }
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let count = backtrace(&frames, 64)
                backtrace_symbols_fd(&frames, count, CrashLog.fd)
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    private static func write(_ text: String) {
        guard fd >= 0 else { return }
        text.withCString { _ = Darwin.write(fd, $0, strlen($0)) }
    }
}
