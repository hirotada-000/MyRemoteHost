//
//  NetworkSender.swift
//  MyRemoteHost
//
//  UDP経由で映像データを送信するクラス
//  Phase 2: LAN内映像転送用
//
//  アーキテクチャ:
//  - Mac側: UDPリスナーとして待機（ポート5000）、登録パケットを受信
//  - iPhone側: 登録パケットを送信してIP:Portを通知 → Mac側はそのIP:5001に送信
//

import Foundation
import Network

/// 送信状態を通知するデリゲート
protocol NetworkSenderDelegate: AnyObject {
    /// 接続状態が変化
    func networkSender(_ sender: NetworkSender, didChangeState state: NetworkSender.ConnectionState)
    /// エラー発生
    func networkSender(_ sender: NetworkSender, didFailWithError error: Error)
    /// クライアント接続
    func networkSender(_ sender: NetworkSender, didConnectToClient endpoint: String)
    /// クライアント切断
    func networkSender(_ sender: NetworkSender, didDisconnectClient endpoint: String, remainingClients: Int)
    /// 認証リクエスト受信（userRecordIDはApple ID判定用）
    func networkSender(_ sender: NetworkSender, didReceiveAuthRequest host: String, port: UInt16, userRecordID: String?)
    /// ★ Phase 3: キーフレーム要求受信（クライアントからの自動要求）
    func networkSenderDidReceiveKeyFrameRequest(_ sender: NetworkSender)
}

/// クライアント情報
class ClientInfo {
    let host: String
    let port: UInt16
    var connection: NWConnection?
    var lastHeartbeat: Date
    
    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        self.lastHeartbeat = Date()
    }
}

/// UDP映像送信クラス
class NetworkSender {
    
    // MARK: - Types
    
    enum ConnectionState {
        case idle
        case listening
        case ready
        case failed(Error)
        case cancelled
    }
    
    /// パケットタイプ
    enum PacketType: UInt8 {
        case vps = 0x00       // HEVC VPS
        case sps = 0x01
        case pps = 0x02
        case videoFrame = 0x03
        case keyFrame = 0x04

        case fecParity = 0x07  // ★ Phase 2: FECパリティブロック
        case metadata = 0x08   // ★ Phase 4: Retinaメタデータ
        case handshake = 0x09  // ★ Phase 4: ECDHハンドシェイク
        case omniscientState = 0x50 // ★ Phase 2: 全知全能ステート送信
    }
    
    // MARK: - Properties
    
    weak var delegate: NetworkSenderDelegate?
    
    private(set) var state: ConnectionState = .idle {
        didSet {
            DispatchQueue.main.async {
                self.delegate?.networkSender(self, didChangeState: self.state)
            }
        }
    }
    
    /// リスニングポート（登録パケット受信用）
    let port: UInt16
    
    /// 最大パケットサイズ（MTU対応）
    // ★ Phase 2.5: MTU対策で縮小 (1400 -> 1100)
    // IPv6(40)+UDP(8)+TURN(4)+ChannelData(4)=56bytesヘッダ考慮
    // 1100+56=1156 < 1280(IPv6最小MTU)
    private let maxPacketSize = 1100
    
    /// ★ Phase 3: キーフレーム送信最小間隔（クールダウン 2.0秒）
    private let minKeyFrameInterval: TimeInterval = 2.0
    
    /// UDP リスナー（登録受信用）
    private var listener: NWListener?
    
    /// 登録接続（ハートビート受信用）
    private var registrationConnection: NWConnection?
    
    /// 登録済みクライアント
    private var clients: [String: ClientInfo] = [:]
    
    /// ★ R7修正: ハンドシェイク中のconnectionを追跡（二重登録による誤削除防止）
    private var pendingConnections: [String: NWConnection] = [:]
    
    /// 送信キュー
    private let sendQueue = DispatchQueue(label: "com.myremotehost.networksender", qos: .userInteractive)
    
    /// ★ 停止中フラグ（ポート競合防止）
    private var isStopping = false
    
    /// ★ 開始中フラグ（重複開始防止）
    private var isStarting = false
    
    /// ★ Phase 2: FECエンコーダー
    private let fecEncoder = FECEncoder()
    
    /// ★ Phase 2: FEC有効化フラグ
    var fecEnabled: Bool = true
    
    /// ★ Phase 3: 暗号化マネージャー
    let cryptoManager = CryptoManager()
    
    /// ★ Phase 3: 暗号化有効化フラグ
    var encryptionEnabled: Bool = true
    
    // MARK: - ★ A-2: TURNリレーモード
    
    /// TURNクライアント（TURN relay経由送信用）
    var turnClient: TURNClient?
    
    /// TURNモード有効化フラグ
    var isTURNMode: Bool = false
    
    /// TURN送信先のpeerIP（iPhoneのrelayアドレス）
    var turnPeerIP: String = ""
    
    /// TURN送信先のpeerPort（iPhoneのrelayポート）
    var turnPeerPort: UInt16 = 0
    
    /// ★ KF TURN送信中フラグ（KF送信完了までPFを抑制）
    private var isSendingKeyFrameViaTURN: Bool = false
    
    // MARK: - ★ Phase 3: アダプティブ・ペーシング
    
    /// EMA RTT（ミリ秒）
    private var emaRttMs: Double = 2.0
    private let rttAlpha: Double = 0.2
    
    /// RTTを更新（NetworkQualityMonitorから呼び出し）
    func updateRTT(_ rttMs: Double) {
        emaRttMs = emaRttMs * (1.0 - rttAlpha) + rttMs * rttAlpha
    }
    
    /// アダプティブ・バッチサイズ（何パケットごとにウェイトを入れるか）
    var adaptiveBatchSize: Int {
        if emaRttMs <= 2.0  { return 20 }  // LAN内: 攻撃的
        if emaRttMs <= 10.0 { return 15 }  // 近距離Wi-Fi
        if emaRttMs <= 30.0 { return 10 }  // 通常ネットワーク
        return 5                            // WAN: 慎重
    }
    
    /// アダプティブ・ペーシング間隔（マイクロ秒）
    var adaptivePacingUs: UInt32 {
        if emaRttMs <= 2.0  { return 500 }   // LAN: 0.5ms
        if emaRttMs <= 10.0 { return 800 }   // 近距離: 0.8ms
        if emaRttMs <= 30.0 { return 1000 }  // 通常: 1ms
        return 2000                           // WAN: 2ms
    }
    
    // MARK: - ログ頻度制御
    
    /// パラメータセット(VPS/SPS/PPS)ログ済みフラグ
    private var hasLoggedParameterSets = false
    
    /// キーフレーム送信カウンター
    private var keyFrameSendCount = 0
    
    /// 最後にキーフレームを送信した時刻
    private var lastKeyFrameSendTime: Date?
    

    // MARK: - Initialization
    
    init(port: UInt16 = 5100) {
        self.port = port
    }
    
    // MARK: - Public Methods
    
    /// リスナーを開始（クライアント登録を待機）
    func startListening() throws {
        // ★ 重複開始・停止中はスキップ
        guard !isStarting && !isStopping && listener == nil else {
            // print("[NetworkSender] ⚠️ 開始スキップ（既に開始中または停止中）")
            return
        }
        
        isStarting = true
        defer { isStarting = false }
        
        let parameters = NWParameters.tcp  // ★ TCP接続に変更
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        
        listener?.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            
            switch newState {
            case .ready:
                self.state = .listening
                Logger.network("✅ ポート\(self.port)でリスニング開始（登録待機中）")
                
            case .failed(let error):
                self.state = .failed(error)
                Logger.network("❌ リスナー失敗: \(error)", level: .error)
                
            case .cancelled:
                self.state = .cancelled
                // print("[NetworkSender] リスナーキャンセル")
                
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleRegistrationConnection(connection)
        }
        
        listener?.start(queue: sendQueue)
        
        // 定期的に古いクライアントをクリーンアップ
        scheduleClientCleanup()
    }
    
    /// リスナーを停止
    func stop() {
        // ★ 停止中フラグを立てる
        isStopping = true
        
        listener?.cancel()
        listener = nil
        registrationConnection?.cancel()
        registrationConnection = nil
        
        for (_, client) in clients {
            client.connection?.cancel()
        }
        clients.removeAll()
        
        state = .idle
        // print("[NetworkSender] 停止")
        
        // ★ ポート解放のため少し待機
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isStopping = false
        }
    }
    
    /// VPSを送信（HEVCのみ）
    func sendVPS(_ data: Data) {
        if !hasLoggedParameterSets {
            // print("[NetworkSender] HEVC VPS送信: \(data.count)バイト, クライアント数: \(clients.count)")
        }
        sendPacket(type: .vps, data: data, timestamp: 0)
    }
    
    /// SPSを送信
    func sendSPS(_ data: Data) {
        if !hasLoggedParameterSets {
            // print("[NetworkSender] SPS送信: \(data.count)バイト, クライアント数: \(clients.count)")
        }
        sendPacket(type: .sps, data: data, timestamp: 0)
    }
    
    /// PPSを送信
    func sendPPS(_ data: Data) {
        if !hasLoggedParameterSets {
            // print("[NetworkSender] PPS送信: \(data.count)バイト, クライアント数: \(clients.count)")
            hasLoggedParameterSets = true  // PPSが最後なのでここでフラグを立てる
        }
        sendPacket(type: .pps, data: data, timestamp: 0)
    }
    
    /// 映像フレームを送信
    func sendVideoFrame(_ data: Data, isKeyFrame: Bool, timestamp: UInt64) {
        // ★ TURN KF送信中のPF抑制: KF送信完了まで新しいPFを送らない
        // KF（~200ms、164チャンク）送信中にPFを並行送信すると、
        // iPhone側でVideoDecoderがwaitingForKeyFrame状態のためPFが全てスキップされる
        if isTURNMode && !isKeyFrame && isSendingKeyFrameViaTURN {
            // KF送信完了後に自然にエンコーダから新PFが来るので、ここでは静かにスキップ
            return
        }
        
        // ★ Phase 3: キーフレーム送信クールダウン
        // どんなに要求があっても、2秒間は次のKFを送らない（帯域保護）
        if isKeyFrame {
            if let lastTime = lastKeyFrameSendTime, Date().timeIntervalSince(lastTime) < minKeyFrameInterval {
                Logger.network("⏳ KF送信スキップ (クールダウン中)")
                return
            }
            lastKeyFrameSendTime = Date()
            keyFrameSendCount += 1
        }
        
        let type: PacketType = isKeyFrame ? .keyFrame : .videoFrame
        sendPacket(type: type, data: data, timestamp: timestamp)
    }
    
    /// ★ Phase 4: ECDHハンドシェイク（公開鍵）を送信
    func sendHandshake(_ publicKey: Data) {
        Logger.network("🔐 ハンドシェイク送信: \(publicKey.count)バイト")
        sendPacket(type: .handshake, data: publicKey, timestamp: 0)
    }
    
    /// ★ Phase 2: 全知全能ステートを送信
    func sendOmniscientState(_ state: OmniscientState) {
        do {
            let data = try JSONEncoder().encode(state)
            // ステートは頻繁に送るためログは出さない
            sendPacket(type: .omniscientState, data: data, timestamp: 0)
        } catch {
            print("[NetworkSender] ⚠️ OmniscientStateエンコード失敗: \(error)")
        }
    }
    
    // ★ 動画一本化: sendPNGFrame / sendPacketWithStrongPacingSync / reconnectFailedClients は廃止
    
    
    /// 接続クライアント数
    var clientCount: Int {
        clients.count
    }
    
    /// ★ 送信可能なクライアントが存在するか
    var hasReadyClients: Bool {
        clients.values.contains { $0.connection?.state == .ready }
    }
    
    // MARK: - Private Methods
    
    private func handleRegistrationConnection(_ connection: NWConnection) {
        Logger.network("🔔 新規接続受信")  // ★ デバッグログ
        registrationConnection?.cancel()
        registrationConnection = connection
        
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                Logger.network("🔔 接続Ready - 登録待機")  // ★ デバッグログ
                self?.receiveRegistration(on: connection)
            case .failed:
                break // 登録接続失敗
            case .cancelled:
                break // 登録接続キャンセル
            default:
                break
            }
        }
        
        connection.start(queue: sendQueue)
    }
    
    private func receiveRegistration(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = content, data.count >= 1 {
                // 切断パケット: [0xFF]
                if data[0] == 0xFF {
                    Logger.network("🔔 切断パケット受信")  // ★ デバッグログ
                    // 接続元IPを取得してクライアントを削除
                    if case .hostPort(let host, _) = connection.endpoint {
                        let hostString = self.extractHostString(from: host)
                        self.unregisterClient(host: hostString)
                    }
                }
                // ★ Phase 3: キーフレーム要求パケット: [0xFC]
                else if data[0] == 0xFC {
                    Logger.pipeline("★ キーフレーム要求受信")
                    DispatchQueue.main.async {
                        self.delegate?.networkSenderDidReceiveKeyFrameRequest(self)
                    }
                }
                // 登録パケット: [0xFE] [2バイト: ポート] [userRecordID(UTF-8)]
                else if data[0] == 0xFE && data.count >= 3 {
                    Logger.network("🔔 登録パケット受信: \(data.count)バイト", sampling: .oncePerSession)  // 初回のみ
                    let clientPort = UInt16(bigEndian: data.subdata(in: 1..<3).withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
                    })
                    
                    // ★ Phase 3: userRecordIDを抽出（3バイト以降）
                    var userRecordID: String? = nil
                    if data.count > 3 {
                        userRecordID = String(data: data.subdata(in: 3..<data.count), encoding: .utf8)
                    }
                    
                    // 接続元IPを取得
                    if case .hostPort(let host, _) = connection.endpoint {
                        let hostString = self.extractHostString(from: host)
                        self.registerClient(host: hostString, port: clientPort, userRecordID: userRecordID)
                    }
                }
            }
            
            // 次の登録/ハートビートを待機
            if !isComplete {
                self.receiveRegistration(on: connection)
            }
        }
    }
    
    /// クライアント登録リクエストを処理（認証フロー）
    private func registerClient(host: String, port: UInt16, userRecordID: String?) {
        let key = "\(host):\(port)"
        
        if let existing = clients[key] {
            // 既存クライアント → ハートビート更新
            existing.lastHeartbeat = Date()
            return
        }
        
        // 新規クライアント → 認証リクエストをデリゲートに通知
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.networkSender(self, didReceiveAuthRequest: host, port: port, userRecordID: userRecordID)
        }
        Logger.network("🔔 認証リクエスト: \(key)")
    }
    
    /// ★ InputReceiver経由で登録を受信（外部から呼び出し用）
    func registerClientFromInput(host: String, port: UInt16, userRecordID: String?) {
        Logger.network("🔔 InputReceiver経由登録: \(host):\(port)")
        registerClient(host: host, port: port, userRecordID: userRecordID)
    }
    
    /// クライアント接続を許可
    func approveClient(host: String, port: UInt16) {
        let key = "\(host):\(port)"
        
        // 既に登録済みの場合はスキップ
        if clients[key] != nil {
            Logger.network("⚠️ クライアント既に登録済み: \(key) - approveスキップ")
            return
        }
        
        // ★ R7修正: ハンドシェイク中の場合、古い接続をキャンセルして新しい接続で上書き
        if let existingPending = pendingConnections[key] {
            Logger.network("⚠️ 二重登録検出: \(key) - 古いハンドシェイク接続をキャンセル")
            existingPending.cancel()
            pendingConnections.removeValue(forKey: key)
        }
        
        // クライアント接続を確立
        let clientInfo = ClientInfo(host: host, port: port)
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        let connection = NWConnection(to: endpoint, using: .udp)
        
        // ★ R7修正: pendingConnectionsにこの接続を追跡
        pendingConnections[key] = connection
        
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                Logger.network("🟡 UDP接続確立 - ハンドシェイク開始: \(key)")
                
                // ★ ECDHハンドシェイク開始
                if let sender = self {
                    let handshakePayload = sender.cryptoManager.generateECDHHandshakePacket()
                    sender.sendHandshake(handshakePayload, to: connection)
                    
                    // Clientからのハンドシェイクを待機し、完了したら登録を行う
                    sender.receiveHandshakeAndCompleteConnection(connection, clientInfo: clientInfo, key: key)
                }
                
            case .failed(let error):
                Logger.network("❌ クライアント接続失敗: \(key) - \(error)", level: .error)
                self?.pendingConnections.removeValue(forKey: key)
                clientInfo.connection?.cancel()
            case .cancelled:
                // ★ R7修正: 現在のconnectionが登録済みクライアントのものと一致する場合のみ削除
                // 二重登録時に古い接続のキャンセルが新しい正常な登録を誤削除するのを防止
                if let currentClient = self?.clients[key], currentClient.connection === connection {
                    self?.clients.removeValue(forKey: key)
                    Logger.network("🔌 クライアント切断(cancelled): \(key)")
                } else {
                    Logger.network("⚠️ 古い接続のキャンセル検出: \(key) - クライアント保持")
                }
                self?.pendingConnections.removeValue(forKey: key)
            default:
                break
            }
        }
        
        clientInfo.connection = connection
        connection.start(queue: sendQueue)
    }
    
    /// ★ Phase 4: ハンドシェイク受信待機と接続完了処理
    private func receiveHandshakeAndCompleteConnection(_ connection: NWConnection, clientInfo: ClientInfo, key: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                Logger.network("❌ ハンドシェイク受信エラー: \(error)", level: .error)
                return
            }
            
            if let data = content, data.count > 17 {
                let typeByte = data[0]
                // ハンドシェイクパケット (0x09) かつ ヘッダー(17) + 鍵(32) = 49バイト以上
                if typeByte == 0x09 {
                    let keyData = data.subdata(in: 17..<data.count)
                    do {
                        Logger.network("🔐 ハンドシェイク受信(Client->Server): \(keyData.count) bytes")
                        try self.cryptoManager.processECDHHandshake(keyData)
                        Logger.network("✅ E2E暗号化接続 確立完了 (Server)")
                        
                        // ★ ハンドシェイク成功！ここで初めてクライアント登録とデリゲート通知を行う
                        DispatchQueue.main.async {
                            self.completeClientRegistration(clientInfo: clientInfo, key: key, connection: connection)
                        }
                        
                        // 以降は通常の受信ループへ（もしあれば）
                        // self.receiveFromClient(connection) 
                        // 現状UDP受信はハンドシェイク以外想定していないが、将来のために閉じておくかループするか？
                        // とりあえず終了。
                        return
                        
                    } catch {
                        Logger.network("❌ ハンドシェイク処理失敗: \(error)", level: .error)
                        connection.cancel()
                        return
                    }
                }
            }
            
            // まだハンドシェイクが来ていない、または不完全な場合
            if !isComplete {
                self.receiveHandshakeAndCompleteConnection(connection, clientInfo: clientInfo, key: key)
            }
        }
    }
    
    /// ★ Phase 4: クライアント登録完了処理
    private func completeClientRegistration(clientInfo: ClientInfo, key: String, connection: NWConnection) {
        // ★ R7修正: pendingからclientsへ昇格
        self.pendingConnections.removeValue(forKey: key)
        self.clients[key] = clientInfo
        self.state = .ready
        
        Logger.network("✅ クライアント正式登録: \(key) (connState: \(connection.state), clients: \(self.clients.count))")
        
        // デリゲート呼び出し
        self.delegate?.networkSender(self, didConnectToClient: key)
        
        // 認証成功通知 (TCP) — registrationConnection経由で送信
        // ★ クライアントはTCP serverConnectionで0xAAを待機しているため、
        //    UDP connectionではなくTCP registrationConnectionに送信する必要がある
        if let tcpConnection = self.registrationConnection {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.sendAuthResult(approved: true, to: tcpConnection)
                Logger.network("📤 認証成功通知送信 (TCP)")
            }
        } else {
            Logger.network("⚠️ TCP registrationConnectionが無い - 認証通知送信不可", level: .error)
        }
    }
    
    /// ★ Phase 4: 特定の接続にハンドシェイク送信
    private func sendHandshake(_ payload: Data, to connection: NWConnection) {
        Logger.network("🔐 ハンドシェイク送信(Server->Client): \(payload.count)バイト")
        
        // ヘッダー作成 (タイプ + タイムスタンプ + 総数 + 番号)
        var packet = Data()
        packet.append(PacketType.handshake.rawValue)
        var ts: UInt64 = 0
        packet.append(Data(bytes: &ts, count: 8))
        var total: UInt32 = 1
        packet.append(contentsOf: Data(bytes: &total, count: 4).reversed()) // bigEndian
        var index: UInt32 = 0
        packet.append(contentsOf: Data(bytes: &index, count: 4).reversed()) // bigEndian
        
        packet.append(payload) // 既に 0xEC 付き
        
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }
    

    
    /// クライアント接続を拒否
    func denyClient(host: String, port: UInt16) {
        let key = "\(host):\(port)"
        // print("[NetworkSender] ❌ クライアント認証拒否: \(key)")
        
        // 拒否通知を送信するための一時的な接続を作成
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { [weak self] newState in
            if case .ready = newState {
                self?.sendAuthResult(approved: false, to: connection)
                // 送信後に接続を閉じる
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    connection.cancel()
                }
            }
        }
        connection.start(queue: sendQueue)
    }
    
    /// 認証結果をクライアントに送信
    private func sendAuthResult(approved: Bool, to connection: NWConnection) {
        // 認証結果パケット: [0xAA] [結果: 0x01=許可, 0x00=拒否]
        var packet = Data([0xAA, approved ? 0x01 : 0x00])
        connection.send(content: packet, completion: .idempotent)
    }
    
    private func scheduleClientCleanup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, case .listening = self.state else { return }
            self.cleanupStaleClients()
            self.scheduleClientCleanup()
        }
    }
    
    private func cleanupStaleClients() {
        let timeout: TimeInterval = 10.0 // 10秒タイムアウト
        let now = Date()
        
        var timedOutClients: [String] = []
        
        for (key, client) in clients {
            if now.timeIntervalSince(client.lastHeartbeat) > timeout {
                client.connection?.cancel()
                clients.removeValue(forKey: key)
                timedOutClients.append(key)
                // print("[NetworkSender] クライアントタイムアウト: \(key)")
            }
        }
        
        // タイムアウトしたクライアントをデリゲートに通知
        if !timedOutClients.isEmpty {
            let remainingClients = self.clients.count
            DispatchQueue.main.async {
                for key in timedOutClients {
                    self.delegate?.networkSender(self, didDisconnectClient: key, remainingClients: remainingClients)
                }
            }
        }
        
        if clients.isEmpty {
            if case .ready = state {
                state = .listening
            }
        }
    }
    
    private func extractHostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr):
            return "\(addr)"
        case .ipv6(let addr):
            return "\(addr)"
        case .name(let name, _):
            return name
        @unknown default:
            return "unknown"
        }
    }
    
    private func unregisterClient(host: String) {
        // ホストに対応するクライアントを検索して削除
        for (key, client) in clients {
            if key.hasPrefix(host) {
                client.connection?.cancel()
                clients.removeValue(forKey: key)
                // print("[NetworkSender] クライアント切断: \(key)")
                
                // デリゲートに切断を通知
                let remainingClients = self.clients.count
                DispatchQueue.main.async {
                    self.delegate?.networkSender(self, didDisconnectClient: key, remainingClients: remainingClients)
                    
                    // クライアント数が0になったら状態を更新
                    if self.clients.isEmpty {
                        if case .ready = self.state {
                            self.state = .listening
                        }
                    }
                }
                return
            }
        }
    }
    
    private func sendPacket(type: PacketType, data: Data, timestamp: UInt64) {
        // メインスレッドをブロックしないよう、送信キューで実行
        sendQueue.async { [weak self] in
            guard let self = self else { return }
            
            // ★ A-2修正: TURNモード時はクライアントリスト不要（relay経由で送信）
            guard self.isTURNMode || !self.clients.isEmpty else {
                // ★ 診断ログ: クライアントがいない場合
                if type == .keyFrame || type == .vps || type == .sps || type == .pps {
                    Logger.network("⚠️ sendPacketスキップ: クライアントなし type=\(type)", level: .warning)
                }
                return
            }
            
            // パケットヘッダー作成
            // [1バイト: タイプ] [8バイト: タイムスタンプ] [4バイト: 総パケット数] [4バイト: パケット番号] [データ]
            
            // ★ Phase 4: 暗号化 (ハンドシェイク以外)
            var payload = data
            if type != .handshake {
                // debugLogPacket(data, label: "Plain")
                guard let encrypted = self.cryptoManager.encryptIfEnabled(data) else {
                    print("[NetworkSender] ⚠️ 暗号化失敗のためパケット送信をスキップ")
                    return
                }
                payload = encrypted
                // debugLogPacket(payload, label: "Encrypted")
                
                // 暗号化によりサイズが増加するため、ログ出力（デバッグ用）
                // if payload.count != data.count { print("🔒 Encrypted: \(data.count) -> \(payload.count) bytes") }
            }
            
            let headerSize = 1 + 8 + 4 + 4
            let maxDataPerPacket = self.maxPacketSize - headerSize
            
            // データを分割
            let totalPackets = (payload.count + maxDataPerPacket - 1) / maxDataPerPacket
            
            // ★ TURN送信: 全チャンクを先に構築してから1つのTaskで順次送信
            //   個別Task作成だとキーフレーム(複数チャンク)の途中にP-frame Taskが挟まり、
            //   iPhone側でキーフレーム再構築が失敗する
            var turnPackets: [Data] = []
            
            for i in 0..<totalPackets {
                // ★ Phase 3: アダプティブ・ペーシング（RTTベース）
                // TURN経由ではペーシング不要（actorが逐次送信するため）
                if !self.isTURNMode {
                    let batchSize = self.adaptiveBatchSize
                    if i > 0 && i % batchSize == 0 {
                        usleep(self.adaptivePacingUs)
                    }
                }
                
                let start = i * maxDataPerPacket
                let end = min(start + maxDataPerPacket, payload.count)
                let chunk = payload[start..<end]
                
                var packet = Data()
                
                // タイプ（1バイト）
                packet.append(type.rawValue)
                
                // タイムスタンプ（8バイト、ビッグエンディアン）
                var ts = timestamp.bigEndian
                packet.append(Data(bytes: &ts, count: 8))
                
                // 総パケット数（4バイト）
                var total = UInt32(totalPackets).bigEndian
                packet.append(Data(bytes: &total, count: 4))
                
                // パケット番号（4バイト）
                var index = UInt32(i).bigEndian
                packet.append(Data(bytes: &index, count: 4))
                
                // データ
                packet.append(chunk)
                
                // ★ TURN/通常の分岐
                if self.isTURNMode {
                    turnPackets.append(packet)
                } else {
                    // 通常: 全クライアントに直接UDP送信（.ready状態のみ）
                    for (key, client) in self.clients {
                        guard let connection = client.connection else {
                            continue
                        }
                        
                        // ★ 接続状態を確認
                        // .ready 以外では送信しない
                        if connection.state != .ready {
                            continue
                        }
                        
                        connection.send(content: packet, completion: .contentProcessed { error in
                            if let error = error {
                                Logger.network("❌ UDP送信エラー: \(key) - \(error)", level: .error)
                            }
                        })
                    }
                }
            }
            
            // ★ TURN送信: 1つのTaskで全チャンクを順次送信（順序保証）
            if self.isTURNMode, !turnPackets.isEmpty, let turnClient = self.turnClient {
                let peerIP = self.turnPeerIP
                let peerPort = self.turnPeerPort
                let packetType = type
                let packetCount = turnPackets.count
                let totalBytes = turnPackets.reduce(0) { $0 + $1.count }
                
                // ★ Phase 0 診断: 送信開始ログ（KF/PF両方）
                if packetType == .keyFrame {
                    Logger.network("📤 TURN KF送信開始: \(packetCount)チャンク, \(totalBytes)バイト")
                    self.isSendingKeyFrameViaTURN = true  // ★ KF送信中フラグON
                } else {
                    Logger.network("📤 TURN PF送信: \(packetCount)チャンク, \(totalBytes)バイト [type=\(packetType)]")
                }
                
                Task {
                    let startTime = CFAbsoluteTimeGetCurrent()
                    do {
                        for (idx, pkt) in turnPackets.enumerated() {
                            try await turnClient.sendData(pkt, to: peerIP, peerPort: peerPort)
                            
                            // ★ 最適化 1-C: 適応型ペーシング（PF/KF分離）
                            // PF（1-5チャンク）: ペーシング不要 → 即時送信で遅延最小化
                            // KF（100-200チャンク）: 4チャンク毎0.5ms → 旧(2毎×1ms=80ms)比60%短縮
                            if packetType == .keyFrame && idx > 0 && idx % 4 == 0 {
                                try? await Task.sleep(nanoseconds: 500_000) // 0.5ms（KFのみ）
                            }
                            // PF: ペーシングなし（即時全チャンク送信）
                        }
                        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        // ★ KF送信完了 → PF抑制解除
                        if packetType == .keyFrame {
                            self.isSendingKeyFrameViaTURN = false  // ★ KF送信中フラグOFF
                            Logger.network("✅ TURN KF送信完了: \(packetCount)チャンク, \(totalBytes)バイト, \(String(format: "%.1f", elapsed))ms → PF抑制解除")
                        } else {
                            Logger.network("✅ TURN PF送信完了: \(packetCount)チャンク, \(String(format: "%.1f", elapsed))ms")
                        }
                    } catch {
                        Logger.network("❌ TURN送信エラー (\(packetType)): \(error)", level: .error)
                    }
                }
            }
        }
    }
    
    // MARK: - Debug
    
    /// ★ 暗号化検証用パケットダンプ
    private func debugLogPacket(_ data: Data, label: String) {
        // 最初の32バイトだけ表示
        let count = min(data.count, 32)
        let subdata = data.subdata(in: 0..<count)
        let hex = subdata.map { String(format: "%02X", $0) }.joined(separator: " ")
        // Logger.network("🔍 [PacketDump] \(label): \(hex) ...Total:\(data.count)")
    }
}
