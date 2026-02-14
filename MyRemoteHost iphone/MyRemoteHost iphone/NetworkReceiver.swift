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
    
    /// OmniscientStateを受信
    func networkReceiver(_ receiver: NetworkReceiver, didReceiveOmniscientState state: OmniscientState)
    

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

        case fecParity = 0x07  // ★ Phase 2: FECパリティ
        case metadata = 0x08   // ★ Phase 4: メタデータ
        case handshake = 0x09  // ★ Phase 4: ECDHハンドシェイク
        case omniscientState = 0x50 // ★ Phase 2: 全知全能ステート送信
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
    /// TURN経由では遅延が大きいため動的に調整
    private var frameTimeoutMs: UInt64 = 200  // ★ Phase 3: フレームタイムアウト（200ms — TURN時は2000ms）
    
    /// ★ フレーム開始時刻（タイムアウト用）
    private var frameStartTimes: [UInt64: UInt64] = [:]
    
    /// ★ スキップされたフレーム数（デバッグ用）
    private var skippedFrameCount: Int = 0
    
    /// ★ Phase 3: 連続タイムアウトカウンタ（キーフレーム自動要求用）
    private var consecutiveTimeoutCount: Int = 0
    
    /// ★ Phase 3: userRecordIDキャッシュ（Apple ID認証用）
    private(set) var cachedUserRecordID: String?  // ★ 外部から読み取り可能に
    
    /// ★ Phase 2: FECデコーダー
    private let fecDecoder = FECDecoder()
    
    /// ★ Phase 2: FEC有効化フラグ
    var fecEnabled: Bool = true
    
    /// ★ Phase 3: 暗号化マネージャー
    let cryptoManager = CryptoManager()
    
    /// ★ Phase 3: 暗号化有効化フラグ
    var encryptionEnabled: Bool = true
    
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
        
        // ★ Phase 2.5: 欠落チャンクの文字列表現（例: "0, 1, 5-10"）
        var missingChunksString: String {
            var missing: [Int] = []
            for i in 0..<totalPackets {
                if receivedPackets[i] == nil {
                    missing.append(i)
                }
            }
            
            // 簡易的な範囲圧縮（数が多い場合に見やすくする）
            if missing.isEmpty { return "None" }
            if missing.count > 20 {
                return "\(missing.prefix(10).map(String.init).joined(separator: ",")) ... (Total \(missing.count) missing)"
            }
            return missing.map(String.init).joined(separator: ",")
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
            Logger.network("⚠️ 既に接続中または接続処理中 - 無視")
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
            Logger.network("❌ リスナー起動失敗: \(error)")
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
                
                // ★ TCPからもデータ受信待ちを開始（認証結果 0xAA を受信するため）
                self.startReceiving(self.serverConnection!)
                
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
    
    // MARK: - TURN Relay Support
    
    /// ★ Step 2: TURN接続モードフラグ
    /// TURN relay経由の場合、TCP登録やUDPリスナーではなくTURN経由でデータを送受信
    private(set) var isTURNMode: Bool = false
    
    /// ★ Step 2: TURN relay経由で受信したデータを既存パイプラインに注入
    /// TURNClient.onDataReceived → この関数 → processPacket()
    func injectTURNData(_ data: Data) {
        receiveQueue.async { [weak self] in
            guard let self = self else { return }
            self.processPacket(data)
        }
    }
    
    /// ★ Step 2: TURNモードでの接続開始
    /// 直接TCP/UDP接続の代わりにTURN relay経由で通信する
    func connectViaTURN() {
        isTURNMode = true
        state = .receiving
        // ★ TURN経由はネットワーク遅延が大きいためタイムアウトを緩和
        frameTimeoutMs = 2000
        Logger.network("🔄 TURN relayモード: データ注入待機中 (timeout=\(frameTimeoutMs)ms)")
        
        // TURN経由ではTCP登録パケットを送らない
        // 代わりにCloudKit経由でMacに存在を通知する
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
    
    /// ★ Phase 3: キーフレーム自動要求（連続ロス時）
    private func requestKeyFrame() {
        // キーフレーム要求パケット: [0xFC]
        var packet = Data()
        packet.append(0xFC)
        
        serverConnection?.send(content: packet, completion: .contentProcessed { error in
            if error == nil {
                Logger.pipeline("★ キーフレーム自動要求送信")
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
            Logger.network("🔄 既存UDP接続再利用: \(key)")
            return
        }
        
        Logger.network("🆕 新規UDP接続: \(key), 接続数: \(connections.count + 1)")
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
        
        Logger.network("📤 登録パケット送信: \(packet.count)バイト", sampling: .oncePerSession)  // 初回のみ
        
        serverConnection?.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                Logger.network("❌ 登録送信エラー: \(error)", level: .error)
            }
            // 成功ログは冗長なため削除
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
                Logger.network("❌ UDP受信エラー: \(error)", level: .error)
                self.delegate?.networkReceiver(self, didFailWithError: error)
                return
            }
            
            if let data = content {
                // ★ 診断ログ: パケット受信確認
                if data.count >= 1 {
                    let typeByte = data[0]
                    Logger.network("📥 UDP受信: \(data.count)bytes, type=0x\(String(format: "%02X", typeByte))", sampling: .perSecond)
                }
                self.processPacket(data)
            } else {
                Logger.network("⚠️ UDP受信: contentがnil", level: .warning)
            }
            
            // UDP では各データグラムが isComplete=true を返すが、
            // エラーがない限り常に次のパケットを待機する
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
            UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
        }
        
        let totalPackets = data.subdata(in: 9..<13).withUnsafeBytes {
            Int(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
        }
        
        let packetIndex = data.subdata(in: 13..<17).withUnsafeBytes {
            Int(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
        }
        
        let payload = data.subdata(in: 17..<data.count)
        
        // ═══════════════════════════════════════════
        // ★ パケットロス無視戦略: 古いフレームは即座に破棄
        // ═══════════════════════════════════════════
        // SPS/PPS/VPSは常に受け入れる（デコーダ初期化に必要）
        // SPS/PPS/VPSは常に受け入れる（デコーダ初期化に必要）
        if packetType == .vps || packetType == .sps || packetType == .pps {
            // ★ Phase 4: 復号 (パラメータセットも暗号化されている)
            guard let finalData = cryptoManager.decryptIfEnabled(payload) else {
                Logger.network("⚠️ パラメータセット復号失敗 type=\(packetType) size=\(payload.count)", level: .error)
                return
            }
            Logger.network("✅ パラメータセット受信: type=\(packetType) size=\(finalData.count)", sampling: .oncePerSession)
            deliverFrame(type: packetType, data: finalData, timestamp: timestamp)
            return
        }
        
        // 古いフレームは即破棄（しきい値判定 - 200ms以上古い場合のみ）
        // ★ ただし、以下は古いフレーム判定から除外して保護:
        //    1. キーフレーム: デコード再開に必須、TURN経由では大幅に遅延する可能性あり
        //    2. 既にAssemblerが存在する: 分割受信中のフレーム（後続チャンク到着待ち）
        let isProtected = (packetType == .keyFrame) || (packetBuffer[timestamp] != nil)
        
        // ★ Phase 0 診断: パケット到着ログ（KF/PF両方）
        if packetType == .keyFrame {
            Logger.network("🔑 KFチャンク受信: \(packetIndex)/\(totalPackets) ts=\(timestamp) protected=\(isProtected)")
        } else if packetType == .videoFrame {
            Logger.network("🎬 PFチャンク受信: \(packetIndex)/\(totalPackets) ts=\(timestamp) size=\(payload.count)", sampling: .throttle(1.0))
        }
        
        if isOlderFrame(timestamp, than: latestFrameId) && !isProtected {
            skippedFrameCount += 1
            // ★ 診断: P-frameが古いフレーム判定でドロップされた場合にログ
            if packetType == .videoFrame && skippedFrameCount <= 10 {
                Logger.network("⚠️ PF古いフレームドロップ: ts=\(timestamp) latest=\(latestFrameId) diff=\(latestFrameId - timestamp)", level: .warning)
            }
            return
        }
        
        // 最新フレームID更新（パケット破棄はしない - 並行受信を許可）
        // ★ Phase 2: キーフレーム再構築中はlatestFrameId更新を凍結
        //   キーフレームAssemblerが存在する間、P-frameがlatestFrameIdを進めるのを防止
        let hasKeyFrameAssembler = packetBuffer.values.contains { $0.packetType == .keyFrame }
        if timestamp > latestFrameId && !hasKeyFrameAssembler {
            latestFrameId = timestamp
            // 定期クリーンアップ（新しいフレームID検知時に実行）
            cleanupOldBuffers(currentTimestamp: timestamp)
        }
        
        // 単一パケットの場合は即座に処理
        if totalPackets == 1 {
            // ★ Phase 4: 復号 (ハンドシェイク以外)
            var finalData = payload
            if packetType != .handshake {
                guard let decrypted = cryptoManager.decryptIfEnabled(payload) else {
                    print("[NetworkReceiver] ⚠️ 単一パケット復号失敗 → 破棄")
                    return
                }
                finalData = decrypted
                // if finalData.count != payload.count { print("🔓 Decrypted: \(payload.count) -> \(finalData.count) bytes") }
            }
            deliverFrame(type: packetType, data: finalData, timestamp: timestamp)
            return
        }
        
        // 複数パケットの場合は再構築
        let key = timestamp
        
        if packetBuffer[key] == nil {
            // ★ Phase 0 診断: キーフレーム用Assembler作成ログ
            if packetType == .keyFrame {
                Logger.network("🔑 KF Assembler作成: ts=\(key), total=\(totalPackets)チャンク")
            }
            packetBuffer[key] = PacketAssembler(totalPackets: totalPackets, packetType: packetType)
            frameStartTimes[key] = currentTimeMs()  // タイムアウト計測開始
        }
        
        packetBuffer[key]?.addPacket(index: packetIndex, data: payload)
        
        // 全パケット揃った場合
        if let assembler = packetBuffer[key], assembler.isComplete {
            let frameType = assembler.packetType  // ★ 保存したタイプを使用
            
            // ★ Phase 0 診断: キーフレーム再構築完了ログ
            if frameType == .keyFrame {
                Logger.network("🔑🎉 KF再構築完了! ts=\(key), total=\(totalPackets)チャンク")
            }
            
            if let assembledData = assembler.assemble() {
                
                // ★ Phase 4: 復号 (組み立て後)
                var finalData = assembledData
                if frameType != .handshake {
                    guard let decrypted = cryptoManager.decryptIfEnabled(assembledData) else {
                        print("[NetworkReceiver] ⚠️ 組み立て済みフレーム復号失敗 → 破棄")
                        packetBuffer.removeValue(forKey: key)
                        frameStartTimes.removeValue(forKey: key)
                        return
                    }
                    finalData = decrypted
                    // if finalData.count != assembledData.count { print("🔓 Decrypted(Assembled): \(assembledData.count) -> \(finalData.count) bytes") }
                }
                deliverFrame(type: frameType, data: finalData, timestamp: timestamp)
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
                consecutiveTimeoutCount += 1
                
                // ★ Phase 3: 連続タイムアウト時はキーフレーム自動要求
                if consecutiveTimeoutCount >= 5 {
                    requestKeyFrame()
                    consecutiveTimeoutCount = 0
                }
            }
        }
    }
    
    /// ★ 最適化 3-A: 古いフレーム判定（TURN時はjitter許容を拡大）
    private func isOlderFrame(_ id: UInt64, than latest: UInt64) -> Bool {
        if id < latest {
            let diff = latest - id
            // TURN経由ではパケット到着ジッターが大きいため、
            // 有効フレームの過剰ドロップを防止（200ms→500ms）
            let thresholdNs: UInt64 = isTURNMode ? 500_000_000 : 200_000_000
            return diff > thresholdNs
        }
        return false
    }
    
    /// ★ 現在時刻（ミリ秒）
    private func currentTimeMs() -> UInt64 {
        return UInt64(CFAbsoluteTimeGetCurrent() * 1000)
    }
    
    private func deliverFrame(type: PacketType, data: Data, timestamp: UInt64) {
        // ★ Phase 3: 正常フレーム受信でタイムアウトカウンタリセット
        consecutiveTimeoutCount = 0
        DispatchQueue.main.async {
            self.handlePacketOnMain(type: type, data: data, timestamp: timestamp)
        }
    }
    
    private func handlePacketOnMain(type: PacketType, data: Data, timestamp: UInt64) {
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

        case .fecParity:
            break
        case .metadata:
            self.metadataReceiveCount += 1
            if self.metadataReceiveCount == 1 || self.metadataReceiveCount % 100 == 0 {
                // print("[NetworkReceiver] メタデータ受信: \(data.count)バイト (累計\(self.metadataReceiveCount)回)")
            }
        case .handshake:
            do {
                Logger.network("🔐 ハンドシェイク受信(Server->Client): \(data.count) bytes")
                
                // 1. 自分の鍵ペアを生成 (0xEC + PubKey)
                let myHandshakePayload = self.cryptoManager.generateECDHHandshakePacket()
                
                // 2. 相手の鍵で共有鍵を生成 (0xECチェック含む)
                try self.cryptoManager.processECDHHandshake(data)
                Logger.network("✅ E2E暗号化接続 確立完了 (Client)")
                
                // 3. 自分の公開鍵を返信
                 for (_, conn) in self.connections {
                     self.sendHandshake(myHandshakePayload, to: conn)
                 }
                
            } catch {
                Logger.network("❌ ハンドシェイク失敗: \(error)", level: .error)
            }
        case .omniscientState:
            do {
                let state = try JSONDecoder().decode(OmniscientState.self, from: data)
                self.delegate?.networkReceiver(self, didReceiveOmniscientState: state)
            } catch {
                Logger.network("⚠️ OmniscientStateデコード失敗: \(error)", level: .warning)
            }
        }
    }
    
    /// ★ Phase 4: ハンドシェイク返信 (Client->Server)
    private func sendHandshake(_ payload: Data, to connection: NWConnection) {
        Logger.network("🔐 ハンドシェイク送信(Client->Server): \(payload.count)バイト")
        
        // ヘッダー作成
        var packet = Data()
        packet.append(PacketType.handshake.rawValue)
        var ts: UInt64 = 0
        packet.append(Data(bytes: &ts, count: 8))
        var total: UInt32 = 1
        packet.append(contentsOf: Data(bytes: &total, count: 4).reversed())
        var index: UInt32 = 0
        packet.append(contentsOf: Data(bytes: &index, count: 4).reversed())
        
        packet.append(payload) // 既に 0xEC 付き
        
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }
    
    private func cleanupOldBuffers(currentTimestamp: UInt64) {
        // 1秒以上古いバッファを削除
        let threshold: UInt64 = 1_000_000_000 // 1秒（ナノ秒）
        // ★ Phase 2: キーフレームAssemblerは5秒まで延長保護（TURN遅延対応）
        let kfThreshold: UInt64 = 5_000_000_000 // 5秒
        
        packetBuffer = packetBuffer.filter { key, assembler in
            let effectiveThreshold = (assembler.packetType == .keyFrame) ? kfThreshold : threshold
            // 最新より新しい(未来) or 閾値以内
            let isAlive = key >= currentTimestamp || (currentTimestamp - key < effectiveThreshold)
            
            // ★ Phase 2.5: タイムアウト(破棄)時の詳細ログ
            if !isAlive && assembler.packetType == .keyFrame {
                let percent = Int(Double(assembler.receivedCount) / Double(assembler.totalPackets) * 100)
                Logger.network("⚠️ KF再構築失敗(Timeout): ts=\(key) 受信=\(assembler.receivedCount)/\(assembler.totalPackets)(\(percent)%) 欠落idx=[\(assembler.missingChunksString)]")
            }
            
            return isAlive
        }
        
        // スタート時間も packetBuffer の生存に合わせてクリーンアップ
        frameStartTimes = frameStartTimes.filter { key, _ in
            packetBuffer.keys.contains(key)
        }
    }
}
