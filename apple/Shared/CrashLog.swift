import Foundation

/// A small crash log next to the app's data (Library/Logs/Droprr/crash.log): uncaught exceptions with their
/// stack, and fatal signals with a raw backtrace. The system's own crash reports still exist; this is just
/// easier to find and to attach.
enum CrashLog {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static var url: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Droprr/crash.log")
    }

    /// Deletes Droprr's own temporary files (uploads, exports, forwarded copies) older than a day.
    static func cleanTemporaryFiles() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where url.lastPathComponent.hasPrefix("droprr-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    static func install() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        NSSetUncaughtExceptionHandler { exception in
            CrashLog.write("\n=== \(Date()) uncaught exception: \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n")
        }
        frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig) { number in
                // Async-signal-safe only: no allocation, just write(2) into buffers made at install time.
                var line: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
                    = (10, 61, 61, 61, 32, 102, 97, 116, 97, 108, 32, 115, 105, 103, 110, 97, 108, 32,   // "\n=== fatal signal "
                       UInt8(48 + number / 10 % 10), UInt8(48 + number % 10), 10)
                withUnsafeBytes(of: &line) { _ = Darwin.write(CrashLog.fd, $0.baseAddress, $0.count) }
                if let frames = CrashLog.frames {
                    let count = backtrace(frames, 64)
                    backtrace_symbols_fd(frames, count, CrashLog.fd)
                }
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    nonisolated(unsafe) private static var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

    private static func write(_ text: String) {
        guard fd >= 0 else { return }
        text.withCString { _ = Darwin.write(fd, $0, strlen($0)) }
    }
}
