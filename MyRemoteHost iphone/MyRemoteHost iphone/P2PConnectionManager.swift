//
//  P2PConnectionManager.swift
//  MyRemoteHost iphone
//
//  P2Pホールパンチングによる直接接続管理
//  Phase 2: NAT Traversal
//
//  動作フロー:
//  1. CloudKitから相手のIP/ポート取得
//  2. 双方から同時にUDPパケット送信（穴あけ）
//  3. 接続確立確認
//

import Foundation
import Network

// MARK: - P2P Connection State

/// P2P接続状態
public enum P2PConnectionState: Equatable, Sendable {
    case idle
    case discovering
    case holePunching
    case connected(endpoint: String)
    case failed(reason: String)
}

// MARK: - P2P Connection Manager

/// P2Pホールパンチング接続マネージャー
public class P2PConnectionManager {
    
    // MARK: - Properties
    
    /// 接続状態
    private(set) var state: P2PConnectionState = .idle
    
    /// UDPコネクション
    private var connection: NWConnection?
    
    /// ホールパンチング試行回数
    private let maxHolePunchAttempts = 10
    
    /// ホールパンチング間隔（ミリ秒）
    private let holePunchInterval: UInt64 = 200
    
    /// 接続タイムアウト（秒）
    private let connectionTimeout: TimeInterval = 10.0
    
    /// ホールパンチメッセージ
    private let holePunchMessage = "PUNCH".data(using: .utf8)!
    
    /// 接続確立メッセージ
    private let connectAckMessage = "ACK".data(using: .utf8)!
    
    /// 同期用キュー
    private let queue = DispatchQueue(label: "P2PConnectionManager")
    
    // MARK: - Callbacks
    
    /// 状態変更コールバック
    var onStateChange: ((P2PConnectionState) -> Void)?
    
    /// 接続成功コールバック（確立したコネクションを返す）
    var onConnected: ((NWConnection) -> Void)?
    
    // MARK: - Public Methods
    
    /// P2P接続を開始（iPhone側から呼ぶ）- 従来の互換メソッド
    public func connect(to host: HostDeviceRecord) {
        state = .discovering
        notifyStateChange()
        
        // 1. 公開IPがあれば公開IP経由で接続試行
        if let publicIP = host.publicIP, let publicPort = host.publicPort, !publicIP.isEmpty {
            Logger.p2p("🌐 公開IP経由で接続試行: \(publicIP):\(publicPort)")
            attemptHolePunch(ip: publicIP, port: UInt16(publicPort)) { [weak self] success in
                if success {
                    return
                }
                // ローカルIPにフォールバック
                Logger.p2p("公開IP接続失敗、ローカルIPにフォールバック", level: .warning)
                self?.attemptDirectConnect(ip: host.localIP, port: UInt16(host.localPort))
            }
        } else {
            // 2. ローカルIP経由で接続試行
            Logger.p2p("📍 ローカルIP経由で接続試行: \(host.localIP):\(host.localPort)")
            attemptDirectConnect(ip: host.localIP, port: UInt16(host.localPort))
        }
    }
    
    /// ICE候補を使用したP2P接続（強化版）
    public func connectWithICE(candidates: [ICECandidate]) {
        state = .discovering
        notifyStateChange()
        
        guard !candidates.isEmpty else {
            Logger.p2p("❌ ICE候補がありません", level: .error)
            state = .failed(reason: "ICE候補がありません")
            notifyStateChange()
            return
        }
        
        // 優先度順にソート
        let sortedCandidates = candidates.sorted { $0.priority > $1.priority }
        Logger.p2p("📋 ICE候補試行開始: \(sortedCandidates.count)件")
        
        // 順次試行
        tryNextCandidate(sortedCandidates, index: 0)
    }
    
    /// 次の候補を試行
    private func tryNextCandidate(_ candidates: [ICECandidate], index: Int) {
        guard index < candidates.count else {
            Logger.p2p("❌ すべてのICE候補で失敗", level: .error)
            state = .failed(reason: "すべての接続候補で失敗しました")
            notifyStateChange()
            return
        }
        
        let candidate = candidates[index]
        Logger.p2p("🔄 候補試行 [\(index + 1)/\(candidates.count)]: [\(candidate.type.rawValue)] \(candidate.ip):\(candidate.port)")
        
        switch candidate.type {
        case .host:
            // ローカル候補は直接接続
            attemptDirectConnectWithFallback(
                ip: candidate.ip,
                port: UInt16(candidate.port)
            ) { [weak self] success in
                if !success {
                    self?.tryNextCandidate(candidates, index: index + 1)
                }
            }
            
        case .serverReflexive:
            // STUN候補はホールパンチング
            attemptHolePunch(ip: candidate.ip, port: UInt16(candidate.port)) { [weak self] success in
                if !success {
                    self?.tryNextCandidate(candidates, index: index + 1)
                }
            }
            
        case .relay:
            // リレー候補（将来のCloudflare対応用）
            Logger.p2p("⚠️ リレー候補は未実装、スキップ", level: .warning)
            tryNextCandidate(candidates, index: index + 1)
        }
    }
    
    /// 直接接続試行（フォールバック付き）
    private func attemptDirectConnectWithFallback(ip: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        let params = NWParameters.udp
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        
        var hasCompleted = false
        
        // 短いタイムアウト（候補ごとに素早く試行）
        let candidateTimeout: TimeInterval = 3.0
        queue.asyncAfter(deadline: .now() + candidateTimeout) { [weak self] in
            guard !hasCompleted else { return }
            hasCompleted = true
            conn.cancel()
            Logger.p2p("候補タイムアウト: \(ip):\(port)", level: .debug)
            completion(false)
        }
        
        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            
            switch newState {
            case .ready:
                // 接続確認パケット送信
                conn.send(content: self.connectAckMessage, completion: .contentProcessed { _ in })
                
                // レスポンス受信
                self.receiveResponse(connection: conn) { success in
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    
                    if success {
                        Logger.p2p("✅ 接続成功: \(ip):\(port)")
                        self.state = .connected(endpoint: "\(ip):\(port)")
                        self.notifyStateChange()
                        self.onConnected?(conn)
                        completion(true)
                    } else {
                        conn.cancel()
                        completion(false)
                    }
                }
                
            case .failed(let error):
                guard !hasCompleted else { return }
                hasCompleted = true
                Logger.p2p("接続失敗: \(error)", level: .debug)
                completion(false)
                
            case .cancelled:
                guard !hasCompleted else { return }
                hasCompleted = true
                completion(false)
                
            default:
                break
            }
        }
        
        conn.start(queue: queue)
    }
    
    /// 接続を切断
    public func disconnect() {
        connection?.cancel()
        connection = nil
        state = .idle
        notifyStateChange()
    }
    
    // MARK: - Private Methods
    
    /// ホールパンチング試行
    private func attemptHolePunch(ip: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        state = .holePunching
        notifyStateChange()
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        // UDPパラメータ設定
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        
        var hasCompleted = false
        
        // タイムアウト
        queue.asyncAfter(deadline: .now() + connectionTimeout) { [weak self] in
            guard !hasCompleted else { return }
            hasCompleted = true
            conn.cancel()
            self?.state = .failed(reason: "タイムアウト")
            self?.notifyStateChange()
            completion(false)
        }
        
        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            
            switch newState {
            case .ready:
                // ホールパンチングパケット送信開始
                self.sendHolePunchPackets(connection: conn)
                
                // レスポンス受信待機
                self.receiveResponse(connection: conn) { success in
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    
                    if success {
                        self.state = .connected(endpoint: "\(ip):\(port)")
                        self.notifyStateChange()
                        self.onConnected?(conn)
                        completion(true)
                    } else {
                        conn.cancel()
                        completion(false)
                    }
                }
                
            case .failed(let error):
                guard !hasCompleted else { return }
                hasCompleted = true
                Logger.p2p("接続失敗: \(error)", level: .error)
                self.state = .failed(reason: error.localizedDescription)
                self.notifyStateChange()
                completion(false)
                
            case .cancelled:
                guard !hasCompleted else { return }
                hasCompleted = true
                completion(false)
                
            default:
                break
            }
        }
        
        conn.start(queue: queue)
    }
    
    /// 直接接続試行（ローカルIP用）
    private func attemptDirectConnect(ip: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        let params = NWParameters.udp
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        
        var hasCompleted = false
        
        // タイムアウト
        queue.asyncAfter(deadline: .now() + connectionTimeout) { [weak self] in
            guard !hasCompleted else { return }
            hasCompleted = true
            conn.cancel()
            self?.state = .failed(reason: "タイムアウト")
            self?.notifyStateChange()
        }
        
        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            
            switch newState {
            case .ready:
                // 接続確認パケット送信
                conn.send(content: self.connectAckMessage, completion: .contentProcessed { _ in })
                
                // レスポンス受信
                self.receiveResponse(connection: conn) { success in
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    
                    if success {
                        self.state = .connected(endpoint: "\(ip):\(port)")
                        self.notifyStateChange()
                        self.onConnected?(conn)
                    } else {
                        conn.cancel()
                        self.state = .failed(reason: "接続失敗")
                        self.notifyStateChange()
                    }
                }
                
            case .failed(let error):
                guard !hasCompleted else { return }
                hasCompleted = true
                Logger.p2p("直接接続失敗: \(error)", level: .error)
                self.state = .failed(reason: error.localizedDescription)
                self.notifyStateChange()
                
            default:
                break
            }
        }
        
        conn.start(queue: queue)
    }
    
    /// ホールパンチングパケット送信
    private func sendHolePunchPackets(connection: NWConnection) {
        for i in 0..<maxHolePunchAttempts {
            queue.asyncAfter(deadline: .now() + Double(i) * Double(holePunchInterval) / 1000.0) { [weak self] in
                guard let self = self else { return }
                connection.send(content: self.holePunchMessage, completion: .contentProcessed { error in
                    if let error = error {
                        Logger.p2p("パンチ送信エラー: \(error)", level: .warning)
                    }
                })
                Logger.p2p("👊 パンチ送信 \(i + 1)/\(self.maxHolePunchAttempts)", level: .debug)
            }
        }
    }
    
    /// レスポンス受信
    private func receiveResponse(connection: NWConnection, completion: @escaping (Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, error in
            if let error = error {
                Logger.p2p("受信エラー: \(error)", level: .warning)
                completion(false)
                return
            }
            
            if let data = data, !data.isEmpty {
                Logger.p2p("✅ レスポンス受信: \(data.count) bytes")
                completion(true)
            } else {
                // データなしでも続けて受信待機
                self?.receiveResponse(connection: connection, completion: completion)
            }
        }
    }
    
    /// 状態変更通知
    private func notifyStateChange() {
        let currentState = state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(currentState)
        }
    }
}

// MARK: - P2P Errors

public enum P2PError: Error, LocalizedError {
    case timeout
    case cancelled
    case noPublicIP
    case connectionFailed
    
    public var errorDescription: String? {
        switch self {
        case .timeout: return "P2P接続がタイムアウトしました"
        case .cancelled: return "P2P接続がキャンセルされました"
        case .noPublicIP: return "公開IPが見つかりません"
        case .connectionFailed: return "P2P接続に失敗しました"
        }
    }
}
