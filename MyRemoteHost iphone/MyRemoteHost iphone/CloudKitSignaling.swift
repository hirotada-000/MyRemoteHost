//
//  CloudKitSignaling.swift
//  MyRemoteHost iphone
//
//  CloudKitをシグナリングサーバーとして活用
//  Phase 1: サーバーレス・デバイス発見と接続
//
//  機能:
//  - デバイス発見（自分のApple IDのホスト一覧取得）
//  - ICE候補受信
//

import Foundation
import CloudKit

// MARK: - HostDevice Record

/// CloudKitから取得するホストデバイス情報
public struct HostDeviceRecord: Sendable, Identifiable {
    /// CloudKit Record ID
    let recordID: CKRecord.ID?
    
    /// ホストのApple ID識別子（userRecordID）
    let hostUserRecordID: String
    
    /// デバイス名
    let deviceName: String
    
    /// ローカルIP（LAN内接続用）
    let localIP: String
    
    /// ローカルポート
    let localPort: Int
    
    /// パブリックIP（NAT越え用）
    var publicIP: String?
    
    /// パブリックポート
    var publicPort: Int?
    
    /// オンライン状態
    var isOnline: Bool
    
    /// 最終ハートビート
    var lastHeartbeat: Date
    
    // MARK: - Identifiable
    
    public var id: String {
        recordID?.recordName ?? "\(hostUserRecordID)-\(deviceName)"
    }
    
    // MARK: - CloudKit Keys
    
    static let recordType = "HostDevice"
    
    enum Keys {
        static let hostUserRecordID = "hostUserRecordID"
        static let deviceName = "deviceName"
        static let localIP = "localIP"
        static let localPort = "localPort"
        static let publicIP = "publicIP"
        static let publicPort = "publicPort"
        static let isOnline = "isOnline"
        static let lastHeartbeat = "lastHeartbeat"
    }
    
    // MARK: - Init from CKRecord
    
    init(from record: CKRecord) {
        self.recordID = record.recordID
        self.hostUserRecordID = record[Keys.hostUserRecordID] as? String ?? ""
        self.deviceName = record[Keys.deviceName] as? String ?? "Unknown"
        self.localIP = record[Keys.localIP] as? String ?? ""
        self.localPort = record[Keys.localPort] as? Int ?? Int(NetworkTransportConfiguration.default.videoPort)
        self.publicIP = record[Keys.publicIP] as? String
        self.publicPort = record[Keys.publicPort] as? Int
        self.isOnline = record[Keys.isOnline] as? Bool ?? false
        self.lastHeartbeat = record[Keys.lastHeartbeat] as? Date ?? Date.distantPast
    }
    
    /// 接続用のアドレスを取得（パブリックIPがあればそれを優先）
    var connectionAddress: String {
        if let publicIP = publicIP, !publicIP.isEmpty {
            return publicIP
        }
        return localIP
    }
    
    /// 接続用のポートを取得
    var connectionPort: Int {
        if let publicPort = publicPort, publicPort > 0 {
            return publicPort
        }
        return localPort
    }
    
    /// ハートビートが有効かどうか（5分以内）
    var isHeartbeatValid: Bool {
        Date().timeIntervalSince(lastHeartbeat) < 300
    }
}

// MARK: - CloudKit Signaling Manager (Client)

/// CloudKitシグナリングマネージャー（クライアント側）
/// サーバーレスでデバイス発見を実現
actor CloudKitSignalingManager {
    
    static let shared = CloudKitSignalingManager()
    
    // MARK: - Properties
    
    private let containerID = "iCloud.com.myremotehost.shared"
    private var container: CKContainer { CKContainer(identifier: containerID) }
    
    /// ★ ゼロコスト戦略: Private Databaseを使用
    /// - ユーザーのiCloudストレージを使用するため運営コスト$0
    /// - 同じApple IDのデバイス同士は同じPrivate DBにアクセス可能
    private var database: CKDatabase { container.privateCloudDatabase }
    
    // MARK: - Device Discovery
    
    /// 自分のApple IDに紐づくホストデバイス一覧を取得
    /// ★ Private Databaseでは自分のデータのみアクセス可能なため
    ///   hostUserRecordIDでのフィルタリングは不要
    func discoverMyHosts() async throws -> [HostDeviceRecord] {
        // ★ CloudKitダッシュボードでインデックス追加済み:
        //   - recordName: QUERYABLE
        //   - isOnline: QUERYABLE
        //   - deviceName: QUERYABLE
        //   - lastHeartbeat: SORTABLE
        let predicate = NSPredicate(format: "%K == %@",
                                    HostDeviceRecord.Keys.isOnline, NSNumber(value: true))
        let query = CKQuery(recordType: HostDeviceRecord.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: HostDeviceRecord.Keys.lastHeartbeat, ascending: false)]
        
        let (results, _) = try await database.records(matching: query, resultsLimit: 10)
        
        var hosts: [HostDeviceRecord] = []
        for (_, result) in results {
            if case .success(let record) = result {
                let host = HostDeviceRecord(from: record)
                // ハートビート10分以内のみ有効
                if Date().timeIntervalSince(host.lastHeartbeat) < 600 {
                    hosts.append(host)
                }
            }
        }
        
        print("[CloudKitSignaling] 🔍 発見したホスト: \(hosts.count)台 (Private DB, CKQuery)")
        return hosts
    }
    
    /// 特定のホストの最新情報を取得
    func refreshHost(recordID: CKRecord.ID) async throws -> HostDeviceRecord? {
        do {
            let record = try await database.record(for: recordID)
            let host = HostDeviceRecord(from: record)
            return host.isOnline && host.isHeartbeatValid ? host : nil
        } catch {
            print("[CloudKitSignaling] ホスト情報取得失敗: \(error)")
            return nil
        }
    }
    
    // MARK: - ICE Candidate Exchange
    
    /// 指定ホストのICE候補を取得
    func fetchICECandidates(for host: HostDeviceRecord) async throws -> [ICECandidate] {
        guard let recordID = host.recordID else {
            return generateCandidatesFromHostRecord(host)
        }
        
        let record = try await database.record(for: recordID)
        
        guard let candidatesJSON = record["iceCandidates"] as? String,
              let candidatesData = candidatesJSON.data(using: .utf8) else {
            // ICE候補がない場合、ローカル/パブリックIPから候補を生成
            return generateCandidatesFromHostRecord(host)
        }
        
        let decoder = JSONDecoder()
        let candidates = try decoder.decode([ICECandidate].self, from: candidatesData)
        print("[CloudKitSignaling] 📥 ICE候補取得: \(candidates.count)件")
        return candidates
    }
    
    /// HostDeviceRecordからICE候補を生成（フォールバック）
    private func generateCandidatesFromHostRecord(_ host: HostDeviceRecord) -> [ICECandidate] {
        var candidates: [ICECandidate] = []
        
        // ローカル候補
        if !host.localIP.isEmpty {
            candidates.append(ICECandidate(
                type: .host,
                ip: host.localIP,
                port: host.localPort,
                priority: 1000
            ))
        }
        
        // パブリック候補
        if let publicIP = host.publicIP, let publicPort = host.publicPort {
            candidates.append(ICECandidate(
                type: .serverReflexive,
                ip: publicIP,
                port: publicPort,
                priority: 500
            ))
        }
        
        return candidates
    }
}

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
