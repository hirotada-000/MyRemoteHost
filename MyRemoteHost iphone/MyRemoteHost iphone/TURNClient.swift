//
//  TURNClient.swift
//  MyRemoteHost iphone
//
//  TURN (Traversal Using Relays around NAT) クライアント
//  Oracle Cloud Always Free ARM VPS上のCoturnに接続
//  P2P接続失敗時のフォールバックとしてリレー接続を提供
//
//  Phase 1: Oracle TURN（公共Wi-Fi対応）
//

import Foundation
import Network
import CommonCrypto

// MARK: - TURN Configuration

/// TURNサーバー設定
public struct TURNConfiguration: Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let credential: String
    public let realm: String
    
    /// Oracle Cloud Always Free TURN サーバー
    /// ★ ユーザーがサーバーセットアップ後に実際の値に置き換え
    public static let oracleAlwaysFree = TURNConfiguration(
        host: "161.33.131.27",
        port: 3478,
        username: "user",
        credential: "password",
        realm: "my-turn-server"
    )
    
    public init(host: String, port: UInt16, username: String, credential: String, realm: String) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.realm = realm
    }
}

// MARK: - TURN Message Types (RFC 5766)

/// TURNメッセージタイプ
private enum TURNMessageType: UInt16 {
    // STUN互換
    case bindingRequest = 0x0001
    case bindingResponse = 0x0101
    
    // TURN固有
    case allocateRequest = 0x0003
    case allocateResponse = 0x0103
    case allocateErrorResponse = 0x0113
    
    case refreshRequest = 0x0004
    case refreshResponse = 0x0104
    
    case createPermissionRequest = 0x0008
    case createPermissionResponse = 0x0108
    
    case channelBindRequest = 0x0009
    case channelBindResponse = 0x0109
    
    case sendIndication = 0x0016
    case dataIndication = 0x0017
}

/// TURN/STUN属性タイプ
private enum TURNAttributeType: UInt16 {
    case mappedAddress = 0x0001
    case username = 0x0006
    case messageIntegrity = 0x0008
    case errorCode = 0x0009
    case channelNumber = 0x000C
    case lifetime = 0x000D
    case xorPeerAddress = 0x0012
    case data = 0x0013
    case realm = 0x0014
    case nonce = 0x0015
    case xorRelayedAddress = 0x0016
    case requestedTransport = 0x0019
    case xorMappedAddress = 0x0020
    case software = 0x8022
}

/// STUNマジッククッキー（RFC 5389）
private let turnMagicCookie: UInt32 = 0x2112A442

// MARK: - TURN Allocate Result

/// TURN Allocate結果
public struct TURNAllocateResult: Sendable {
    /// リレーアドレス（サーバー側で割り当てられたIP）
    public let relayIP: String
    /// リレーポート
    public let relayPort: UInt16
    /// マッピングされたアドレス（クライアントから見たIP）
    public let mappedIP: String
    /// マッピングされたポート
    public let mappedPort: UInt16
    /// 割り当ての有効期間（秒）
    public let lifetime: UInt32
}

// MARK: - TURN Client

/// TURNクライアント
/// Oracle Cloud Always FreeのCoturnサーバーに接続してリレーを確立
public actor TURNClient {
    
    // MARK: - Properties
    
    /// TURN設定
    private let config: TURNConfiguration
    
    /// UDPコネクション
    private var connection: NWConnection?
    
    /// タイムアウト（秒）
    private let timeout: TimeInterval = 10.0
    
    /// 現在のトランザクションID
    private var currentTransactionID: Data?
    
    /// サーバーから受け取ったnonce
    private var serverNonce: String?
    
    /// サーバーから受け取ったrealm
    private var serverRealm: String?
    
    /// 現在のAllocation結果
    private var currentAllocation: TURNAllocateResult?
    
    /// Allocation リフレッシュタスク
    private var refreshTask: Task<Void, Never>?
    
    /// チャネルバインド済みのピアアドレス → チャネル番号マップ
    private var channelBindings: [String: UInt16] = [:]
    
    /// 次のチャネル番号（0x4000〜0x7FFF）
    private var nextChannelNumber: UInt16 = 0x4000
    
    /// データ受信コールバック
    var onDataReceived: ((Data) -> Void)?
    
    /// ★ 受信ループ稼働中フラグ
    private var receiveLoopRunning: Bool = false
    
    /// ★ 受信ループ経由のSTUNレスポンス待機用continuation
    private var pendingResponseContinuation: CheckedContinuation<Data, Error>?
    
    /// ★ Step 2: actor外からonDataReceivedを安全にセット
    public func setDataHandler(_ handler: @escaping (Data) -> Void) {
        onDataReceived = handler
    }
    
    // MARK: - Init
    
    public init(config: TURNConfiguration = .oracleAlwaysFree) {
        self.config = config
    }
    
    // MARK: - Public Methods
    
    /// TURN Allocateリクエストを送信してリレーを確立
    public func allocate() async throws -> TURNAllocateResult {
        Logger.turn("🔄 TURN Allocate開始: \(config.host):\(config.port)")
        
        // UDPコネクション作成
        Logger.turn("📋 allocate() Step 1: UDP接続作成中...")
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.port)!
        )
        let conn = NWConnection(to: endpoint, using: .udp)
        self.connection = conn
        
        // 接続待機
        Logger.turn("📋 allocate() Step 2: 接続待機中...")
        try await waitForConnection(conn)
        Logger.turn("📋 allocate() Step 3: 接続Ready, 初回Allocate送信...")
        
        // Step 1: 初回Allocate（nonceなし → 401エラーでnonce取得）
        let initialRequest = createAllocateRequest(withAuth: false)
        let errorResponse = try await sendAndReceive(conn, data: initialRequest)
        Logger.turn("📋 allocate() Step 4: 401受信 (\(errorResponse.count)bytes), nonce解析...")
        parseErrorResponse(errorResponse)
        
        guard let nonce = serverNonce, let realm = serverRealm else {
            Logger.turn("❌ allocate() Step 4失敗: nonce/realmが取得できませんでした")
            throw TURNError.authenticationFailed
        }
        
        Logger.turn("📝 Nonce取得成功、認証付きAllocateを送信")
        
        // Step 2: 認証付きAllocate
        Logger.turn("📋 allocate() Step 5: 認証付きAllocate送信中...")
        let authRequest = createAllocateRequest(withAuth: true)
        
        // ★ デバッグ: 送信パケットのhexダンプ
        let hexDump = authRequest.prefix(120).map { String(format: "%02X", $0) }.joined(separator: " ")
        Logger.turn("📋 allocate() Step 5 送信データ (\(authRequest.count)bytes): \(hexDump)")
        // メッセージ長フィールドの値
        if authRequest.count >= 4 {
            let msgLen = UInt16(authRequest[2]) << 8 | UInt16(authRequest[3])
            Logger.turn("📋 allocate() Step 5 メッセージ長フィールド: \(msgLen), 実際のペイロード: \(authRequest.count - 20)")
        }
        
        let response = try await sendAndReceive(conn, data: authRequest)
        Logger.turn("📋 allocate() Step 6: レスポンス受信 (\(response.count)bytes), 解析中...")
        
        // ★ B-2: レスポンスヘッダーをログ
        if response.count >= 2 {
            let msgType = UInt16(response[0]) << 8 | UInt16(response[1])
            Logger.turn("📋 allocate() レスポンスタイプ: 0x\(String(format: "%04X", msgType))")
        }
        
        // ★ B-2+: 438 Stale Nonce リトライ
        do {
            let result = try parseAllocateResponse(response)
            
            currentAllocation = result
            Logger.turn("✅ TURN Allocate成功: \(result.relayIP):\(result.relayPort) (lifetime: \(result.lifetime)s)")
            
            // リフレッシュタスクを開始
            startRefreshLoop(lifetime: result.lifetime)
            
            // ★ B-3: startReceiveLoopはここでは開始しない
            // createPermission/channelBindのsendAndReceive()と受信競合するため
            // セットアップ完了後にstartReceiving()を呼ぶ
            
            return result
        } catch TURNError.allocateFailed where lastErrorCode == 438 {
            // ★ 438 Stale Nonce: 新しいnonceで再試行
            Logger.turn("🔄 438 Stale Nonce → 新しいnonceで再Allocate試行")
            
            guard serverNonce != nil else {
                throw TURNError.authenticationFailed
            }
            
            let retryRequest = createAllocateRequest(withAuth: true)
            let retryResponse = try await sendAndReceive(conn, data: retryRequest)
            let result = try parseAllocateResponse(retryResponse)
            
            currentAllocation = result
            Logger.turn("✅ TURN Allocate成功（リトライ）: \(result.relayIP):\(result.relayPort) (lifetime: \(result.lifetime)s)")
            
            startRefreshLoop(lifetime: result.lifetime)
            // ★ B-3: リトライ時も受信ループは開始しない
            
            return result
        }
    }
    
    /// ★ B-3: データ受信ループを開始（セットアップ完了後に呼ぶ）
    /// allocate()内で開始するとcreatePermission/channelBindのsendAndReceive()と受信競合するため分離
    public func startReceiving() {
        guard let conn = connection else {
            Logger.turn("⚠️ startReceiving: 接続なし", level: .warning)
            return
        }
        Logger.turn("📡 データ受信ループ開始")
        startReceiveLoop(conn)
    }
    
    /// リレー経由でデータを送信
    public func sendData(_ data: Data, to peerIP: String, peerPort: UInt16) async throws {
        guard let conn = connection else {
            throw TURNError.notAllocated
        }
        
        let peerKey = "\(peerIP):\(peerPort)"
        
        // チャネルバインドがあればChannelDataで送信（効率的）
        if let channelNumber = channelBindings[peerKey] {
            let channelData = createChannelData(channel: channelNumber, data: data)
            try await send(conn, data: channelData)
        } else {
            // Send Indicationで送信（チャネルバインドなし）
            let indication = createSendIndication(data: data, peerIP: peerIP, peerPort: peerPort)
            try await send(conn, data: indication)
        }
    }
    
    /// CreatePermissionリクエスト（特定ピアからのデータ受信を許可）
    public func createPermission(for peerIP: String, peerPort: UInt16) async throws {
        guard let conn = connection else {
            throw TURNError.notAllocated
        }
        
        Logger.turn("🔑 CreatePermission: \(peerIP):\(peerPort)")
        
        let request = createPermissionRequest(peerIP: peerIP, peerPort: peerPort)
        let response = try await sendAndReceive(conn, data: request)
        
        // レスポンス検証（成功/エラー判定）
        let msgType = UInt16(response[0]) << 8 | UInt16(response[1])
        if msgType == TURNMessageType.createPermissionResponse.rawValue {
            Logger.turn("✅ Permission作成成功: \(peerIP)")
        } else {
            // ★ B-3: エラー詳細をログ
            lastErrorCode = 0
            parseErrorResponse(response)
            Logger.turn("❌ Permission拒否: code=\(lastErrorCode) (\(errorCodeDescription(lastErrorCode))) peer=\(peerIP):\(peerPort)", level: .error)
            throw TURNError.permissionDenied
        }
    }
    
    /// ChannelBindリクエスト（効率的なデータ転送用）
    public func channelBind(peerIP: String, peerPort: UInt16) async throws -> UInt16 {
        guard let conn = connection else {
            throw TURNError.notAllocated
        }
        
        let channelNumber = nextChannelNumber
        nextChannelNumber += 1
        
        Logger.turn("📡 ChannelBind: ch=\(String(format: "0x%04X", channelNumber)) → \(peerIP):\(peerPort)")
        
        let request = createChannelBindRequest(channel: channelNumber, peerIP: peerIP, peerPort: peerPort)
        let response = try await sendAndReceive(conn, data: request)
        
        let msgType = UInt16(response[0]) << 8 | UInt16(response[1])
        if msgType == TURNMessageType.channelBindResponse.rawValue {
            channelBindings["\(peerIP):\(peerPort)"] = channelNumber
            Logger.turn("✅ ChannelBind成功: ch=\(String(format: "0x%04X", channelNumber))")
            return channelNumber
        } else {
            throw TURNError.channelBindFailed
        }
    }
    
    /// Allocationを解放（接続終了時）
    public func deallocate() async {
        refreshTask?.cancel()
        refreshTask = nil
        
        if let conn = connection {
            // Refresh with lifetime=0 でAllocationを解放
            let request = createRefreshRequest(lifetime: 0)
            try? await send(conn, data: request)
            conn.cancel()
        }
        
        connection = nil
        currentAllocation = nil
        channelBindings = [:]
        serverNonce = nil
        serverRealm = nil
        
        Logger.turn("🔌 TURN Allocation解放完了")
    }
    
    /// リレーアドレスをICE候補として取得
    public func getRelayCandidates() -> [ICECandidate] {
        guard let allocation = currentAllocation else { return [] }
        
        return [
            ICECandidate(
                type: .relay,
                ip: allocation.relayIP,
                port: Int(allocation.relayPort),
                priority: 100  // relay候補は最低優先度
            )
        ]
    }
    
    // MARK: - Private Methods - Message Construction
    
    /// Allocateリクエスト作成
    private func createAllocateRequest(withAuth: Bool) -> Data {
        var attributes = Data()
        
        // REQUESTED-TRANSPORT: UDP (17) — RFC 5766 §14.7
        // Format: [Protocol Number (1 byte)] [RFFU (3 bytes, must be 0)]
        // ★ B-2+: ビッグエンディアンで正しく送信
        let transportData = Data([17, 0, 0, 0])
        attributes.append(createAttribute(type: .requestedTransport, value: transportData))
        
        if withAuth, let nonce = serverNonce, let realm = serverRealm {
            // USERNAME
            let usernameData = Data(config.username.utf8)
            attributes.append(createAttribute(type: .username, value: usernameData))
            
            // REALM
            let realmData = Data(realm.utf8)
            attributes.append(createAttribute(type: .realm, value: realmData))
            
            // NONCE
            let nonceData = Data(nonce.utf8)
            attributes.append(createAttribute(type: .nonce, value: nonceData))
        }
        
        var message = createSTUNHeader(type: .allocateRequest, length: UInt16(attributes.count))
        message.append(attributes)
        
        // MESSAGE-INTEGRITY（認証付きの場合）
        // ★ B-2+: RFC 5389 §15.4準拠 — HMAC計算前にMI属性サイズ(24バイト)分をメッセージ長に含める
        if withAuth {
            // Step 1: メッセージ長をMESSAGE-INTEGRITY属性を含む値に更新
            //   MI属性 = 4バイトヘッダ + 20バイトHMAC-SHA1 = 24バイト
            message = updateMessageLength(message, addBytes: 24)
            
            // Step 2: 更新済みメッセージでHMAC-SHA1を計算
            let hmac = computeHMACSHA1(message: message)
            
            // Step 3: MESSAGE-INTEGRITY属性を追加
            let miAttr = createAttribute(type: .messageIntegrity, value: hmac)
            message.append(miAttr)
        }
        
        return message
    }
    
    /// CreatePermissionリクエスト作成
    private func createPermissionRequest(peerIP: String, peerPort: UInt16) -> Data {
        var attributes = Data()
        
        // XOR-PEER-ADDRESS
        let peerAddr = createXorAddress(ip: peerIP, port: peerPort, type: .xorPeerAddress)
        attributes.append(peerAddr)
        
        // 認証属性
        if let nonce = serverNonce, let realm = serverRealm {
            attributes.append(createAttribute(type: .username, value: Data(config.username.utf8)))
            attributes.append(createAttribute(type: .realm, value: Data(realm.utf8)))
            attributes.append(createAttribute(type: .nonce, value: Data(nonce.utf8)))
        }
        
        var message = createSTUNHeader(type: .createPermissionRequest, length: UInt16(attributes.count))
        message.append(attributes)
        
        // ★ B-2+: RFC 5389 §15.4準拠 — MI属性サイズ(24バイト)を含めた長さでHMAC計算
        message = updateMessageLength(message, addBytes: 24)
        let hmac = computeHMACSHA1(message: message)
        message.append(createAttribute(type: .messageIntegrity, value: hmac))
        
        return message
    }
    
    /// ChannelBindリクエスト作成
    private func createChannelBindRequest(channel: UInt16, peerIP: String, peerPort: UInt16) -> Data {
        var attributes = Data()
        
        // CHANNEL-NUMBER (RFC 5766 §14.1)
        // Format: [Channel Number (2 bytes, big-endian)] [RFFU (2 bytes, must be 0)]
        var channelBE = channel.bigEndian
        var channelData = Data(bytes: &channelBE, count: 2)
        channelData.append(Data([0x00, 0x00]))  // RFFU
        attributes.append(createAttribute(type: .channelNumber, value: channelData))
        
        // XOR-PEER-ADDRESS
        let peerAddr = createXorAddress(ip: peerIP, port: peerPort, type: .xorPeerAddress)
        attributes.append(peerAddr)
        
        // 認証属性
        if let nonce = serverNonce, let realm = serverRealm {
            attributes.append(createAttribute(type: .username, value: Data(config.username.utf8)))
            attributes.append(createAttribute(type: .realm, value: Data(realm.utf8)))
            attributes.append(createAttribute(type: .nonce, value: Data(nonce.utf8)))
        }
        
        var message = createSTUNHeader(type: .channelBindRequest, length: UInt16(attributes.count))
        message.append(attributes)
        
        // ★ B-2+: RFC 5389 §15.4準拠
        message = updateMessageLength(message, addBytes: 24)
        let hmac = computeHMACSHA1(message: message)
        message.append(createAttribute(type: .messageIntegrity, value: hmac))
        
        return message
    }
    
    /// Refreshリクエスト作成
    private func createRefreshRequest(lifetime: UInt32) -> Data {
        var attributes = Data()
        
        // LIFETIME
        var lt = lifetime.bigEndian
        attributes.append(createAttribute(type: .lifetime, value: Data(bytes: &lt, count: 4)))
        
        // 認証属性
        if let nonce = serverNonce, let realm = serverRealm {
            attributes.append(createAttribute(type: .username, value: Data(config.username.utf8)))
            attributes.append(createAttribute(type: .realm, value: Data(realm.utf8)))
            attributes.append(createAttribute(type: .nonce, value: Data(nonce.utf8)))
        }
        
        var message = createSTUNHeader(type: .refreshRequest, length: UInt16(attributes.count))
        message.append(attributes)
        
        // ★ B-2+: RFC 5389 §15.4準拠
        message = updateMessageLength(message, addBytes: 24)
        let hmac = computeHMACSHA1(message: message)
        message.append(createAttribute(type: .messageIntegrity, value: hmac))
        
        return message
    }
    
    /// Send Indication作成（リレー経由データ送信）
    private func createSendIndication(data payload: Data, peerIP: String, peerPort: UInt16) -> Data {
        var attributes = Data()
        
        // XOR-PEER-ADDRESS
        let peerAddr = createXorAddress(ip: peerIP, port: peerPort, type: .xorPeerAddress)
        attributes.append(peerAddr)
        
        // DATA
        attributes.append(createAttribute(type: .data, value: payload))
        
        var message = createSTUNHeader(type: .sendIndication, length: UInt16(attributes.count))
        message.append(attributes)
        
        return message
    }
    
    /// ChannelData作成（チャネルバインド経由の効率的データ送信）
    private func createChannelData(channel: UInt16, data payload: Data) -> Data {
        var result = Data()
        
        // Channel Number (2 bytes)
        var ch = channel.bigEndian
        result.append(Data(bytes: &ch, count: 2))
        
        // Length (2 bytes)
        var length = UInt16(payload.count).bigEndian
        result.append(Data(bytes: &length, count: 2))
        
        // Data
        result.append(payload)
        
        // 4バイト境界パディング
        let padding = (4 - (payload.count % 4)) % 4
        if padding > 0 {
            result.append(Data(repeating: 0, count: padding))
        }
        
        return result
    }
    
    // MARK: - Private Methods - Message Helpers
    
    /// STUNヘッダー作成
    private func createSTUNHeader(type: TURNMessageType, length: UInt16) -> Data {
        var data = Data()
        
        // Message Type
        var msgType = type.rawValue.bigEndian
        data.append(Data(bytes: &msgType, count: 2))
        
        // Message Length
        var msgLength = length.bigEndian
        data.append(Data(bytes: &msgLength, count: 2))
        
        // Magic Cookie
        var cookie = turnMagicCookie.bigEndian
        data.append(Data(bytes: &cookie, count: 4))
        
        // Transaction ID (12 bytes)
        var transactionID = Data(count: 12)
        _ = transactionID.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }
        currentTransactionID = transactionID
        data.append(transactionID)
        
        return data
    }
    
    /// 属性作成
    private func createAttribute(type: TURNAttributeType, value: Data) -> Data {
        var attr = Data()
        
        // Type
        var attrType = type.rawValue.bigEndian
        attr.append(Data(bytes: &attrType, count: 2))
        
        // Length
        var attrLength = UInt16(value.count).bigEndian
        attr.append(Data(bytes: &attrLength, count: 2))
        
        // Value
        attr.append(value)
        
        // 4バイト境界パディング
        let padding = (4 - (value.count % 4)) % 4
        if padding > 0 {
            attr.append(Data(repeating: 0, count: padding))
        }
        
        return attr
    }
    
    /// XORアドレス属性作成
    private func createXorAddress(ip: String, port: UInt16, type: TURNAttributeType) -> Data {
        var value = Data()
        
        // Reserved (1 byte)
        value.append(0x00)
        
        // Family: IPv4 = 0x01
        value.append(0x01)
        
        // XOR Port
        let xorPort = port ^ UInt16(turnMagicCookie >> 16)
        var xp = xorPort.bigEndian
        value.append(Data(bytes: &xp, count: 2))
        
        // XOR IP
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            let ipVal = UInt32(parts[0]) << 24 | UInt32(parts[1]) << 16 | UInt32(parts[2]) << 8 | UInt32(parts[3])
            let xorIP = ipVal ^ turnMagicCookie
            var xip = xorIP.bigEndian
            value.append(Data(bytes: &xip, count: 4))
        }
        
        return createAttribute(type: type, value: value)
    }
    
    /// メッセージ長を更新
    private func updateMessageLength(_ message: Data, addBytes: Int) -> Data {
        var updated = message
        let currentLength = UInt16(message.count - 20)  // ヘッダー20バイトを除く
        let newLength = currentLength + UInt16(addBytes)
        var len = newLength.bigEndian
        updated.replaceSubrange(2..<4, with: Data(bytes: &len, count: 2))
        return updated
    }
    
    /// HMAC-SHA1計算（RFC 5389 §15.4）
    /// ★ B-2+: computeMessageIntegrityからリネーム（Mac側と統一）
    private func computeHMACSHA1(message: Data) -> Data {
        // Key = MD5(username:realm:password)
        let keyString = "\(config.username):\(serverRealm ?? config.realm):\(config.credential)"
        let keyData = keyString.data(using: .utf8)!
        let md5Key = md5Hash(keyData)
        
        // HMAC-SHA1(key, message) — 20バイトの生ハッシュ値
        return hmacSHA1(key: md5Key, data: message)
    }
    
    /// MD5ハッシュ
    private func md5Hash(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBytes { buffer in
            CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
    
    /// HMAC-SHA1
    private func hmacSHA1(key: Data, data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: 20)
        key.withUnsafeBytes { keyBuffer in
            data.withUnsafeBytes { dataBuffer in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyBuffer.baseAddress, key.count,
                    dataBuffer.baseAddress, data.count,
                    &digest
                )
            }
        }
        return Data(digest)
    }
    
    // MARK: - Private Methods - Response Parsing
    
    /// 401/438エラーレスポンスからnonce/realm/errorCodeを抽出
    /// ★ B-2+: ERROR-CODE属性（0x0009）の解析を追加
    private var lastErrorCode: Int = 0
    private var lastErrorMessage: String = ""
    
    private func parseErrorResponse(_ data: Data) {
        guard data.count >= 20 else { return }
        
        let msgType = UInt16(data[0]) << 8 | UInt16(data[1])
        let messageLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        var offset = 20
        
        Logger.turn("📋 エラーレスポンス解析: type=0x\(String(format: "%04X", msgType)), len=\(messageLength)")
        
        while offset < min(20 + messageLength, data.count) {
            guard offset + 4 <= data.count else { break }
            
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            offset += 4
            
            guard offset + attrLength <= data.count else { break }
            
            if attrType == TURNAttributeType.nonce.rawValue {
                serverNonce = String(data: data[offset..<(offset + attrLength)], encoding: .utf8)
                Logger.turn("  📝 Nonce: \(serverNonce ?? "nil")")
            } else if attrType == TURNAttributeType.realm.rawValue {
                serverRealm = String(data: data[offset..<(offset + attrLength)], encoding: .utf8)
                Logger.turn("  📝 Realm: \(serverRealm ?? "nil")")
            } else if attrType == TURNAttributeType.errorCode.rawValue {
                // ★ ERROR-CODE属性解析 (RFC 5389 Section 15.6)
                // [2バイト: reserved] [1バイト: class(hundreds)] [1バイト: number(0-99)]
                if attrLength >= 4 {
                    let errorClass = Int(data[offset + 2])
                    let errorNumber = Int(data[offset + 3])
                    lastErrorCode = errorClass * 100 + errorNumber
                    if attrLength > 4 {
                        lastErrorMessage = String(data: data[(offset + 4)..<(offset + attrLength)], encoding: .utf8) ?? ""
                    }
                    Logger.turn("  ❌ Error Code: \(lastErrorCode) (\(errorCodeDescription(lastErrorCode)))")
                    if !lastErrorMessage.isEmpty {
                        Logger.turn("  📝 Error Message: \(lastErrorMessage)")
                    }
                }
            } else {
                Logger.turn("  Attr: type=0x\(String(format: "%04X", attrType)), len=\(attrLength)")
            }
            
            offset += attrLength
            let padding = (4 - (attrLength % 4)) % 4
            offset += padding
        }
    }
    
    /// エラーコードの説明
    private func errorCodeDescription(_ code: Int) -> String {
        switch code {
        case 401: return "Unauthorized"
        case 437: return "Allocation Mismatch"
        case 438: return "Stale Nonce"
        case 441: return "Wrong Credentials"
        case 486: return "Allocation Quota Reached"
        case 508: return "Insufficient Capacity"
        default: return "Unknown"
        }
    }
    
    /// Allocateレスポンス解析
    private func parseAllocateResponse(_ data: Data) throws -> TURNAllocateResult {
        guard data.count >= 20 else {
            throw TURNError.invalidResponse
        }
        
        let msgType = UInt16(data[0]) << 8 | UInt16(data[1])
        
        if msgType == TURNMessageType.allocateErrorResponse.rawValue {
            // ★ B-2+: エラーコード詳細をログしてから解析
            lastErrorCode = 0
            parseErrorResponse(data)
            Logger.turn("❌ Allocateエラー: code=\(lastErrorCode) (\(errorCodeDescription(lastErrorCode)))")
            throw TURNError.allocateFailed
        }
        
        guard msgType == TURNMessageType.allocateResponse.rawValue else {
            Logger.turn("❌ 予期しないレスポンス: 0x\(String(format: "%04X", msgType))")
            throw TURNError.invalidResponse
        }
        
        let messageLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        var offset = 20
        
        var relayIP: String?
        var relayPort: UInt16?
        var mappedIP: String?
        var mappedPort: UInt16?
        var lifetime: UInt32 = 600
        
        while offset < min(20 + messageLength, data.count) {
            guard offset + 4 <= data.count else { break }
            
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            offset += 4
            
            guard offset + attrLength <= data.count else { break }
            
            switch attrType {
            case TURNAttributeType.xorRelayedAddress.rawValue:
                if let (ip, port) = parseXorAddress(data: data, offset: offset, length: attrLength) {
                    relayIP = ip
                    relayPort = port
                }
                
            case TURNAttributeType.xorMappedAddress.rawValue:
                if let (ip, port) = parseXorAddress(data: data, offset: offset, length: attrLength) {
                    mappedIP = ip
                    mappedPort = port
                }
                
            case TURNAttributeType.lifetime.rawValue:
                if attrLength >= 4 {
                    lifetime = UInt32(data[offset]) << 24 |
                               UInt32(data[offset + 1]) << 16 |
                               UInt32(data[offset + 2]) << 8 |
                               UInt32(data[offset + 3])
                }
                
            default:
                break
            }
            
            offset += attrLength
            let padding = (4 - (attrLength % 4)) % 4
            offset += padding
        }
        
        guard let rIP = relayIP, let rPort = relayPort else {
            throw TURNError.noRelayAddress
        }
        
        return TURNAllocateResult(
            relayIP: rIP,
            relayPort: rPort,
            mappedIP: mappedIP ?? "",
            mappedPort: mappedPort ?? 0,
            lifetime: lifetime
        )
    }
    
    /// XORアドレス解析
    private func parseXorAddress(data: Data, offset: Int, length: Int) -> (String, UInt16)? {
        guard length >= 8 else { return nil }
        
        let family = data[offset + 1]
        
        let xorPort = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
        let port = xorPort ^ UInt16(turnMagicCookie >> 16)
        
        if family == 0x01 {
            // IPv4
            let xorIP = UInt32(data[offset + 4]) << 24 |
                         UInt32(data[offset + 5]) << 16 |
                         UInt32(data[offset + 6]) << 8 |
                         UInt32(data[offset + 7])
            let ip = xorIP ^ turnMagicCookie
            let ipString = "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
            return (ipString, port)
        }
        
        return nil
    }
    
    // MARK: - Private Methods - Connection Helpers
    
    /// コネクション接続待機
    private func waitForConnection(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var hasResumed = false
            
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !hasResumed {
                    hasResumed = true
                    conn.cancel()
                    continuation.resume(throwing: TURNError.timeout)
                }
            }
            
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !hasResumed {
                        hasResumed = true
                        timeoutTask.cancel()
                        continuation.resume()
                    }
                case .failed(let error):
                    if !hasResumed {
                        hasResumed = true
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            
            conn.start(queue: .global())
        }
    }
    
    /// データ送信
    private func send(_ conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    /// データ送受信（リクエスト→レスポンス）
    private func sendAndReceive(_ conn: NWConnection, data: Data) async throws -> Data {
        // ★ B-2: 接続状態を確認
        guard conn.state == .ready else {
            Logger.turn("❌ sendAndReceive: 接続が.readyでない (state=\(conn.state))", level: .error)
            throw TURNError.notAllocated
        }
        
        // ★ 受信ループ稼働中は pending continuation 方式を使用
        if receiveLoopRunning {
            return try await sendAndReceiveViaPending(conn, data: data)
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            var hasResumed = false
            
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(throwing: TURNError.timeout)
                }
            }
            
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    if !hasResumed {
                        hasResumed = true
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }
                    return
                }
                
                // レスポンス受信
                conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, _, error in
                    if hasResumed { return }
                    hasResumed = true
                    timeoutTask.cancel()
                    
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: TURNError.noResponse)
                    }
                }
            })
        }
    }
    
    /// ★ 受信ループ稼働中のsendAndReceive（pending continuation経由）
    private func sendAndReceiveViaPending(_ conn: NWConnection, data: Data) async throws -> Data {
        // 送信
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        
        // レスポンスを受信ループ経由で待機
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            self.pendingResponseContinuation = continuation
            
            // タイムアウト
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pending = self.pendingResponseContinuation {
                    self.pendingResponseContinuation = nil
                    pending.resume(throwing: TURNError.timeout)
                }
            }
        }
    }
    
    /// Allocationリフレッシュループ
    private func startRefreshLoop(lifetime: UInt32) {
        refreshTask?.cancel()
        
        // lifetime の 80% のタイミングでリフレッシュ
        let refreshInterval = TimeInterval(lifetime) * 0.8
        
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
                
                guard !Task.isCancelled, let conn = connection else { break }
                
                let request = createRefreshRequest(lifetime: lifetime)
                do {
                    let response = try await sendAndReceive(conn, data: request)
                    let msgType = UInt16(response[0]) << 8 | UInt16(response[1])
                    if msgType == TURNMessageType.refreshResponse.rawValue {
                        Logger.turn("💓 TURN Refresh成功", level: .debug)
                    }
                } catch {
                    Logger.turn("⚠️ TURN Refresh失敗: \(error.localizedDescription)", level: .warning)
                }
            }
        }
    }
    
    /// データ受信ループ（Data Indication / ChannelData）
    private func startReceiveLoop(_ conn: NWConnection) {
        receiveLoopRunning = true
        Task {
            while !Task.isCancelled {
                do {
                    let data = try await receiveOne(conn)
                    processIncoming(data)
                } catch {
                    if !Task.isCancelled {
                        Logger.turn("受信エラー: \(error.localizedDescription)", level: .debug)
                    }
                    break
                }
            }
            receiveLoopRunning = false
        }
    }
    
    /// 1パケット受信
    private func receiveOne(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: TURNError.noResponse)
                }
            }
        }
    }
    
    /// 受信データの処理
    private func processIncoming(_ data: Data) {
        guard data.count >= 4 else { return }
        
        let firstTwo = UInt16(data[0]) << 8 | UInt16(data[1])
        
        // ★ STUNレスポンスはpending continuationに転送
        if isSTUNResponse(firstTwo) {
            if let pending = pendingResponseContinuation {
                pendingResponseContinuation = nil
                pending.resume(returning: data)
                return
            }
            return
        }
        
        if firstTwo >= 0x4000 && firstTwo <= 0x7FFF {
            // ChannelData
            let length = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
            if data.count >= 4 + length {
                let payload = data[4..<(4 + length)]
                
                // ★ Phase 0 診断: 受信パケットタイプを判定
                if let firstByte = payload.first {
                    if firstByte == 0x04 {
                        // キーフレームチャンク到着！
                        Logger.turn("🔑 TURN受信: キーフレームチャンク到着! size=\(length)bytes")
                    }
                }
                
                onDataReceived?(Data(payload))
            }
        } else if firstTwo == TURNMessageType.dataIndication.rawValue {
            // Data Indication - DATA属性からペイロードを抽出
            extractDataFromIndication(data)
        }
    }
    
    /// STUNレスポンスタイプか判定
    private func isSTUNResponse(_ msgType: UInt16) -> Bool {
        let stunResponses: [UInt16] = [
            TURNMessageType.createPermissionResponse.rawValue,
            TURNMessageType.channelBindResponse.rawValue,
            TURNMessageType.refreshResponse.rawValue,
            TURNMessageType.allocateResponse.rawValue,
            TURNMessageType.allocateErrorResponse.rawValue,
            0x0118, // CreatePermission Error Response
            0x0119, // ChannelBind Error Response
        ]
        return stunResponses.contains(msgType)
    }
    
    /// Data IndicationからDATA属性を抽出
    private func extractDataFromIndication(_ data: Data) {
        guard data.count >= 20 else { return }
        
        let messageLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        var offset = 20
        
        while offset < min(20 + messageLength, data.count) {
            guard offset + 4 <= data.count else { break }
            
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            offset += 4
            
            guard offset + attrLength <= data.count else { break }
            
            if attrType == TURNAttributeType.data.rawValue {
                let payload = data[offset..<(offset + attrLength)]
                onDataReceived?(Data(payload))
                return
            }
            
            offset += attrLength
            let padding = (4 - (attrLength % 4)) % 4
            offset += padding
        }
    }
}

// MARK: - TURN Errors

public enum TURNError: Error, LocalizedError {
    case timeout
    case noResponse
    case invalidResponse
    case authenticationFailed
    case allocateFailed
    case noRelayAddress
    case notAllocated
    case permissionDenied
    case channelBindFailed
    case notConfigured
    
    public var errorDescription: String? {
        switch self {
        case .timeout: return "TURNサーバーがタイムアウトしました"
        case .noResponse: return "TURNサーバーからの応答がありません"
        case .invalidResponse: return "TURNレスポンスが不正です"
        case .authenticationFailed: return "TURN認証に失敗しました"
        case .allocateFailed: return "TURN Allocateに失敗しました"
        case .noRelayAddress: return "リレーアドレスが取得できません"
        case .notAllocated: return "TURN Allocationがありません"
        case .permissionDenied: return "TURN Permissionが拒否されました"
        case .channelBindFailed: return "TURN ChannelBindに失敗しました"
        case .notConfigured: return "TURNサーバーが設定されていません"
        }
    }
}

// MARK: - Logger Extension

extension Logger {
    static func turn(_ message: String, level: LogLevel = .info) {
        shared.log(message, level: level, category: .network)
    }
}
