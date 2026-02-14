//
//  P2PConnectionManager.swift
//  MyRemoteHost
//
//  P2P接続マネージャー
//  同時発信ホールパンチングによる直接接続を試行し、
//  失敗時はCloudKitシグナリングを活用
//
//  Phase 1: 強化P2P実装
//

import Foundation
import Network

// MARK: - ICE Candidate

/// ICE候補（接続候補アドレス）
public struct ICECandidate: Codable, Sendable {
    public let type: CandidateType
    public let ip: String
    public let port: Int
    public let priority: Int
    
    public enum CandidateType: String, Codable, Sendable {
        case host = "host"           // ローカルアドレス
        case serverReflexive = "srflx"  // STUN経由（パブリック）
        case relay = "relay"         // リレー経由
    }
    
    public init(type: CandidateType, ip: String, port: Int, priority: Int) {
        self.type = type
        self.ip = ip
        self.port = port
        self.priority = priority
    }
}

// MARK: - P2P Connection State

/// P2P接続状態
public enum P2PConnectionState: Sendable {
    case idle
    case gatheringCandidates
    case exchangingCandidates
    case attemptingConnection
    case connected(method: String)
    case failed(reason: String)
}

// MARK: - P2P Connection Manager

/// P2P接続マネージャー
/// 同時発信ホールパンチングを実装
public actor P2PConnectionManager {
    
    // MARK: - Properties
    
    /// 追加STUNサーバー（Cloudflare、Mozilla等）
    private let additionalSTUNServers: [(String, UInt16)] = [
        ("stun.cloudflare.com", 3478),
        ("stun.services.mozilla.com", 3478)
    ]
    
    /// 収集されたICE候補
    private var localCandidates: [ICECandidate] = []
    private var remoteCandidates: [ICECandidate] = []
    
    /// 現在の状態
    private var state: P2PConnectionState = .idle
    
    /// ローカルリスニングポート
    private var localListeningPort: UInt16 = 0
    
    /// 確立された接続
    private var establishedConnection: NWConnection?
    
    /// ホールパンチング用リスナー
    private var holePunchListener: NWListener?
    
    /// 接続タイムアウト（秒）
    private let connectionTimeout: TimeInterval = 10.0
    
    /// 同時接続試行の最大数
    private let maxSimultaneousAttempts = 5
    
    /// ★ Step 2: アクティブなTURNクライアント（relay用に維持）
    private(set) var activeTURNClient: TURNClient?
    
    // MARK: - Public Methods
    
    /// ICE候補を収集（ローカル + STUN + TURN）
    public func gatherCandidates(localPort: Int) async throws -> [ICECandidate] {
        state = .gatheringCandidates
        localCandidates = []
        localListeningPort = UInt16(localPort)
        
        // 1. ローカル候補（host）を追加
        let localIPs = getLocalIPAddresses()
        for (index, ip) in localIPs.enumerated() {
            let candidate = ICECandidate(
                type: .host,
                ip: ip,
                port: localPort,
                priority: 1000 - index  // ローカルは高優先度
            )
            localCandidates.append(candidate)
            Logger.p2p("📍 Host候補: \(ip):\(localPort)")
        }
        
        // 2. STUN候補（srflx）を取得
        let stunClient = STUNClient()
        do {
            let stunResult = try await stunClient.discoverPublicEndpoint()
            let candidate = ICECandidate(
                type: .serverReflexive,
                ip: stunResult.publicIP,
                port: Int(stunResult.publicPort),
                priority: 500  // STUN候補は中優先度
            )
            localCandidates.append(candidate)
            Logger.p2p("🌐 STUN候補: \(stunResult.publicIP):\(stunResult.publicPort)")
        } catch {
            Logger.p2p("⚠️ STUN候補取得失敗: \(error.localizedDescription)", level: .warning)
        }
        
        // 3. TURN候補（relay）を取得
        do {
            let turnClient = TURNClient()
            let allocation = try await turnClient.allocate()
            let relayCandidates = await turnClient.getRelayCandidates()
            localCandidates.append(contentsOf: relayCandidates)
            Logger.p2p("🔄 TURN候補: \(allocation.relayIP):\(allocation.relayPort)")
            // ★ Step 2: Allocationを維持（TURN relay用）
            // 以前は候補収集後すぐにdeallocateしていたが、
            // TURN relay経由のデータ転送に使用するため維持する
            self.activeTURNClient = turnClient
        } catch {
            Logger.p2p("⚠️ TURN候補取得失敗（Oracle TURN未設定の可能性）: \(error.localizedDescription)", level: .warning)
        }
        
        return localCandidates
    }
    
    /// リモート候補を設定
    public func setRemoteCandidates(_ candidates: [ICECandidate]) {
        remoteCandidates = candidates
        Logger.p2p("📥 リモート候補受信: \(candidates.count)件")
        for candidate in candidates {
            Logger.p2p("  - [\(candidate.type.rawValue)] \(candidate.ip):\(candidate.port)")
        }
    }
    
    // MARK: - Smart Connection Extensions
    
    /// 接続ハンドラ
    private var connectionHandler: ((P2PConnectionState) -> Void)?
    
    /// 接続ハンドラを設定
    public func setConnectionHandler(_ handler: @escaping (P2PConnectionState) -> Void) {
        self.connectionHandler = handler
    }
    
    /// ICE候補を使って接続開始（ラッパー）
    public func connectWithICE(candidates: [ICECandidate]) {
        Task {
            // 状態更新
            state = .exchangingCandidates
            connectionHandler?(.exchangingCandidates)
            
            // ローカル候補収集（自分側も準備が必要）
            // ポートはデフォルト設定を使用（動的ポート割り当て）
            let _ = try? await gatherCandidates(localPort: 0)
            
            // リモート候補設定
            setRemoteCandidates(candidates)
            
            do {
                // 接続試行
                state = .attemptingConnection
                connectionHandler?(.attemptingConnection)
                
                let connection = try await attemptConnection()
                
                // 成功時はエンドポイント文字列を返す（簡易実装）
                // 実際にはNWConnectionを返す方が良いが、RemoteViewModel側で再接続するためエンドポイント情報だけで十分
                if let endpoint = connection.currentPath?.remoteEndpoint {
                     switch endpoint {
                     case .hostPort(let host, let port):
                         let endpointStr = "\(host):\(port)"
                         state = .connected(method: endpointStr)
                         connectionHandler?(.connected(method: endpointStr))
                     default:
                         state = .connected(method: "Unknown Endpoint")
                         connectionHandler?(.connected(method: "Unknown Endpoint"))
                     }
                }
            } catch {
                let reason = error.localizedDescription
                state = .failed(reason: reason)
                connectionHandler?(.failed(reason: reason))
            }
        }
    }
    
    /// 同時発信ホールパンチングを実行
    public func attemptConnection() async throws -> NWConnection {
        state = .attemptingConnection
        
        guard !remoteCandidates.isEmpty else {
            throw P2PError.noCandidates
        }
        
        // 優先度順にソート
        let sortedCandidates = remoteCandidates.sorted { $0.priority > $1.priority }
        
        // ホールパンチング用リスナーを開始
        try await startHolePunchListener()
        
        // 同時発信を試行
        return try await withThrowingTaskGroup(of: NWConnection?.self) { group in
            // 各候補に対して同時に接続試行
            for candidate in sortedCandidates.prefix(maxSimultaneousAttempts) {
                group.addTask {
                    try await self.attemptConnectionTo(candidate)
                }
            }
            
            // 最初に成功した接続を返す
            for try await result in group {
                if let connection = result {
                    group.cancelAll()
                    state = .connected(method: "P2P Hole Punch")
                    establishedConnection = connection
                    Logger.p2p("✅ P2P接続成功!")
                    return connection
                }
            }
            
            throw P2PError.allAttemptsFailed
        }
    }
    
    /// 接続をクリーンアップ
    public func cleanup() async {
        holePunchListener?.cancel()
        holePunchListener = nil
        establishedConnection?.cancel()
        establishedConnection = nil
        localCandidates = []
        remoteCandidates = []
        state = .idle
        
        // ★ Step 2: TURN Allocation解放
        if let turnClient = activeTURNClient {
            await turnClient.deallocate()
            activeTURNClient = nil
        }
    }
    
    // MARK: - Private Methods
    
    /// ホールパンチング用リスナーを開始
    private func startHolePunchListener() async throws {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        let port = localListeningPort
        holePunchListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        
        holePunchListener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Logger.p2p("🎯 ホールパンチリスナー開始: ポート\(port)")
            case .failed(let error):
                Logger.p2p("❌ ホールパンチリスナー失敗: \(error)", level: .error)
            default:
                break
            }
        }
        
        holePunchListener?.newConnectionHandler = { connection in
            Logger.p2p("🔔 ホールパンチ着信接続!")
            // 着信接続を処理
            connection.start(queue: .global())
        }
        
        holePunchListener?.start(queue: .global())
    }
    
    /// 単一の候補に接続試行
    private func attemptConnectionTo(_ candidate: ICECandidate) async throws -> NWConnection? {
        Logger.p2p("🔄 接続試行: [\(candidate.type.rawValue)] \(candidate.ip):\(candidate.port)")
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(candidate.ip),
            port: NWEndpoint.Port(rawValue: UInt16(candidate.port))!
        )
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        // ローカルポートを固定（ホールパンチングに重要）
        if let localPort = NWEndpoint.Port(rawValue: localListeningPort) {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: localPort)
        }
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            
            // タイムアウト
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(connectionTimeout * 1_000_000_000))
                if !hasResumed {
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(returning: nil)
                }
            }
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !hasResumed {
                        hasResumed = true
                        timeoutTask.cancel()
                        Logger.p2p("✅ 接続確立: \(candidate.ip):\(candidate.port)")
                        
                        // 疎通確認パケットを送信
                        let pingData = "P2P_PING".data(using: .utf8)!
                        connection.send(content: pingData, completion: .contentProcessed { error in
                            if error == nil {
                                continuation.resume(returning: connection)
                            } else {
                                connection.cancel()
                                continuation.resume(returning: nil)
                            }
                        })
                    }
                    
                case .failed(_), .cancelled:
                    if !hasResumed {
                        hasResumed = true
                        timeoutTask.cancel()
                        continuation.resume(returning: nil)
                    }
                    
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
        }
    }
    
    /// ローカルIPアドレスを取得
    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 (Wi-Fi), en1 (有線) などを優先
                if name.hasPrefix("en") || name.hasPrefix("utun") {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if !ip.isEmpty && !ip.hasPrefix("127.") {
                        addresses.append(ip)
                    }
                }
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        return addresses
    }
}

// MARK: - P2P Errors

public enum P2PError: Error, LocalizedError {
    case noCandidates
    case allAttemptsFailed
    case connectionFailed
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .noCandidates: return "リモート候補がありません"
        case .allAttemptsFailed: return "すべての接続試行が失敗しました"
        case .connectionFailed: return "P2P接続に失敗しました"
        case .timeout: return "接続タイムアウト"
        }
    }
}

// MARK: - Logger Extension

extension Logger {
    static func p2p(_ message: String, level: LogLevel = .info) {
        shared.log(message, level: level, category: .network)
    }
}
