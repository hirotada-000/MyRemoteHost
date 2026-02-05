//
//  ConnectionManager.swift
//  MyRemoteHost iphone
//
//  接続管理マネージャー
//  Phase 0: 商用リリース向け基盤整備
//
//  責務:
//  - 接続状態の一元管理
//  - 自動再接続ロジック
//  - 接続品質モニタリング
//  - グレースフルな切断処理
//

import Foundation
import Combine

/// 接続管理マネージャー
/// クライアント側の接続ライフサイクルを管理
@MainActor
public final class ConnectionManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// 現在の接続状態
    @Published public private(set) var state: ConnectionState = .disconnected
    
    /// 接続先ホスト情報
    @Published public private(set) var currentHost: NetworkEndpoint?
    
    /// 最後の接続エラー
    @Published public private(set) var lastError: Error?
    
    /// 再接続試行回数
    @Published public private(set) var reconnectAttempts: Int = 0
    
    // MARK: - Types
    
    /// 接続状態
    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case waitingForAuth
        case connected
        case reconnecting(attempt: Int)
        case failed(reason: String)
        
        public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.waitingForAuth, .waitingForAuth),
                 (.connected, .connected):
                return true
            case let (.reconnecting(a), .reconnecting(b)):
                return a == b
            case let (.failed(a), .failed(b)):
                return a == b
            default:
                return false
            }
        }
    }
    
    /// 接続設定
    public struct Configuration {
        /// 最大再接続試行回数
        public let maxReconnectAttempts: Int
        
        /// 再接続間隔（秒）
        public let reconnectInterval: TimeInterval
        
        /// 再接続間隔の指数バックオフ係数
        public let backoffMultiplier: Double
        
        /// 最大再接続間隔（秒）
        public let maxReconnectInterval: TimeInterval
        
        /// 接続タイムアウト（秒）
        public let connectionTimeout: TimeInterval
        
        /// デフォルト設定
        public static let `default` = Configuration(
            maxReconnectAttempts: 5,
            reconnectInterval: 1.0,
            backoffMultiplier: 1.5,
            maxReconnectInterval: 30.0,
            connectionTimeout: 15.0
        )
        
        /// アグレッシブ再接続（モバイル向け）
        public static let aggressive = Configuration(
            maxReconnectAttempts: 10,
            reconnectInterval: 0.5,
            backoffMultiplier: 1.2,
            maxReconnectInterval: 10.0,
            connectionTimeout: 10.0
        )
        
        public init(
            maxReconnectAttempts: Int,
            reconnectInterval: TimeInterval,
            backoffMultiplier: Double,
            maxReconnectInterval: TimeInterval,
            connectionTimeout: TimeInterval
        ) {
            self.maxReconnectAttempts = maxReconnectAttempts
            self.reconnectInterval = reconnectInterval
            self.backoffMultiplier = backoffMultiplier
            self.maxReconnectInterval = maxReconnectInterval
            self.connectionTimeout = connectionTimeout
        }
    }
    
    // MARK: - Private Properties
    
    private let configuration: Configuration
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    
    /// 接続確立時コールバック
    public var onConnect: (() -> Void)?
    
    /// 切断時コールバック
    public var onDisconnect: ((Error?) -> Void)?
    
    /// 再接続開始時コールバック
    public var onReconnectStart: ((Int) -> Void)?
    
    /// 再接続成功時コールバック
    public var onReconnectSuccess: (() -> Void)?
    
    /// 再接続失敗時コールバック
    public var onReconnectFailed: (() -> Void)?
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }
    
    // MARK: - Public Methods
    
    /// 接続を開始
    public func connect(to endpoint: NetworkEndpoint) {
        guard case .disconnected = state else {
            print("[ConnectionManager] 接続中のため無視: \(state)")
            return
        }
        
        currentHost = endpoint
        reconnectAttempts = 0
        lastError = nil
        state = .connecting
        
        // タイムアウト監視開始
        startConnectionTimeout()
        
        print("[ConnectionManager] 接続開始: \(endpoint.description)")
    }
    
    /// 接続成功を通知
    public func notifyConnected() {
        cancelConnectionTimeout()
        reconnectAttempts = 0
        state = .connected
        onConnect?()
        print("[ConnectionManager] ✅ 接続成功")
    }
    
    /// 認証待機状態に遷移
    public func notifyWaitingForAuth() {
        cancelConnectionTimeout()
        state = .waitingForAuth
        print("[ConnectionManager] 認証待機中...")
    }
    
    /// 切断を通知（自動再接続を試行）
    public func notifyDisconnected(error: Error? = nil, shouldReconnect: Bool = true) {
        cancelConnectionTimeout()
        cancelReconnect()
        
        lastError = error
        
        if let error = error {
            print("[ConnectionManager] ⚠️ 切断: \(error.localizedDescription)")
        } else {
            print("[ConnectionManager] 切断")
        }
        
        // 再接続が有効で、接続先が設定されている場合
        if shouldReconnect, let host = currentHost {
            attemptReconnect(to: host)
        } else {
            state = .disconnected
            onDisconnect?(error)
        }
    }
    
    /// 明示的に切断（再接続なし）
    public func disconnect() {
        cancelConnectionTimeout()
        cancelReconnect()
        
        state = .disconnected
        lastError = nil
        
        onDisconnect?(nil)
        print("[ConnectionManager] 切断完了")
    }
    
    /// 再接続をキャンセル
    public func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }
    
    // MARK: - Private Methods
    
    private func attemptReconnect(to endpoint: NetworkEndpoint) {
        reconnectAttempts += 1
        
        // 最大試行回数チェック
        if reconnectAttempts > configuration.maxReconnectAttempts {
            state = .failed(reason: "最大再接続試行回数(\(configuration.maxReconnectAttempts)回)に達しました")
            onReconnectFailed?()
            print("[ConnectionManager] ❌ 再接続失敗: 最大試行回数超過")
            return
        }
        
        // 再接続間隔を計算（指数バックオフ）
        let delay = min(
            configuration.reconnectInterval * pow(configuration.backoffMultiplier, Double(reconnectAttempts - 1)),
            configuration.maxReconnectInterval
        )
        
        state = .reconnecting(attempt: reconnectAttempts)
        onReconnectStart?(reconnectAttempts)
        
        print("[ConnectionManager] 🔄 再接続試行 \(reconnectAttempts)/\(configuration.maxReconnectAttempts) (\(String(format: "%.1f", delay))秒後)")
        
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            
            // 再接続開始
            state = .connecting
            startConnectionTimeout()
            
            // 注意: 実際の接続処理はNetworkReceiverに委譲
            // ここでは状態管理のみを行う
        }
    }
    
    private func startConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        
        connectionTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(configuration.connectionTimeout * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            
            // タイムアウト発生
            if case .connecting = state {
                let error = ConnectionError.timeout
                lastError = error
                notifyDisconnected(error: error, shouldReconnect: true)
            }
        }
    }
    
    private func cancelConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
    }
}

// MARK: - Errors

/// 接続エラー
public enum ConnectionError: LocalizedError {
    case timeout
    case authDenied
    case networkUnavailable
    case hostUnreachable
    case unknown(Error)
    
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "接続がタイムアウトしました"
        case .authDenied:
            return "認証が拒否されました"
        case .networkUnavailable:
            return "ネットワークが利用できません"
        case .hostUnreachable:
            return "ホストに接続できません"
        case .unknown(let error):
            return error.localizedDescription
        }
    }
}
