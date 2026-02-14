//
//  CloudKitSignaling.swift
//  MyRemoteHost
//
//  CloudKitをシグナリングサーバーとして活用
//  Phase 1: サーバーレス・デバイス発見と接続
//
//  機能:
//  - デバイス登録（HostDevice レコード）
//  - プレゼンス管理（ハートビート）
//  - ICE候補交換
//

import Foundation
import CloudKit
import Network

// MARK: - HostDevice Record

/// CloudKitに保存するホストデバイス情報
public struct HostDeviceRecord: Sendable {
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
    
    /// パブリックIP（NAT越え用、STUNで取得予定）
    var publicIP: String?
    
    /// パブリックポート
    var publicPort: Int?
    
    /// オンライン状態
    var isOnline: Bool
    
    /// 最終ハートビート
    var lastHeartbeat: Date
    
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
    
    // MARK: - Init
    
    init(hostUserRecordID: String, deviceName: String, localIP: String, localPort: Int) {
        self.recordID = nil
        self.hostUserRecordID = hostUserRecordID
        self.deviceName = deviceName
        self.localIP = localIP
        self.localPort = localPort
        self.publicIP = nil
        self.publicPort = nil
        self.isOnline = true
        self.lastHeartbeat = Date()
    }
    
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
    
    func toCKRecord() -> CKRecord {
        let record: CKRecord
        if let existingID = recordID {
            record = CKRecord(recordType: Self.recordType, recordID: existingID)
        } else {
            // デバイスごとに一意のIDを生成（userRecordID + デバイス名のハッシュ）
            let uniqueID = "\(hostUserRecordID)-\(deviceName)".data(using: .utf8)?.base64EncodedString() ?? UUID().uuidString
            record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: uniqueID))
        }
        
        record[Keys.hostUserRecordID] = hostUserRecordID
        record[Keys.deviceName] = deviceName
        record[Keys.localIP] = localIP
        record[Keys.localPort] = localPort
        record[Keys.publicIP] = publicIP
        record[Keys.publicPort] = publicPort
        record[Keys.isOnline] = isOnline
        record[Keys.lastHeartbeat] = lastHeartbeat
        
        return record
    }
}

// MARK: - CloudKit Signaling Manager

/// CloudKitシグナリングマネージャー
/// サーバーレスでデバイス発見とICE候補交換を実現
actor CloudKitSignalingManager {
    
    static let shared = CloudKitSignalingManager()
    
    // MARK: - Properties
    
    private let containerID = "iCloud.com.myremotehost.shared"
    private var container: CKContainer { CKContainer(identifier: containerID) }
    
    /// ★ ゼロコスト戦略: Private Databaseを使用
    /// - ユーザーのiCloudストレージを使用するため運営コスト$0
    /// - 同じApple IDのデバイス同士は同じPrivate DBにアクセス可能
    /// - 無制限スケール（各ユーザーが自分のストレージを使用）
    private var database: CKDatabase { container.privateCloudDatabase }
    
    /// 登録済みデバイスレコードID
    private var registeredRecordID: CKRecord.ID?
    
    /// ハートビートタスク
    private var heartbeatTask: Task<Void, Never>?
    
    /// ハートビート間隔（秒）
    private let heartbeatInterval: TimeInterval = 30.0
    
    // MARK: - Device Registration (Host側)
    
    /// ホストデバイスをCloudKitに登録
    func registerHost(deviceName: String, localIP: String, localPort: Int) async throws {
        // 1. userRecordIDを取得
        let userRecordID = try await CloudKitManager.shared.fetchUserRecordID()
        
        // 2. 既存レコードを検索
        let existingRecord = try await findExistingHostRecord(userRecordID: userRecordID, deviceName: deviceName)
        
        // 3. レコードを作成または更新
        var hostDevice = HostDeviceRecord(
            hostUserRecordID: userRecordID,
            deviceName: deviceName,
            localIP: localIP,
            localPort: localPort
        )
        
        let record: CKRecord
        if let existing = existingRecord {
            // 既存レコードを更新
            record = existing
            record[HostDeviceRecord.Keys.localIP] = localIP
            record[HostDeviceRecord.Keys.localPort] = localPort
            record[HostDeviceRecord.Keys.isOnline] = true
            record[HostDeviceRecord.Keys.lastHeartbeat] = Date()
        } else {
            // 新規レコードを作成
            record = hostDevice.toCKRecord()
        }
        
        // 4. CloudKitに保存
        let savedRecord = try await database.save(record)
        registeredRecordID = savedRecord.recordID
        
        Logger.cloudkit("✅ ホスト登録成功: \(deviceName) (\(localIP):\(localPort))")
        
        // 5. ハートビート開始
        startHeartbeat()
    }
    
    /// 既存のホストレコードを検索
    /// ★ Private DBでは自分のデータのみ → deviceNameでフィルタ
    private func findExistingHostRecord(userRecordID: String, deviceName: String) async throws -> CKRecord? {
        let predicate = NSPredicate(format: "%K == %@",
                                    HostDeviceRecord.Keys.deviceName, deviceName)
        let query = CKQuery(recordType: HostDeviceRecord.recordType, predicate: predicate)
        
        let (results, _) = try await database.records(matching: query, resultsLimit: 1)
        
        for (_, result) in results {
            if case .success(let record) = result {
                return record
            }
        }
        return nil
    }
    
    /// ホストをオフラインにする
    func unregisterHost() async {
        stopHeartbeat()
        
        guard let recordID = registeredRecordID else { return }
        
        do {
            let record = try await database.record(for: recordID)
            record[HostDeviceRecord.Keys.isOnline] = false
            _ = try await database.save(record)
            Logger.cloudkit("ホストをオフラインに設定")
        } catch {
            Logger.cloudkit("オフライン設定失敗: \(error)", level: .warning)
        }
        
        registeredRecordID = nil
    }
    
    // MARK: - Phase 2: STUN結果の保存
    
    /// 公開IP/ポートをCloudKitに保存（STUN結果）
    func updatePublicEndpoint(publicIP: String, publicPort: Int) async throws {
        guard let recordID = registeredRecordID else {
            Logger.cloudkit("レコード未登録: 公開IP保存スキップ", level: .warning)
            return
        }
        
        let record = try await database.record(for: recordID)
        record[HostDeviceRecord.Keys.publicIP] = publicIP
        record[HostDeviceRecord.Keys.publicPort] = publicPort
        _ = try await database.save(record)
        
        Logger.cloudkit("🌐 公開IP保存完了: \(publicIP):\(publicPort)")
    }
    
    // MARK: - Heartbeat
    
    private func startHeartbeat() {
        stopHeartbeat()
        
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))
                
                guard !Task.isCancelled, let recordID = registeredRecordID else { break }
                
                do {
                    let record = try await database.record(for: recordID)
                    record[HostDeviceRecord.Keys.lastHeartbeat] = Date()
                    record[HostDeviceRecord.Keys.isOnline] = true
                    _ = try await database.save(record)
                    Logger.cloudkit("💓 ハートビート送信", level: .debug)
                } catch {
                    Logger.cloudkit("ハートビート失敗: \(error)", level: .warning)
                }
            }
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
    
    // MARK: - Device Discovery (Client側)
    
    /// 自分のApple IDに紐づくホストデバイス一覧を取得
    /// ★ Private DBでは自分のデータのみアクセス可能
    func discoverMyHosts() async throws -> [HostDeviceRecord] {
        // Private DBでは自分のレコードのみ → オンラインのみでフィルタ
        let predicate = NSPredicate(format: "%K == %@",
                                    HostDeviceRecord.Keys.isOnline, NSNumber(value: true))
        let query = CKQuery(recordType: HostDeviceRecord.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: HostDeviceRecord.Keys.lastHeartbeat, ascending: false)]
        
        let (results, _) = try await database.records(matching: query, resultsLimit: 10)
        
        var hosts: [HostDeviceRecord] = []
        for (_, result) in results {
            if case .success(let record) = result {
                let host = HostDeviceRecord(from: record)
                // 5分以内のハートビートのみ有効とみなす
                if Date().timeIntervalSince(host.lastHeartbeat) < 300 {
                    hosts.append(host)
                }
            }
        }
        
        Logger.cloudkit("🔍 発見したホスト: \(hosts.count)台 (Private DB)")
        return hosts
    }
    
    // MARK: - Utility
    
    /// 現在のローカルIPアドレスを取得
    static func getLocalIPAddress() -> String? {
        var address: String?
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            let interface = ptr?.pointee
            let addrFamily = interface?.ifa_addr.pointee.sa_family
            
            // IPv4のみ
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: (interface?.ifa_name)!)
                // en0 (WiFi) or en1 (Ethernet)
                if name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    if address != nil && !address!.isEmpty {
                        break
                    }
                }
            }
        }
        
        return address
    }
    
    // MARK: - ICE Candidate Exchange
    
    /// ICE候補をCloudKitに保存
    func saveICECandidates(_ candidates: [ICECandidate]) async throws {
        guard let recordID = registeredRecordID else {
            Logger.cloudkit("レコード未登録: ICE候補保存スキップ", level: .warning)
            return
        }
        
        let record = try await database.record(for: recordID)
        
        // ICE候補をJSON形式で保存
        let encoder = JSONEncoder()
        let candidatesData = try encoder.encode(candidates)
        let candidatesJSON = String(data: candidatesData, encoding: .utf8)
        
        record["iceCandidates"] = candidatesJSON
        _ = try await database.save(record)
        
        Logger.cloudkit("📤 ICE候補保存: \(candidates.count)件")
    }
    
    /// 指定ホストのICE候補を取得
    func fetchICECandidates(for host: HostDeviceRecord) async throws -> [ICECandidate] {
        guard let recordID = host.recordID else {
            return []
        }
        
        let record = try await database.record(for: recordID)
        
        guard let candidatesJSON = record["iceCandidates"] as? String,
              let candidatesData = candidatesJSON.data(using: .utf8) else {
            // ICE候補がない場合、ローカル/パブリックIPから候補を生成
            return generateCandidatesFromHostRecord(host)
        }
        
        let decoder = JSONDecoder()
        let candidates = try decoder.decode([ICECandidate].self, from: candidatesData)
        Logger.cloudkit("📥 ICE候補取得: \(candidates.count)件")
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
