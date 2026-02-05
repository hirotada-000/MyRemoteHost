//
//  ConnectionManager.swift
//  MyRemoteHost
//
//  接続管理マネージャー（ホスト側）
//  Phase 0: 商用リリース向け基盤整備
//
//  責務:
//  - クライアント接続の一元管理
//  - 接続品質モニタリング
//  - グレースフルな切断処理
//

import Foundation
import Combine

/// 接続管理マネージャー（ホスト側）
/// 複数クライアントの接続ライフサイクルを管理
@MainActor
public final class HostConnectionManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// 接続中のクライアント数
    @Published public private(set) var connectedClientCount: Int = 0
    
    /// 接続中のクライアント一覧
    @Published public private(set) var connectedClients: [String: ClientConnection] = [:]
    
    /// リスニング状態
    @Published public private(set) var isListening: Bool = false
    
    // MARK: - Types
    
    /// クライアント接続情報
    public struct ClientConnection: Identifiable {
        public let id: String
        public let endpoint: NetworkEndpoint
        public let connectedAt: Date
        public var lastActivity: Date
        public var userRecordID: String?
        
        public init(endpoint: NetworkEndpoint, userRecordID: String? = nil) {
            self.id = endpoint.description
            self.endpoint = endpoint
            self.connectedAt = Date()
            self.lastActivity = Date()
            self.userRecordID = userRecordID
        }
        
        /// 接続時間（秒）
        public var connectionDuration: TimeInterval {
            Date().timeIntervalSince(connectedAt)
        }
        
        /// 最後のアクティビティからの経過時間（秒）
        public var idleTime: TimeInterval {
            Date().timeIntervalSince(lastActivity)
        }
    }
    
    /// 設定
    public struct Configuration {
        /// クライアントタイムアウト（秒）
        public let clientTimeout: TimeInterval
        
        /// 最大同時接続数
        public let maxClients: Int
        
        /// クリーンアップ間隔（秒）
        public let cleanupInterval: TimeInterval
        
        public static let `default` = Configuration(
            clientTimeout: 10.0,
            maxClients: 5,
            cleanupInterval: 5.0
        )
        
        public init(clientTimeout: TimeInterval, maxClients: Int, cleanupInterval: TimeInterval) {
            self.clientTimeout = clientTimeout
            self.maxClients = maxClients
            self.cleanupInterval = cleanupInterval
        }
    }
    
    // MARK: - Private Properties
    
    private let configuration: Configuration
    private var cleanupTask: Task<Void, Never>?
    
    /// クライアント接続時コールバック
    public var onClientConnected: ((ClientConnection) -> Void)?
    
    /// クライアント切断時コールバック
    public var onClientDisconnected: ((ClientConnection) -> Void)?
    
    /// 認証リクエスト時コールバック
    public var onAuthRequest: ((NetworkEndpoint, String?) -> Void)?
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }
    
    // MARK: - Public Methods
    
    /// リスニング開始
    public func startListening() {
        isListening = true
        startCleanupTimer()
        print("[HostConnectionManager] リスニング開始")
    }
    
    /// リスニング停止
    public func stopListening() {
        isListening = false
        cleanupTask?.cancel()
        cleanupTask = nil
        
        // 全クライアント切断
        for client in connectedClients.values {
            onClientDisconnected?(client)
        }
        connectedClients.removeAll()
        connectedClientCount = 0
        
        print("[HostConnectionManager] リスニング停止")
    }
    
    /// 認証リクエストを処理
    public func handleAuthRequest(from endpoint: NetworkEndpoint, userRecordID: String?) {
        // 既存クライアントのハートビート更新
        if var existing = connectedClients[endpoint.description] {
            existing.lastActivity = Date()
            connectedClients[endpoint.description] = existing
            return
        }
        
        // 最大接続数チェック
        if connectedClients.count >= configuration.maxClients {
            print("[HostConnectionManager] ⚠️ 最大接続数に達しています: \(configuration.maxClients)")
            return
        }
        
        // 認証リクエストコールバック
        onAuthRequest?(endpoint, userRecordID)
        print("[HostConnectionManager] 認証リクエスト: \(endpoint.description)")
    }
    
    /// クライアント接続を許可
    public func approveClient(endpoint: NetworkEndpoint, userRecordID: String? = nil) {
        let client = ClientConnection(endpoint: endpoint, userRecordID: userRecordID)
        connectedClients[endpoint.description] = client
        connectedClientCount = connectedClients.count
        
        onClientConnected?(client)
        print("[HostConnectionManager] ✅ クライアント許可: \(endpoint.description)")
    }
    
    /// クライアント接続を拒否
    public func denyClient(endpoint: NetworkEndpoint) {
        print("[HostConnectionManager] ❌ クライアント拒否: \(endpoint.description)")
    }
    
    /// クライアントのアクティビティを更新
    public func updateClientActivity(endpoint: NetworkEndpoint) {
        if var existing = connectedClients[endpoint.description] {
            existing.lastActivity = Date()
            connectedClients[endpoint.description] = existing
        }
    }
    
    /// クライアントを切断
    public func disconnectClient(endpoint: NetworkEndpoint) {
        if let client = connectedClients.removeValue(forKey: endpoint.description) {
            connectedClientCount = connectedClients.count
            onClientDisconnected?(client)
            print("[HostConnectionManager] クライアント切断: \(endpoint.description)")
        }
    }
    
    // MARK: - Private Methods
    
    private func startCleanupTimer() {
        cleanupTask?.cancel()
        
        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(configuration.cleanupInterval * 1_000_000_000))
                
                guard !Task.isCancelled else { break }
                
                await cleanupStaleClients()
            }
        }
    }
    
    private func cleanupStaleClients() async {
        var timedOutClients: [ClientConnection] = []
        
        for (key, client) in connectedClients {
            if client.idleTime > configuration.clientTimeout {
                timedOutClients.append(client)
                connectedClients.removeValue(forKey: key)
            }
        }
        
        if !timedOutClients.isEmpty {
            connectedClientCount = connectedClients.count
            
            for client in timedOutClients {
                onClientDisconnected?(client)
                print("[HostConnectionManager] クライアントタイムアウト: \(client.endpoint.description)")
            }
        }
    }
}
