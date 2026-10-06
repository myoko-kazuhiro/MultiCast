import Foundation
import os.log
import Darwin

/// アプリ全体のログを管理・保存するシングルトン
class LogStore: ObservableObject {
    static let shared = LogStore()
    
    @Published var logEntries: [LogEntry] = []
    
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "com.multicast.logstore")
    
    private init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MultiCast")
        
        if !fileManager.fileExists(atPath: appDir.path) {
            try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        
        logFileURL = appDir.appendingPathComponent("app.log")
        loadLogs()
    }
    
    func write(level: String, category: String, message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        
        let logLine = "[\(timestamp)] [\(level)] [\(category)] \(message)"
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message, rawText: logLine)
        
        DispatchQueue.main.async {
            self.logEntries.append(entry)
            // UIパフォーマンスのため、最大1000件程度に制限
            if self.logEntries.count > 1000 {
                self.logEntries.removeFirst(self.logEntries.count - 1000)
            }
        }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            let writeString = logLine + "\n"
            guard let data = writeString.data(using: .utf8) else { return }
            
            if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: self.logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: self.logFileURL)
            }
        }
    }
    
    func loadLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard FileManager.default.fileExists(atPath: self.logFileURL.path),
                  let data = try? Data(contentsOf: self.logFileURL),
                  let content = String(data: data, encoding: .utf8) else {
                return
            }
            
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            
            // 最新1000行だけロード
            let recentLines = lines.suffix(1000)
            var entries: [LogEntry] = []
            
            for line in recentLines {
                // Parse simple logline format: [TIMESTAMP] [LEVEL] [CATEGORY] Message
                // e.g., [2026-10-06 23:14:36.123] [INFO] [App] Initializing audio system...
                entries.append(LogEntry(rawText: line))
            }
            
            DispatchQueue.main.async {
                self.logEntries = entries
            }
        }
    }
    
    func clearLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.logFileURL)
            DispatchQueue.main.async {
                self.logEntries.removeAll()
            }
        }
    }
    
    func registerCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let msg = "Uncaught Exception: \(exception.name.rawValue) - \(exception.reason ?? "")\n\(stack)"
            LogStore.shared.write(level: "FATAL", category: "Crash", message: msg)
            Thread.sleep(forTimeInterval: 0.5) // 書き込み完了を待機
        }
        
        // Signal handler setup
        let signalHandler: @convention(c) (Int32) -> Void = { sig in
            let stack = Thread.callStackSymbols.joined(separator: "\n")
            let sigName: String
            switch sig {
            case SIGABRT: sigName = "SIGABRT"
            case SIGILL: sigName = "SIGILL"
            case SIGSEGV: sigName = "SIGSEGV"
            case SIGFPE: sigName = "SIGFPE"
            case SIGBUS: sigName = "SIGBUS"
            case SIGPIPE: sigName = "SIGPIPE"
            default: sigName = "SIG \(sig)"
            }
            LogStore.shared.write(level: "FATAL", category: "Crash", message: "Signal \(sigName) caught\n\(stack)")
            Thread.sleep(forTimeInterval: 0.5)
            exit(sig)
        }
        
        signal(SIGABRT, signalHandler)
        signal(SIGILL, signalHandler)
        signal(SIGSEGV, signalHandler)
        signal(SIGFPE, signalHandler)
        signal(SIGBUS, signalHandler)
        signal(SIGPIPE, SIG_IGN) // ignore SIGPIPE typically
    }
    
    func getLogText() -> String {
        return logEntries.map { $0.rawText }.joined(separator: "\n")
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    var timestamp: Date = Date()
    var level: String = "INFO"
    var category: String = ""
    var message: String = ""
    var rawText: String = ""
    
    init(timestamp: Date, level: String, category: String, message: String, rawText: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.rawText = rawText
    }
    
    init(rawText: String) {
        self.rawText = rawText
        // 簡易パース処理
        let parts = rawText.components(separatedBy: "] ")
        if parts.count >= 3 {
            self.level = parts[1].replacingOccurrences(of: "[", with: "")
            self.category = parts[2].replacingOccurrences(of: "[", with: "")
            self.message = parts.dropFirst(3).joined(separator: "] ")
        }
    }
}

/// os.log とファイルログの両方に書き込むラッパー
struct AppLogger {
    let category: String
    private let osLogger: Logger
    
    init(category: String) {
        self.category = category
        self.osLogger = Logger(subsystem: "com.multicast", category: category)
    }
    
    func info(_ message: String) {
        osLogger.info("\(message)")
        LogStore.shared.write(level: "INFO", category: category, message: message)
    }
    
    func warning(_ message: String) {
        osLogger.warning("\(message)")
        LogStore.shared.write(level: "WARN", category: category, message: message)
    }
    
    func error(_ message: String) {
        osLogger.error("\(message)")
        LogStore.shared.write(level: "ERROR", category: category, message: message)
    }
    
    func debug(_ message: String) {
        osLogger.debug("\(message)")
        LogStore.shared.write(level: "DEBUG", category: category, message: message)
    }
}
