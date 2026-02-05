//
//  Logger.swift
//  MyRemoteHost
//
//  世界最高水準ログシステム
//  - スロットリング: 同一メッセージ抑制
//  - サンプリング: 高頻度イベント間引き
//  - 接続フロー追跡: 重要イベントのみ
//

import Foundation

// MARK: - Log Level

public enum LogLevel: Int, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

// MARK: - Log Category

public enum LogCategory: String, Sendable {
    case cloudkit = "CloudKit"
    case stun = "STUN"
    case p2p = "P2P"
    case network = "Network"
    case crypto = "Crypto"
    case video = "Video"
    case connection = "Connection"  // 接続フロー専用
    
    var emoji: String {
        switch self {
        case .cloudkit: return "☁️"
        case .stun: return "🌐"
        case .p2p: return "🔗"
        case .network: return "📡"
        case .crypto: return "🔐"
        case .video: return "🎬"
        case .connection: return "🚀"
        }
    }
}

// MARK: - Sampling Mode

public enum SamplingMode: Sendable {
    case always          // 常に出力
    case throttle(TimeInterval)  // 指定秒数に1回
    case perSecond       // 1秒に1回
    case oncePerSession  // セッション中1回のみ
}

// MARK: - Logger

public final class Logger: @unchecked Sendable {
    
    // MARK: - Singleton
    
    public static let shared = Logger()
    
    // MARK: - Configuration
    
    /// 最小ログレベル（これ未満は出力しない）
    public var minimumLevel: LogLevel = .info
    
    /// デバッグビルドかどうか
    #if DEBUG
    private let isDebugBuild = true
    #else
    private let isDebugBuild = false
    #endif
    
    // MARK: - Throttling State
    
    private var lastLogTimes: [String: Date] = [:]
    private var messageCounts: [String: Int] = [:]
    private let lock = NSLock()
    
    /// デフォルトのスロットリング間隔（秒）
    private let defaultThrottleInterval: TimeInterval = 5.0
    
    // MARK: - Session Tracking
    
    private var sessionLogs: Set<String> = []
    private var connectionStartTime: Date?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Core Log Method
    
    public func log(
        _ message: String,
        level: LogLevel = .info,
        category: LogCategory,
        sampling: SamplingMode = .throttle(5.0),
        file: String = #file,
        line: Int = #line
    ) {
        // レベルフィルタ
        guard level.rawValue >= minimumLevel.rawValue else { return }
        
        // リリースビルドではwarning以上のみ
        if !isDebugBuild && level.rawValue < LogLevel.warning.rawValue {
            return
        }
        
        // サンプリング処理
        let key = "\(category.rawValue):\(message)"
        
        switch sampling {
        case .always:
            break  // 常に出力
            
        case .throttle(let interval):
            if !shouldLog(key: key, interval: interval) {
                return
            }
            
        case .perSecond:
            if !shouldLog(key: key, interval: 1.0) {
                return
            }
            
        case .oncePerSession:
            lock.lock()
            if sessionLogs.contains(key) {
                lock.unlock()
                return
            }
            sessionLogs.insert(key)
            lock.unlock()
        }
        
        // 出力
        let timestamp = formatTime(Date())
        let output = "[\(timestamp)] \(category.emoji) [\(category.rawValue)] \(message)"
        print(output)
    }
    
    // MARK: - Throttling Logic
    
    private func shouldLog(key: String, interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        
        if let lastTime = lastLogTimes[key] {
            if now.timeIntervalSince(lastTime) < interval {
                // カウントのみ増やす
                messageCounts[key, default: 0] += 1
                return false
            }
        }
        
        // 抑制されたメッセージ数を追記
        if let count = messageCounts[key], count > 0 {
            let suppressedOutput = "  ↳ (同一メッセージ \(count)件 抑制)"
            print(suppressedOutput)
            messageCounts[key] = 0
        }
        
        lastLogTimes[key] = now
        return true
    }
    
    // MARK: - Time Formatting
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
    
    // MARK: - Connection Flow Tracking
    
    /// 接続開始を記録
    public func connectionStart() {
        lock.lock()
        connectionStartTime = Date()
        connectionContext = ConnectionContext()  // コンテキストリセット
        lock.unlock()
        log("接続開始", level: .info, category: .connection, sampling: .always)
    }
    
    /// 接続成功を記録
    public func connectionSuccess(endpoint: String) {
        lock.lock()
        let duration = connectionStartTime.map { Date().timeIntervalSince($0) } ?? 0
        connectionContext = ConnectionContext()
        connectionStartTime = nil
        lock.unlock()
        
        log("✅ 接続成功: \(endpoint) (\(String(format: "%.1f", duration))秒)", 
            level: .info, category: .connection, sampling: .always)
    }
    
    // MARK: - Connection Context (エラー時詳細出力用)
    
    /// 接続コンテキスト
    private var connectionContext = ConnectionContext()
    
    /// 接続コンテキストを更新
    public func setContext(publicIP: String? = nil, publicPort: Int? = nil,
                          localIP: String? = nil, localPort: Int? = nil,
                          punchAttempts: Int? = nil, punchResponses: Int? = nil) {
        lock.lock()
        if let ip = publicIP { connectionContext.publicIP = ip }
        if let port = publicPort { connectionContext.publicPort = port }
        if let ip = localIP { connectionContext.localIP = ip }
        if let port = localPort { connectionContext.localPort = port }
        if let attempts = punchAttempts { connectionContext.punchAttempts = attempts }
        if let responses = punchResponses { connectionContext.punchResponses = responses }
        lock.unlock()
    }
    
    /// パンチ試行をカウント
    public func incrementPunchAttempt() {
        lock.lock()
        connectionContext.punchAttempts += 1
        lock.unlock()
    }
    
    /// パンチ応答をカウント
    public func incrementPunchResponse() {
        lock.lock()
        connectionContext.punchResponses += 1
        lock.unlock()
    }
    
    /// 接続失敗を記録（詳細コンテキスト付き）
    public func connectionFailed(reason: String) {
        lock.lock()
        let ctx = connectionContext
        let duration = connectionStartTime.map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()
        
        // メインエラーメッセージ
        log("❌ 接続失敗: \(reason) (\(String(format: "%.1f", duration))秒)", 
            level: .error, category: .connection, sampling: .always)
        
        // コンテキスト詳細
        var details: [String] = []
        
        if !ctx.publicIP.isEmpty || !ctx.localIP.isEmpty {
            var ips: [String] = []
            if !ctx.publicIP.isEmpty {
                ips.append("\(ctx.publicIP):\(ctx.publicPort) (公開)")
            }
            if !ctx.localIP.isEmpty {
                ips.append("\(ctx.localIP):\(ctx.localPort) (ローカル)")
            }
            details.append("├─ 試行IP: \(ips.joined(separator: ", "))")
        }
        
        if ctx.punchAttempts > 0 {
            details.append("├─ ホールパンチ: \(ctx.punchAttempts)回送信, \(ctx.punchResponses)回応答")
        }
        
        details.append("└─ 経過時間: \(String(format: "%.1f", duration))秒")
        
        for detail in details {
            print("  \(detail)")
        }
        
        // コンテキストをリセット
        lock.lock()
        connectionContext = ConnectionContext()
        connectionStartTime = nil
        lock.unlock()
    }
    
    // MARK: - Session Management
    
    /// セッションをリセット（新規接続時に呼ぶ）
    public func resetSession() {
        lock.lock()
        sessionLogs.removeAll()
        lastLogTimes.removeAll()
        messageCounts.removeAll()
        connectionContext = ConnectionContext()
        lock.unlock()
    }
}

// MARK: - Connection Context

/// 接続コンテキスト（エラー時の詳細出力用）
private struct ConnectionContext {
    var publicIP: String = ""
    var publicPort: Int = 0
    var localIP: String = ""
    var localPort: Int = 0
    var punchAttempts: Int = 0
    var punchResponses: Int = 0
}

// MARK: - Category Shortcuts

public extension Logger {
    
    static func cloudkit(_ message: String, level: LogLevel = .info, sampling: SamplingMode = .throttle(5.0)) {
        shared.log(message, level: level, category: .cloudkit, sampling: sampling)
    }
    
    static func stun(_ message: String, level: LogLevel = .info, sampling: SamplingMode = .throttle(5.0)) {
        shared.log(message, level: level, category: .stun, sampling: sampling)
    }
    
    static func p2p(_ message: String, level: LogLevel = .info, sampling: SamplingMode = .throttle(5.0)) {
        shared.log(message, level: level, category: .p2p, sampling: sampling)
    }
    
    static func network(_ message: String, level: LogLevel = .info, sampling: SamplingMode = .perSecond) {
        shared.log(message, level: level, category: .network, sampling: sampling)
    }
    
    static func crypto(_ message: String, level: LogLevel = .info, sampling: SamplingMode = .oncePerSession) {
        shared.log(message, level: level, category: .crypto, sampling: sampling)
    }
    
    static func video(_ message: String, level: LogLevel = .info, sampling: SamplingMode = .perSecond) {
        shared.log(message, level: level, category: .video, sampling: sampling)
    }
}
