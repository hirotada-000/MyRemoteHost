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
    }
    
    /// パケットタイプ
    enum PacketType: UInt8 {
        case vps = 0x00       // HEVC VPS
        case sps = 0x01
        case pps = 0x02
        case videoFrame = 0x03
        case keyFrame = 0x04
        case jpegFrame = 0x05  // Deprecated (JPEG)
        case pngFrame = 0x06   // ★ PNG 静止画フレーム
        case fecParity = 0x07  // ★ Phase 2: FECパリティブロック
        case metadata = 0x08   // ★ Phase 4: Retinaメタデータ
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
    private let maxPacketSize = 1400
    
    /// UDP リスナー（登録受信用）
    private var listener: NWListener?
    
    /// 登録接続（ハートビート受信用）
    private var registrationConnection: NWConnection?
    
    /// 登録済みクライアント
    private var clients: [String: ClientInfo] = [:]
    
    /// 送信キュー
    private let sendQueue = DispatchQueue(label: "com.myremotehost.networksender", qos: .userInteractive)
    
    /// ★ 停止中フラグ（ポート競合防止）
    private var isStopping = false
    
    /// ★ 開始中フラグ（重複開始防止）
    private var isStarting = false
    
    /// ★ Phase 2: FECエンコーダー
    private let fecEncoder = FECEncoder()
    
    /// ★ Phase 2: FEC有効化フラグ
    var fecEnabled: Bool = false  // ★ 一時無効化: デバッグ用
    
    /// ★ Phase 3: 暗号化マネージャー
    let cryptoManager = CryptoManager()
    
    /// ★ Phase 3: 暗号化有効化フラグ
    var encryptionEnabled: Bool = false  // ★ 一時無効化: 鍵交換未実装のため
    
    // MARK: - ログ頻度制御
    
    /// パラメータセット(VPS/SPS/PPS)ログ済みフラグ
    private var hasLoggedParameterSets = false
    
    /// キーフレーム送信カウンター
    private var keyFrameSendCount = 0
    
    /// PNG送信カウンター
    private var pngSendCount = 0
    
    /// ★ PNG送信中フラグ（動画フレーム送信を一時停止）
    private var _isPNGSending = false
    
    /// ★ PNG送信排他制御用ロック
    private let pngSendingLock = NSLock()
    
    /// ★ PNG送信中かどうか（スレッドセーフ）
    var isPNGSending: Bool {
        pngSendingLock.lock()
        defer { pngSendingLock.unlock() }
        return _isPNGSending
    }
    
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
                self.state = .idle
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
        // ★ PNG送信中は動画フレームをスキップ（ソケット負荷軽減）
        if isPNGSending {
            return
        }
        
        let type: PacketType = isKeyFrame ? .keyFrame : .videoFrame
        if isKeyFrame {
            keyFrameSendCount += 1
            if keyFrameSendCount == 1 || keyFrameSendCount % 100 == 0 {
                // print("[NetworkSender] キーフレーム送信: \(data.count)バイト (累計\(keyFrameSendCount)回)")
            }
        }
        sendPacket(type: type, data: data, timestamp: timestamp)
    }
    
    /// ★ PNG 静止画フレームを送信（強化ペーシング・排他制御付き）
    func sendPNGFrame(_ data: Data) {
        // ★ スレッドセーフに送信中フラグをチェック・セット
        pngSendingLock.lock()
        if _isPNGSending {
            pngSendingLock.unlock()
            // print("[NetworkSender] ⚠️ PNG送信中のため新規送信スキップ")
            return
        }
        _isPNGSending = true
        pngSendingLock.unlock()
        
        // ★ PNG送信前に100ms待機（エンコーダ再構成直後の接続安定化）
        sendQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.sendPacketWithStrongPacingSync(type: .pngFrame, data: data, timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
            
            // ★ PNG送信完了 → フラグ解除（スレッドセーフ）
            self.pngSendingLock.lock()
            self._isPNGSending = false
            self.pngSendingLock.unlock()
            
            // print("[NetworkSender] ✅ PNG送信完了: \(self.pngSendCount)回目")
            
            // ★ PNG送信完了後に接続状態を確認し、必要なら再確立
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.reconnectFailedClients()
            }
        }
    }
    
    /// ★ 接続がfailed状態のクライアントを再接続
    private func reconnectFailedClients() {
        sendQueue.async { [weak self] in
            guard let self = self else { return }
            
            for (key, client) in self.clients {
                guard let connection = client.connection else { continue }
                
                // ★ failed状態の接続を検出
                if case .failed = connection.state {
                    // print("[NetworkSender] 🔄 接続再確立開始: \(key)")
                    
                    // 古い接続をキャンセル
                    connection.cancel()
                    
                    // 新しい接続を作成
                    let endpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(client.host),
                        port: NWEndpoint.Port(rawValue: client.port)!
                    )
                    
                    let newConnection = NWConnection(to: endpoint, using: .udp)
                    newConnection.stateUpdateHandler = { [weak self] newState in
                        switch newState {
                        case .ready:
                            break // 接続再確立成功
                        case .failed:
                            break // 接続再確立失敗
                        default:
                            break
                        }
                    }
                    
                    client.connection = newConnection
                    newConnection.start(queue: self.sendQueue)
                }
            }
        }
    }
    
    /// ★ 強化ペーシングでパケット送信（PNG等の大きなフレーム用）- 同期版
    private func sendPacketWithStrongPacingSync(type: PacketType, data: Data, timestamp: UInt64) {
        // 既にsendQueue上で実行されている前提
        guard !self.clients.isEmpty else { return }
        
        let headerSize = 1 + 8 + 4 + 4
        let maxDataPerPacket = self.maxPacketSize - headerSize
        let totalPackets = (data.count + maxDataPerPacket - 1) / maxDataPerPacket
        
        self.pngSendCount += 1
        if self.pngSendCount == 1 || self.pngSendCount % 100 == 0 {
            // print("[NetworkSender] 📤 PNG送信開始: \(data.count)バイト → \(totalPackets)パケット (累計\(self.pngSendCount)回)")
        }
        
        // ★ 送信エラーカウント（ログ抑制用）
        var errorCount = 0
        
        for i in 0..<totalPackets {
            // ★★ 超・超強化ペーシング: 3パケットごとに50msウェイト（接続保護最優先）
            if i > 0 && i % 3 == 0 {
                usleep(50000)  // 50ms
            }
            
            let start = i * maxDataPerPacket
            let end = min(start + maxDataPerPacket, data.count)
            let chunk = data[start..<end]
            
            var packet = Data()
            packet.append(type.rawValue)
            
            var ts = timestamp.bigEndian
            packet.append(Data(bytes: &ts, count: 8))
            
            var total = UInt32(totalPackets).bigEndian
            packet.append(Data(bytes: &total, count: 4))
            
            var index = UInt32(i).bigEndian
            packet.append(Data(bytes: &index, count: 4))
            
            packet.append(chunk)
            
            for (key, client) in self.clients {
                guard let connection = client.connection else { continue }
                
                // ★ 接続状態を確認
                // .ready 以外（failed, waiting, cancelled）では送信しないことでシステムログを抑制
                if connection.state != .ready {
                    // failedの場合は再接続を試みる（非同期）
                    if case .failed = connection.state {
                        DispatchQueue.global().async {
                           self.reconnectFailedClients()
                        }
                    }
                    continue
                }
                
                connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        errorCount += 1
                        // ★ エラーログは最初の1回のみ
                        if errorCount == 1 {
                             // print("[NetworkSender] ⚠️ PNG送信エラー: \(error.localizedDescription)")
                             // エラー発生時は再接続を試みる
                             self?.reconnectFailedClients()
                        }
                    }
                })
            }
        }
        
        if self.pngSendCount == 1 || self.pngSendCount % 100 == 0 {
            // print("[NetworkSender] ✅ PNG送信完了: \(totalPackets)パケット (累計\(self.pngSendCount)回)")
        }
        
        // ★ エラーがあった場合のサマリーログ
        if errorCount > 0 {
            // print("[NetworkSender] ⚠️ PNG送信中のエラー: \(errorCount)件")
        }
    }
    
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
                // 登録パケット: [0xFE] [2バイト: ポート] [userRecordID(UTF-8)]
                else if data[0] == 0xFE && data.count >= 3 {
                    Logger.network("🔔 登録パケット受信: \(data.count)バイト")  // ★ デバッグログ
                    let clientPort = UInt16(bigEndian: data.subdata(in: 1..<3).withUnsafeBytes {
                        $0.load(as: UInt16.self)
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
            // print("[NetworkSender] クライアント既に登録済み: \(key)")
            return
        }
        
        // クライアント接続を確立
        let clientInfo = ClientInfo(host: host, port: port)
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        let connection = NWConnection(to: endpoint, using: .udp)
        
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                self?.clients[key] = clientInfo
                self?.state = .ready
                
                // print("[NetworkSender] ✅ クライアント認証許可: \(key)")
                
                // ★ Phase 3: 暗号化鍵を生成（初回接続時のみ）
                if let sender = self, !sender.cryptoManager.hasKey {
                    sender.cryptoManager.generateKey()
                    // print("[NetworkSender] 🔐 暗号化鍵生成完了（AES-256）")
                }
                
                // ★ 重要: デリゲート呼び出し→オンデマンドキャプチャ開始→SPS/PPS生成 を待ってから認証成功通知
                DispatchQueue.main.async {
                    self?.delegate?.networkSender(self!, didConnectToClient: key)
                    
                    // ★ オンデマンドキャプチャ開始とSPS/PPS生成を待つ時間を確保
                    // didConnectToClient内でstartCapture()が呼ばれ、SPS/PPSが生成される
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // 認証成功をクライアントに通知（オンデマンドキャプチャ開始後）
                        self?.sendAuthResult(approved: true, to: connection)
                        // print("[NetworkSender] 📤 認証成功通知送信: \(key)")
                    }
                }
                
            case .failed(let error):
                // print("[NetworkSender] クライアント接続失敗: \(key) - \(error)")
                clientInfo.connection?.cancel()
            case .cancelled:
                self?.clients.removeValue(forKey: key)
                // print("[NetworkSender] クライアント接続キャンセル: \(key)")
            default:
                break
            }
        }
        
        clientInfo.connection = connection
        connection.start(queue: sendQueue)
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
            guard let self = self, !self.clients.isEmpty else { return }
            
            // パケットヘッダー作成
            // [1バイト: タイプ] [8バイト: タイムスタンプ] [4バイト: 総パケット数] [4バイト: パケット番号] [データ]
            let headerSize = 1 + 8 + 4 + 4
            let maxDataPerPacket = self.maxPacketSize - headerSize
            
            // データを分割
            let totalPackets = (data.count + maxDataPerPacket - 1) / maxDataPerPacket
            
            for i in 0..<totalPackets {
                // ★ UDPバースト制御 (Pacing)
                // 10パケットごとに 1ms のウェイトを入れ、ルーターやOSバッファの溢れを防ぐ
                // 特に巨大なPNG転送時に必須
                if i > 0 && i % 10 == 0 {
                    usleep(1000)
                }
                
                let start = i * maxDataPerPacket
                let end = min(start + maxDataPerPacket, data.count)
                let chunk = data[start..<end]
                
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
                
                // 全クライアントに送信（.ready状態のみ）
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
                        // ★ エラー時もクライアントを即座に削除しない
                        // ハートビートタイムアウトで自然にクリーンアップされる
                        // 一時的なエラーからの復帰を可能にする
                    })
                }
            }
        }
    }
}
