//
//  NetworkReceiver.swift
//  MyRemoteHost iphone
//
//  UDP経由で映像データを受信するクラス
//  Phase 2: LAN内映像転送用（iOS側）
//  
//  アーキテクチャ:
//  - iPhone側: UDPリスナーとして待機（ポート5001）
//  - Mac側: iPhoneのIP:5001に直接送信
//

import Foundation
import Network

/// 受信データを通知するデリゲート
protocol NetworkReceiverDelegate: AnyObject {
    /// VPSを受信（HEVCのみ）
    func networkReceiver(_ receiver: NetworkReceiver, didReceiveVPS data: Data)
    /// SPSを受信
    func networkReceiver(_ receiver: NetworkReceiver, didReceiveSPS data: Data)
    /// PPSを受信
    func networkReceiver(_ receiver: NetworkReceiver, didReceivePPS data: Data)
    /// 映像フレームを受信
    func networkReceiver(_ receiver: NetworkReceiver, didReceiveVideoFrame data: Data, isKeyFrame: Bool, timestamp: UInt64)
    /// 接続状態が変化
    func networkReceiver(_ receiver: NetworkReceiver, didChangeState state: NetworkReceiver.ConnectionState)
    /// エラー発生
    func networkReceiver(_ receiver: NetworkReceiver, didFailWithError error: Error)
    /// 認証結果を受信
    func networkReceiver(_ receiver: NetworkReceiver, didReceiveAuthResult approved: Bool)
    
    /// ★ PNG 静止画フレームを受信
    func networkReceiver(_ receiver: NetworkReceiver, didReceivePNG data: Data)
}

/// UDP映像受信クラス（リスナーモード）
class NetworkReceiver {
    
    // MARK: - Types
    
    enum ConnectionState {
        case disconnected
        case connecting
        case listening
        case receiving
        case failed(Error)
    }
    
    /// パケットタイプ（送信側と同じ）
    enum PacketType: UInt8 {
        case vps = 0x00       // HEVC VPS
        case sps = 0x01
        case pps = 0x02
        case videoFrame = 0x03
        case keyFrame = 0x04
        case jpegFrame = 0x05  // Deprecated
        case pngFrame = 0x06   // ★ PNG フレーム
        case fecParity = 0x07  // ★ Phase 2: FECパリティ
        case metadata = 0x08   // ★ Phase 4: メタデータ
    }
    
    // MARK: - Properties
    
    weak var delegate: NetworkReceiverDelegate?
    
    /// リスニングポート
    let listenPort: UInt16
    
    private(set) var state: ConnectionState = .disconnected {
        didSet {
            DispatchQueue.main.async {
                self.delegate?.networkReceiver(self, didChangeState: self.state)
            }
        }
    }
    
    /// UDP リスナー
    private var listener: NWListener?
    
    /// 受信した接続（複数のソースからの接続を保持）
    private var connections: [String: NWConnection] = [:]
    
    /// サーバーへの通知用接続
    private var serverConnection: NWConnection?
    
    /// 受信キュー
    private let receiveQueue = DispatchQueue(label: "com.myremoteclient.networkreceiver", qos: .userInteractive)
    
    /// パケット再構築用バッファ
    private var packetBuffer: [UInt64: PacketAssembler] = [:]
    
    /// ★ 最新フレームID（パケットロス無視戦略用）
    private var latestFrameId: UInt64 = 0
    
    /// ★ フレームタイムアウト（ms）- この時間内に揃わなければスキップ
    /// PNG画像(数MB・1600+パケット)の転送時間を考慮して大幅に延長
    private let frameTimeoutMs: UInt64 = 5000  // ★ 5秒（超強化ペーシング対応）
    
    /// ★ フレーム開始時刻（タイムアウト用）
    private var frameStartTimes: [UInt64: UInt64] = [:]
    
    /// ★ スキップされたフレーム数（デバッグ用）
    private var skippedFrameCount: Int = 0
    
    /// ★ Phase 3: userRecordIDキャッシュ（Apple ID認証用）
    private(set) var cachedUserRecordID: String?  // ★ 外部から読み取り可能に
    
    /// ★ Phase 2: FECデコーダー
    private let fecDecoder = FECDecoder()
    
    /// ★ Phase 2: FEC有効化フラグ
    var fecEnabled: Bool = false  // ★ 一時無効化: デバッグ用
    
    /// ★ Phase 3: 暗号化マネージャー
    let cryptoManager = CryptoManager()
    
    /// ★ Phase 3: 暗号化有効化フラグ
    var encryptionEnabled: Bool = false  // ★ 一時無効化: 鍵交換未実装のため
    
    // MARK: - ログ頻度制御
    
    /// パラメータセット(VPS/SPS/PPS)ログ済みフラグ
    private var hasLoggedParameterSets = false
    
    /// キーフレーム受信カウンター
    private var keyFrameReceiveCount = 0
    
    /// PNG受信カウンター
    private var pngReceiveCount = 0
    
    /// メタデータ受信カウンター
    private var metadataReceiveCount = 0
    
    /// 旧JPEGログ済みフラグ
    private var hasLoggedOldJpeg = false
    
    // MARK: - Packet Assembler
    
    private class PacketAssembler {
        let totalPackets: Int
        let packetType: PacketType  // ★ フレームタイプを保存
        var receivedPackets: [Int: Data] = [:]
        var isComplete: Bool {
            receivedPackets.count == totalPackets
        }
        var receivedCount: Int {
            receivedPackets.count
        }
        
        init(totalPackets: Int, packetType: PacketType) {
            self.totalPackets = totalPackets
            self.packetType = packetType
        }
        
        func addPacket(index: Int, data: Data) {
            receivedPackets[index] = data
        }
        
        func assemble() -> Data? {
            guard isComplete else { return nil }
            var result = Data()
            for i in 0..<totalPackets {
                if let chunk = receivedPackets[i] {
                    result.append(chunk)
                }
            }
            return result
        }
    }
    
    // MARK: - Initialization
    
    init(listenPort: UInt16 = 5001) {
        self.listenPort = listenPort
    }
    
    // MARK: - Public Methods
    
    /// サーバーに接続して受信準備
    /// iPhone側はリスナーとして待機し、サーバーにIPとポートを通知
    func connect(to host: String, port: UInt16) {
        // 既に接続中または接続処理中なら無視
        switch state {
        case .connecting, .listening, .receiving:
            // print("[NetworkReceiver] ⚠️ 既に接続中または接続処理中 - 無視")
            return
        case .disconnected, .failed:
            break  // 接続可能
        }
        
        // 前回のリソースを確実に解放
        listener?.cancel()
        listener = nil
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        serverConnection?.cancel()
        serverConnection = nil
        packetBuffer.removeAll()
        
        state = .connecting
        
        // 1. まずUDPリスナーを起動
        do {
            try startListening()
        } catch {
            state = .failed(error)
            // print("[NetworkReceiver] リスナー起動失敗: \(error)")
            return
        }
        
        // 2. サーバーに自分のリスニングポートを通知
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        serverConnection = NWConnection(to: endpoint, using: .tcp)  // ★ TCP接続に変更
        
        serverConnection?.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            
            switch newState {
            case .ready:
                // 接続確立 → 自分のリッスンポートを送信
                self.sendRegistration()
                self.scheduleHeartbeat()
                Logger.network("✅ サーバー接続完了: \(host):\(port)")
                
            case .failed(let error):
                self.state = .failed(error)
                Logger.network("❌ サーバー接続失敗: \(error)", level: .error)
                
            case .cancelled:
                break // キャンセル
                
            default:
                break
            }
        }
        
        serverConnection?.start(queue: receiveQueue)
    }
    
    /// 切断
    func disconnect() {
        // Mac側に切断を通知
        sendDisconnectNotification()
        
        // クリーンアップ処理（少し遅延して送信完了を待つ）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.performDisconnect()
        }
    }
    
    private func sendDisconnectNotification() {
        // 切断パケット: [0xFF]
        var packet = Data()
        packet.append(0xFF)
        
        serverConnection?.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                // print("[NetworkReceiver] 切断通知エラー: \(error)")
            } else {
                // print("[NetworkReceiver] 切断通知送信完了")
            }
        })
    }
    
    private func performDisconnect() {
        listener?.cancel()
        listener = nil
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        serverConnection?.cancel()
        serverConnection = nil
        packetBuffer.removeAll()
        state = .disconnected
        // print("[NetworkReceiver] 切断")
    }
    
    // MARK: - Private Methods
    
    private func startListening() throws {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: listenPort)!)
        
        listener?.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            
            switch newState {
            case .ready:
                self.state = .listening
                // print("[NetworkReceiver] ポート\(self.listenPort)でリスニング開始")
                
            case .failed(let error):
                self.state = .failed(error)
                // print("[NetworkReceiver] リスナー失敗: \(error)")
                
            case .cancelled:
                break // リスナーキャンセル
                
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener?.start(queue: receiveQueue)
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        // UDPでは各パケットが異なるソースとして扱われる可能性がある
        // 既存接続をキャンセルせず、新しい接続を追加して共存させる
        let key = "\(connection.endpoint)"
        
        // 既に同じエンドポイントからの接続があれば再利用
        if connections[key] != nil {
            return
        }
        
        connections[key] = connection
        
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            
            switch newState {
            case .ready:
                self.state = .receiving
                self.startReceiving(connection)
                // print("[NetworkReceiver] データ受信開始: \(connection.endpoint)")
                
            case .failed(let error):
                // print("[NetworkReceiver] 接続エラー: \(error)")
                self.connections.removeValue(forKey: key)
                
            case .cancelled:
                // print("[NetworkReceiver] 接続キャンセル: \(key)")
                self.connections.removeValue(forKey: key)
                
            default:
                break
            }
        }
        
        connection.start(queue: receiveQueue)
    }
    
    private func sendRegistration() {
        // 登録パケット: [0xFE] [2バイト: リッスンポート] [userRecordID（UTF8文字列）]
        var packet = Data()
        packet.append(0xFE) // 登録パケットマーカー
        var port = listenPort.bigEndian
        packet.append(Data(bytes: &port, count: 2))
        
        // ★ Phase 3: userRecordIDを追加（取得済みがあればキャッシュを使用）
        if let userRecordID = cachedUserRecordID {
            packet.append(Data(userRecordID.utf8))
        }
        
        Logger.network("📤 登録パケット送信: \(packet.count)バイト")  // ★ デバッグログ
        
        serverConnection?.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                Logger.network("❌ 登録送信エラー: \(error)", level: .error)
            } else {
                Logger.network("✅ 登録パケット送信成功")
            }
        })
    }
    
    /// ★ Phase 3: userRecordIDを取得して接続時に送信
    func prefetchUserRecordID() {
        Task {
            do {
                let userRecordID = try await CloudKitManager.shared.fetchUserRecordID()
                await MainActor.run {
                    self.cachedUserRecordID = userRecordID
                    // print("[NetworkReceiver] userRecordID取得成功")
                }
            } catch {
                // print("[NetworkReceiver] userRecordID取得失敗: \(error)")
            }
        }
    }
    
    private func scheduleHeartbeat() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            // .listeningまたは.receiving状態でハートビートを送信
            switch self.state {
            case .listening, .receiving:
                self.sendRegistration()
                self.scheduleHeartbeat()
            default:
                break
            }
        }
    }
    
    private func startReceiving(_ connection: NWConnection) {
        receivePacket(on: connection)
    }
    
    private func receivePacket(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                // print("[NetworkReceiver] 受信エラー: \(error)")
                self.delegate?.networkReceiver(self, didFailWithError: error)
                return
            }
            
            if let data = content {
                self.processPacket(data)
            }
            
            // UDP では各データグラムが isComplete=true を返すが、
            // エラーがない限り常に次のパケットを待機する
            // （接続がキャンセルされた場合は self が nil になるか error が返る）
            self.receivePacket(on: connection)
        }
    }
    
    private func processPacket(_ data: Data) {
        // 認証結果パケットのチェック: [0xAA] [結果: 0x01=許可, 0x00=拒否]
        if data.count >= 2 && data[0] == 0xAA {
            let approved = data[1] == 0x01
            
            // ★ Phase 3: 認証成功時に暗号化鍵を生成
            if approved && !cryptoManager.hasKey {
                cryptoManager.generateKey()
                // print("[NetworkReceiver] 🔐 暗号化鍵生成完了（AES-256）")
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.networkReceiver(self, didReceiveAuthResult: approved)
            }
            // print("[NetworkReceiver] 認証結果受信: \(approved ? "許可" : "拒否")")
            return
        }
        
        // ヘッダー解析
        // [1バイト: タイプ] [8バイト: タイムスタンプ] [4バイト: 総パケット数] [4バイト: パケット番号] [データ]
        guard data.count >= 17 else {
            // print("[NetworkReceiver] パケットサイズ不足: \(data.count)バイト")
            return
        }
        
        let typeByte = data[0]
        guard let packetType = PacketType(rawValue: typeByte) else {
            // print("[NetworkReceiver] 不明なパケットタイプ: 0x\(String(format: "%02X", typeByte))")
            return
        }
        
        let timestamp = data.subdata(in: 1..<9).withUnsafeBytes {
            UInt64(bigEndian: $0.load(as: UInt64.self))
        }
        
        let totalPackets = data.subdata(in: 9..<13).withUnsafeBytes {
            Int(UInt32(bigEndian: $0.load(as: UInt32.self)))
        }
        
        let packetIndex = data.subdata(in: 13..<17).withUnsafeBytes {
            Int(UInt32(bigEndian: $0.load(as: UInt32.self)))
        }
        
        let payload = data.subdata(in: 17..<data.count)
        
        // ═══════════════════════════════════════════
        // ★ パケットロス無視戦略: 古いフレームは即座に破棄
        // ═══════════════════════════════════════════
        // SPS/PPS/VPS/PNGは常に受け入れる（デコーダ初期化・静止画品質に必要）
        if packetType == .vps || packetType == .sps || packetType == .pps || packetType == .pngFrame {
            if packetType == .pngFrame {
                // ★ PNGパケット到達確認ログ (パケット番号1のみ)
                if packetIndex == 0 {
                    // print("[NetworkReceiver] 📨 PNGパケット受信開始: ID=\(timestamp), Total=\(totalPackets)")
                }
            }
            
            // ★ PNGは複数パケットに分割される可能性があるため、再構築処理に進む
            if packetType == .pngFrame && totalPackets > 1 {
                // 複数パケットの場合は再構築処理へ（下のコードで処理）
            } else {
                deliverFrame(type: packetType, data: payload, timestamp: timestamp)
                return
            }
        }
        
        // 古いフレームは即破棄（しきい値判定 - 1秒以上古い場合のみ）
        // ★ PNGは静止画なので古いフレームチェックをスキップ
        if packetType != .pngFrame && isOlderFrame(timestamp, than: latestFrameId) {
            skippedFrameCount += 1
            // ★ ログ抑制: 10000件ごとのみ出力
            if skippedFrameCount % 10000 == 0 {
                // print("[NetworkReceiver] 古いフレームスキップ: 累計\(skippedFrameCount)フレーム")
            }
            return
        }
        
        // 最新フレームID更新（パケット破棄はしない - 並行受信を許可）
        if timestamp > latestFrameId {
            latestFrameId = timestamp
            // 定期クリーンアップ（新しいフレームID検知時に実行）
            cleanupOldBuffers(currentTimestamp: timestamp)
        }
        
        // 単一パケットの場合は即座に処理
        if totalPackets == 1 {
            deliverFrame(type: packetType, data: payload, timestamp: timestamp)
            return
        }
        
        // 複数パケットの場合は再構築
        let key = timestamp
        
        if packetBuffer[key] == nil {
            // print("[NetworkReceiver] 🧩 新規Assembler作成: ID=\(key), Type=\(packetType), Total=\(totalPackets)")
            packetBuffer[key] = PacketAssembler(totalPackets: totalPackets, packetType: packetType)
            frameStartTimes[key] = currentTimeMs()  // タイムアウト計測開始
        }
        
        packetBuffer[key]?.addPacket(index: packetIndex, data: payload)
        
        // ★ PNG再構築デバッグログ
        if let assembler = packetBuffer[key], assembler.packetType == .pngFrame {
            let receivedCount = assembler.receivedCount
            let totalCount = totalPackets
            // 100パケットごとにログ出力
            if receivedCount == 1 || receivedCount % 100 == 0 || receivedCount == Int(totalCount) {
                // print("[NetworkReceiver] 📦 PNG再構築(\(key)): \(receivedCount)/\(totalCount) パケット受信")
            }
        }
        
        // 全パケット揃った場合
        if let assembler = packetBuffer[key], assembler.isComplete {
            let frameType = assembler.packetType  // ★ 保存したタイプを使用
            if let assembledData = assembler.assemble() {
                if frameType == .pngFrame {
                    // print("[NetworkReceiver] ✅ PNG再構築完了: \(assembledData.count)バイト -> deliverFrameへ")
                }
                deliverFrame(type: frameType, data: assembledData, timestamp: timestamp)
            }
            packetBuffer.removeValue(forKey: key)
            frameStartTimes.removeValue(forKey: key)
            return
        }
        
        // ★ タイムアウトチェック
        if let startTime = frameStartTimes[key] {
            let elapsed = currentTimeMs() - startTime
            if elapsed > frameTimeoutMs {
                // タイムアウト - 不完全フレームを破棄
                packetBuffer.removeValue(forKey: key)
                frameStartTimes.removeValue(forKey: key)
                skippedFrameCount += 1
            }
        }
    }
    
    /// ★ 古いフレームかどうか判定（ラップアラウンド対応）
    private func isOlderFrame(_ id: UInt64, than latest: UInt64) -> Bool {
        // タイムスタンプベース
        if id < latest {
            let diff = latest - id
            // 1秒以上古い場合は「古い」と判定（1秒以内の遅延・並行受信は許容）
            return diff > 1_000_000_000
        }
        return false
    }
    
    /// ★ 現在時刻（ミリ秒）
    private func currentTimeMs() -> UInt64 {
        return UInt64(CFAbsoluteTimeGetCurrent() * 1000)
    }
    
    private func deliverFrame(type: PacketType, data: Data, timestamp: UInt64) {
        DispatchQueue.main.async {
            switch type {
            case .vps:
                if !self.hasLoggedParameterSets {
                    // print("[NetworkReceiver] HEVC VPS受信: \(data.count)バイト")
                }
                self.delegate?.networkReceiver(self, didReceiveVPS: data)
            case .sps:
                if !self.hasLoggedParameterSets {
                    // print("[NetworkReceiver] SPS受信: \(data.count)バイト")
                }
                self.delegate?.networkReceiver(self, didReceiveSPS: data)
            case .pps:
                if !self.hasLoggedParameterSets {
                    // print("[NetworkReceiver] PPS受信: \(data.count)バイト")
                    self.hasLoggedParameterSets = true
                }
                self.delegate?.networkReceiver(self, didReceivePPS: data)
            case .videoFrame:
                self.delegate?.networkReceiver(self, didReceiveVideoFrame: data, isKeyFrame: false, timestamp: timestamp)
            case .keyFrame:
                self.keyFrameReceiveCount += 1
                if self.keyFrameReceiveCount == 1 || self.keyFrameReceiveCount % 100 == 0 {
                    // print("[NetworkReceiver] キーフレーム受信: \(data.count)バイト (累計\(self.keyFrameReceiveCount)回)")
                }
                self.delegate?.networkReceiver(self, didReceiveVideoFrame: data, isKeyFrame: true, timestamp: timestamp)
            case .jpegFrame:
                if !self.hasLoggedOldJpeg {
                    // print("[NetworkReceiver] 旧JPEGフレーム受信(無視) - 今後ログ抜制")
                    self.hasLoggedOldJpeg = true
                }
            case .pngFrame:
                self.pngReceiveCount += 1
                if self.pngReceiveCount == 1 || self.pngReceiveCount % 100 == 0 {
                    // print("[NetworkReceiver] PNG静止画フレーム受信: \(data.count)バイト (累計\(self.pngReceiveCount)回)")
                }
                self.delegate?.networkReceiver(self, didReceivePNG: data)
            case .fecParity:
                break
            case .metadata:
                self.metadataReceiveCount += 1
                if self.metadataReceiveCount == 1 || self.metadataReceiveCount % 100 == 0 {
                    // print("[NetworkReceiver] メタデータ受信: \(data.count)バイト (累計\(self.metadataReceiveCount)回)")
                }
            }
        }
    }
    
    private func cleanupOldBuffers(currentTimestamp: UInt64) {
        // 1秒以上古いバッファを削除
        let threshold: UInt64 = 1_000_000_000 // 1秒（ナノ秒）
        
        packetBuffer = packetBuffer.filter { key, assembler in
            // ★ PNGフレームはID体系が異なる(Unix Time)可能性があるため、無条件に保持する
            // (PNGは静止画なので、古いからといって捨ててはいけない)
            if assembler.packetType == .pngFrame {
                return true
            }
            // 最新より新しい(未来) or 最新から1秒以内
            return key >= currentTimestamp || (currentTimestamp - key < threshold)
        }
        
        // スタート時間も packetBuffer の生存に合わせてクリーンアップ
        frameStartTimes = frameStartTimes.filter { key, _ in
            packetBuffer.keys.contains(key)
        }
    }
}
