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
    
    /// 接続タイムアウト（秒）— host/srflx候補用
    /// ★ B-1: TURN relay独立タイムアウトのため短め設定
    private let connectionTimeout: TimeInterval = 1.5
    
    /// ★ B-1: TURN relay専用タイムアウト（秒）
    private let turnRelayTimeout: TimeInterval = 10.0
    
    /// ★ B-1: ICE進行中フラグ（外部から確認可能）
    private(set) var isICEInProgress: Bool = false
    
    /// ホールパンチメッセージ
    private let holePunchMessage = "PUNCH".data(using: .utf8)!
    
    /// 接続確立メッセージ
    private let connectAckMessage = "ACK".data(using: .utf8)!
    
    /// 同期用キュー
    private let queue = DispatchQueue(label: "P2PConnectionManager")
    
    /// ★ Phase 1: TURNクライアント（Step 2: データパス統合のためpublic read可能に）
    private(set) var turnClient: TURNClient?
    
    /// ★ A-2修正: iPhone自身のrelayアドレス（Mac側への登録パケットに含める）
    private(set) var myRelayIP: String = ""
    private(set) var myRelayPort: UInt16 = 0
    
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
    
    /// ICE候補を使用したP2P接続（★ B-1: 再設計版）
    /// host/srflxを順次試行 → 全失敗時にrelay(TURN)をフォールバック
    public func connectWithICE(candidates: [ICECandidate]) {
        state = .discovering
        isICEInProgress = true
        notifyStateChange()
        
        guard !candidates.isEmpty else {
            Logger.p2p("❌ ICE候補がありません", level: .error)
            isICEInProgress = false
            state = .failed(reason: "ICE候補がありません")
            notifyStateChange()
            return
        }
        
        // ★ B-1: host/srflxとrelayを分離
        let sortedCandidates = candidates.sorted { $0.priority > $1.priority }
        let directCandidates = sortedCandidates.filter { $0.type != .relay }
        let relayCandidates = sortedCandidates.filter { $0.type == .relay }
        
        Logger.p2p("📋 ICE候補試行開始: direct=\(directCandidates.count)件, relay=\(relayCandidates.count)件")
        
        // ★ B-1: まずhost/srflxを順次試行
        tryDirectCandidates(directCandidates, index: 0) { [weak self] success in
            guard let self = self else { return }
            if success { return }
            
            // ★ B-1: 全direct失敗 → relay(TURN)フォールバック
            if let relay = relayCandidates.first {
                Logger.p2p("🔄 direct候補全失敗 → TURN relayフォールバック: \(relay.ip):\(relay.port)")
                self.attemptTURNRelay(
                    relayIP: relay.ip,
                    relayPort: UInt16(relay.port)
                ) { [weak self] success in
                    guard let self = self else { return }
                    self.isICEInProgress = false
                    if !success {
                        // ★ B-1: TURN含む全候補失敗 → ここで初めて.failedをnotify
                        Logger.p2p("❌ すべてのICE候補で失敗（relay含む）", level: .error)
                        self.state = .failed(reason: "すべての接続候補で失敗しました")
                        self.notifyStateChange()
                    }
                }
            } else {
                // relay候補なし → 即失敗
                self.isICEInProgress = false
                Logger.p2p("❌ すべてのICE候補で失敗（relay候補なし）", level: .error)
                self.state = .failed(reason: "すべての接続候補で失敗しました")
                self.notifyStateChange()
            }
        }
    }
    
    /// ★ B-1: host/srflx候補を順次試行（.failedをnotifyしない）
    private func tryDirectCandidates(_ candidates: [ICECandidate], index: Int, completion: @escaping (Bool) -> Void) {
        guard index < candidates.count else {
            // ★ B-1: 全direct候補失敗 → .failedはnotifyせずcompletionのみ
            Logger.p2p("⚠️ direct候補全失敗 (\(candidates.count)件)")
            completion(false)
            return
        }
        
        let candidate = candidates[index]
        Logger.p2p("🔄 候補試行 [\(index + 1)/\(candidates.count)]: [\(candidate.type.rawValue)] \(candidate.ip):\(candidate.port)")
        
        switch candidate.type {
        case .host:
            attemptDirectConnectWithFallback(
                ip: candidate.ip,
                port: UInt16(candidate.port)
            ) { [weak self] success in
                if success {
                    self?.isICEInProgress = false
                    completion(true)
                } else {
                    self?.tryDirectCandidates(candidates, index: index + 1, completion: completion)
                }
            }
            
        case .serverReflexive:
            attemptHolePunch(ip: candidate.ip, port: UInt16(candidate.port)) { [weak self] success in
                if success {
                    self?.isICEInProgress = false
                    completion(true)
                } else {
                    self?.tryDirectCandidates(candidates, index: index + 1, completion: completion)
                }
            }
            
        case .relay:
            // relay候補はここでは処理しない（connectWithICEのフォールバックで処理）
            self.tryDirectCandidates(candidates, index: index + 1, completion: completion)
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
        // ★ 高速化: 3.0s -> 1.5s
        let candidateTimeout: TimeInterval = 1.5
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
        
        // ★ Phase 1: TURN Allocation解放
        if let tc = turnClient {
            Task {
                await tc.deallocate()
            }
            turnClient = nil
        }
    }
    
    // MARK: - Private Methods
    
    /// ★ Phase 1: TURN リレー経由接続
    private func attemptTURNRelay(relayIP: String, relayPort: UInt16, completion: @escaping (Bool) -> Void) {
        Logger.p2p("🔄 TURN リレー接続開始...")
        
        Task {
            do {
                let client = TURNClient()
                self.turnClient = client
                
                // 1. TURN Allocate（リレーアドレス取得）
                let allocation = try await client.allocate()
                Logger.p2p("✅ TURN Allocate成功: \(allocation.relayIP):\(allocation.relayPort)")
                self.myRelayIP = allocation.relayIP
                self.myRelayPort = UInt16(allocation.relayPort)
                
                // 2. macOSホスト側へのPermission作成
                try await client.createPermission(for: relayIP, peerPort: relayPort)
                Logger.p2p("✅ Permission作成成功")
                
                // 3. ChannelBind（効率的データ転送用）
                let channel = try await client.channelBind(peerIP: relayIP, peerPort: relayPort)
                Logger.p2p("✅ ChannelBind成功: ch=\(String(format: "0x%04X", channel))")
                
                // ★ B-3: セットアップ完了後にデータ受信ループを開始
                // allocate()内で開始するとcreatePermission/channelBindのsendAndReceive()と競合するため
                await client.startReceiving()
                
                // 4. 接続成功通知
                DispatchQueue.main.async { [weak self] in
                    // ★ 修正: endpointにはMac側のrelayアドレスを使用（allocation.relayIPはiPhone自身のrelay）
                    self?.state = .connected(endpoint: "TURN:\(relayIP):\(relayPort)")
                    self?.notifyStateChange()
                    
                    // NetworkReceiverに接続先を通知
                    // TURN経由の場合、実際のデータはTURNClient経由で送受信される
                    Logger.p2p("✅ TURN リレー接続確立完了")
                    completion(true)
                }
            } catch {
                Logger.p2p("❌ TURN リレー接続失敗: \(error.localizedDescription)", level: .error)
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
    
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
        // ★ B-1: .failedをnotifyしない（completion(false)で次候補に遷移）
        queue.asyncAfter(deadline: .now() + connectionTimeout) { [weak self] in
            guard !hasCompleted else { return }
            hasCompleted = true
            conn.cancel()
            Logger.p2p("⏱️ holePunchタイムアウト（次候補に遷移）")
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
    
    // MARK: - Smart Connection Extensions
    
    /// 接続ハンドラを設定（RemoteViewModel互換用）
    public func setConnectionHandler(_ handler: @escaping (P2PConnectionState) -> Void) {
        self.onStateChange = handler
    }
    
    /// ICE候補を使って接続開始（RemoteViewModel互換用）
    // iPhone版は既存の connectWithICE があるが、引数や挙動が異なる可能性があるため調整
    // 既存の connectWithICE(candidates:) は既に実装されている（96行目付近）
    // しかし、RemoteViewModelは setConnectionHandler を使って状態監視しようとしている
    // 既存実装では onStateChange を使うので、setConnectionHandler はそのエイリアスとして機能させる
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
