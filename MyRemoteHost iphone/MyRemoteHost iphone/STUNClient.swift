//
//  STUNClient.swift
//  MyRemoteHost
//
//  STUN (Session Traversal Utilities for NAT) クライアント
//  Google STUNサーバーを使用して公開IP/ポートを取得
//
//  Phase 2: NAT Traversal
//

import Foundation
import Network

// MARK: - STUN Constants

/// STUNメッセージタイプ
private enum STUNMessageType: UInt16 {
    case bindingRequest = 0x0001
    case bindingResponse = 0x0101
    case bindingErrorResponse = 0x0111
}

/// STUN属性タイプ
private enum STUNAttributeType: UInt16 {
    case mappedAddress = 0x0001
    case xorMappedAddress = 0x0020
    case errorCode = 0x0009
}

/// STUNマジッククッキー（RFC 5389）
private let stunMagicCookie: UInt32 = 0x2112A442

// MARK: - STUN Result

/// STUN結果（公開IP/ポート）
public struct STUNResult: Sendable {
    public let publicIP: String
    public let publicPort: UInt16
    public let natType: NATType
    
    public enum NATType: String, Sendable {
        case fullCone = "Full Cone"
        case restrictedCone = "Restricted Cone"
        case portRestrictedCone = "Port Restricted Cone"
        case symmetric = "Symmetric"
        case unknown = "Unknown"
    }
}

// MARK: - STUN Client

/// STUNクライアント
/// Google STUNサーバーを使用してNAT越えに必要な公開IP/ポートを取得
public actor STUNClient {
    
    // MARK: - Properties
    
    /// Google STUNサーバー一覧（無料）
    private let stunServers = [
        ("stun.l.google.com", UInt16(19302)),
        ("stun1.l.google.com", UInt16(19302)),
        ("stun2.l.google.com", UInt16(19302)),
        ("stun3.l.google.com", UInt16(19302)),
        ("stun4.l.google.com", UInt16(19302))
    ]
    
    /// タイムアウト（秒）
    private let timeout: TimeInterval = 5.0
    
    /// 現在のトランザクションID
    private var currentTransactionID: Data?
    
    // MARK: - Public Methods
    
    /// 公開IP/ポートを取得
    public func discoverPublicEndpoint() async throws -> STUNResult {
        // 複数のSTUNサーバーを試行
        var lastError: Error?
        
        for (host, port) in stunServers {
            do {
                let result = try await querySTUNServer(host: host, port: port)
                Logger.stun("✅ 公開IP取得成功: \(result.publicIP):\(result.publicPort)")
                return result
            } catch {
                lastError = error
                Logger.stun("\(host) 失敗: \(error.localizedDescription)", level: .warning)
            }
        }
        
        throw lastError ?? STUNError.allServersFailed
    }
    
    // MARK: - Private Methods
    
    /// 単一のSTUNサーバーにクエリ
    private func querySTUNServer(host: String, port: UInt16) async throws -> STUNResult {
        // UDPソケット作成
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .udp)
        
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            
            // タイムアウト
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !hasResumed {
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(throwing: STUNError.timeout)
                }
            }
            
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                
                switch state {
                case .ready:
                    // Binding Request送信
                    Task {
                        let request = await self.createBindingRequest()
                        connection.send(content: request, completion: .contentProcessed { error in
                            if let error = error {
                                if !hasResumed {
                                    hasResumed = true
                                    timeoutTask.cancel()
                                    continuation.resume(throwing: error)
                                }
                            }
                        })
                        
                        // レスポンス受信
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                            timeoutTask.cancel()
                            
                            if hasResumed { return }
                            hasResumed = true
                            
                            if let error = error {
                                connection.cancel()
                                continuation.resume(throwing: error)
                                return
                            }
                            
                            guard let data = data else {
                                connection.cancel()
                                continuation.resume(throwing: STUNError.noResponse)
                                return
                            }
                            
                            Task {
                                do {
                                    let result = try await self.parseBindingResponse(data)
                                    connection.cancel()
                                    continuation.resume(returning: result)
                                } catch {
                                    connection.cancel()
                                    continuation.resume(throwing: error)
                                }
                            }
                        }
                    }
                    
                case .failed(let error):
                    if !hasResumed {
                        hasResumed = true
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }
                    
                case .cancelled:
                    if !hasResumed {
                        hasResumed = true
                        timeoutTask.cancel()
                        continuation.resume(throwing: STUNError.cancelled)
                    }
                    
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
        }
    }
    
    /// STUN Binding Request作成
    private func createBindingRequest() -> Data {
        var data = Data()
        
        // Message Type: Binding Request (0x0001)
        var messageType = STUNMessageType.bindingRequest.rawValue.bigEndian
        data.append(Data(bytes: &messageType, count: 2))
        
        // Message Length: 0 (属性なし)
        var messageLength: UInt16 = 0
        data.append(Data(bytes: &messageLength, count: 2))
        
        // Magic Cookie (RFC 5389)
        var magicCookie = stunMagicCookie.bigEndian
        data.append(Data(bytes: &magicCookie, count: 4))
        
        // Transaction ID (96 bits = 12 bytes)
        var transactionID = Data(count: 12)
        _ = transactionID.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }
        currentTransactionID = transactionID
        data.append(transactionID)
        
        return data
    }
    
    /// STUN Binding Response解析
    private func parseBindingResponse(_ data: Data) throws -> STUNResult {
        guard data.count >= 20 else {
            throw STUNError.invalidResponse
        }
        
        // Message Type確認
        let messageType = UInt16(data[0]) << 8 | UInt16(data[1])
        guard messageType == STUNMessageType.bindingResponse.rawValue else {
            if messageType == STUNMessageType.bindingErrorResponse.rawValue {
                throw STUNError.bindingError
            }
            throw STUNError.invalidResponse
        }
        
        // Message Length
        let messageLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        guard data.count >= 20 + messageLength else {
            throw STUNError.invalidResponse
        }
        
        // 属性を解析
        var offset = 20
        var publicIP: String?
        var publicPort: UInt16?
        
        while offset < 20 + messageLength {
            guard offset + 4 <= data.count else { break }
            
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            offset += 4
            
            guard offset + attrLength <= data.count else { break }
            
            if attrType == STUNAttributeType.xorMappedAddress.rawValue {
                // XOR-MAPPED-ADDRESS解析
                if let result = parseXorMappedAddress(data: data, offset: offset, length: attrLength) {
                    publicIP = result.0
                    publicPort = result.1
                    break
                }
            } else if attrType == STUNAttributeType.mappedAddress.rawValue {
                // MAPPED-ADDRESS（フォールバック）
                if let result = parseMappedAddress(data: data, offset: offset, length: attrLength) {
                    publicIP = result.0
                    publicPort = result.1
                }
            }
            
            // 4バイト境界にパディング
            offset += attrLength
            let padding = (4 - (attrLength % 4)) % 4
            offset += padding
        }
        
        guard let ip = publicIP, let port = publicPort else {
            throw STUNError.noMappedAddress
        }
        
        return STUNResult(publicIP: ip, publicPort: port, natType: .unknown)
    }
    
    /// XOR-MAPPED-ADDRESS解析
    private func parseXorMappedAddress(data: Data, offset: Int, length: Int) -> (String, UInt16)? {
        guard length >= 8 else { return nil }
        
        // Family (1バイト目はパディング)
        let family = data[offset + 1]
        
        // Port (XOR with magic cookie上位16ビット)
        let xorPort = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
        let port = xorPort ^ UInt16(stunMagicCookie >> 16)
        
        if family == 0x01 {
            // IPv4
            let xorIP = UInt32(data[offset + 4]) << 24 |
                        UInt32(data[offset + 5]) << 16 |
                        UInt32(data[offset + 6]) << 8 |
                        UInt32(data[offset + 7])
            let ip = xorIP ^ stunMagicCookie
            let ipString = "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
            return (ipString, port)
        }
        
        return nil
    }
    
    /// MAPPED-ADDRESS解析
    private func parseMappedAddress(data: Data, offset: Int, length: Int) -> (String, UInt16)? {
        guard length >= 8 else { return nil }
        
        let family = data[offset + 1]
        let port = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
        
        if family == 0x01 {
            // IPv4
            let ip = "\(data[offset + 4]).\(data[offset + 5]).\(data[offset + 6]).\(data[offset + 7])"
            return (ip, port)
        }
        
        return nil
    }
}

// MARK: - STUN Errors

public enum STUNError: Error, LocalizedError {
    case timeout
    case noResponse
    case invalidResponse
    case bindingError
    case noMappedAddress
    case allServersFailed
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .timeout: return "STUNサーバーがタイムアウトしました"
        case .noResponse: return "STUNサーバーからの応答がありません"
        case .invalidResponse: return "STUNレスポンスが不正です"
        case .bindingError: return "STUNバインディングエラー"
        case .noMappedAddress: return "マップされたアドレスが見つかりません"
        case .allServersFailed: return "すべてのSTUNサーバーに接続できませんでした"
        case .cancelled: return "STUNリクエストがキャンセルされました"
        }
    }
}
