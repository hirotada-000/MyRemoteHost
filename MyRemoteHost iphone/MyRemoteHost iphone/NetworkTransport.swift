//
//  NetworkTransport.swift
//  MyRemoteHost iphone
//
//  ネットワーク抽象化レイヤー
//  Phase 0: 商用リリース向け基盤整備
//
//  このプロトコルにより、以下の切り替えが可能:
//  - 直接UDP接続（現在）
//  - WebRTC接続（将来）
//  - TURN/リレー接続（将来）
//

import Foundation

// MARK: - Shared Types

/// 共通パケットタイプ
/// NetworkSenderとNetworkReceiverで共有
public enum NetworkPacketType: UInt8, Sendable {
    case vps = 0x00       // HEVC VPS
    case sps = 0x01
    case pps = 0x02
    case videoFrame = 0x03
    case keyFrame = 0x04
    case jpegFrame = 0x05  // Deprecated
    case pngFrame = 0x06   // PNG 静止画フレーム
    case fecParity = 0x07  // FECパリティブロック
    case metadata = 0x08   // Retinaメタデータ
}

/// 共通接続状態
public enum NetworkConnectionState: Sendable {
    case idle
    case connecting
    case listening
    case ready
    case receiving
    case failed(Error)
    case disconnected
    
    /// 接続が確立されているかどうか
    var isConnected: Bool {
        switch self {
        case .ready, .receiving:
            return true
        default:
            return false
        }
    }
    
    /// 接続試行中かどうか
    var isConnecting: Bool {
        switch self {
        case .connecting, .listening:
            return true
        default:
            return false
        }
    }
}

// MARK: - Transport Protocol

/// ネットワークトランスポート抽象化プロトコル
/// 将来のWebRTC/TURN対応のための共通インターフェース
public protocol NetworkTransportProtocol: AnyObject {
    
    /// 現在の接続状態
    var connectionState: NetworkConnectionState { get }
    
    /// 接続が確立されているかどうか
    var isConnected: Bool { get }
    
    /// 接続を開始
    func connect() async throws
    
    /// 接続を終了
    func disconnect()
    
    /// データを送信
    func send(_ data: Data, type: NetworkPacketType) async throws
    
    /// 接続状態変更通知
    var onStateChange: ((NetworkConnectionState) -> Void)? { get set }
    
    /// データ受信通知
    var onDataReceived: ((Data, NetworkPacketType) -> Void)? { get set }
}

// MARK: - Connection Info

/// 接続先情報
public struct NetworkEndpoint: Sendable, Equatable, Hashable {
    public let host: String
    public let port: UInt16
    
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
    
    public var description: String {
        "\(host):\(port)"
    }
}

/// クライアント情報（Host側で使用）
public class NetworkClientInfo {
    public let endpoint: NetworkEndpoint
    public var lastHeartbeat: Date
    public var userRecordID: String?
    
    public init(endpoint: NetworkEndpoint, userRecordID: String? = nil) {
        self.endpoint = endpoint
        self.lastHeartbeat = Date()
        self.userRecordID = userRecordID
    }
    
    /// ハートビート更新
    public func updateHeartbeat() {
        lastHeartbeat = Date()
    }
    
    /// タイムアウトチェック
    public func isTimedOut(timeout: TimeInterval = 10.0) -> Bool {
        Date().timeIntervalSince(lastHeartbeat) > timeout
    }
}

// MARK: - Transport Configuration

/// トランスポート設定
public struct NetworkTransportConfiguration: Sendable {
    /// 最大パケットサイズ（MTU対応）
    public let maxPacketSize: Int
    
    /// ハートビート間隔（秒）
    public let heartbeatInterval: TimeInterval
    
    /// 接続タイムアウト（秒）
    public let connectionTimeout: TimeInterval
    
    /// クライアントタイムアウト（秒）
    public let clientTimeout: TimeInterval
    
    /// FEC有効化
    public let fecEnabled: Bool
    
    /// 暗号化有効化
    public let encryptionEnabled: Bool
    
    /// デフォルト設定
    public static let `default` = NetworkTransportConfiguration(
        maxPacketSize: 1400,
        heartbeatInterval: 1.0,
        connectionTimeout: 10.0,
        clientTimeout: 10.0,
        fecEnabled: false,
        encryptionEnabled: false
    )
    
    /// 高信頼性設定（商用向け）
    public static let production = NetworkTransportConfiguration(
        maxPacketSize: 1400,
        heartbeatInterval: 1.0,
        connectionTimeout: 15.0,
        clientTimeout: 15.0,
        fecEnabled: true,
        encryptionEnabled: true
    )
    
    public init(
        maxPacketSize: Int,
        heartbeatInterval: TimeInterval,
        connectionTimeout: TimeInterval,
        clientTimeout: TimeInterval,
        fecEnabled: Bool,
        encryptionEnabled: Bool
    ) {
        self.maxPacketSize = maxPacketSize
        self.heartbeatInterval = heartbeatInterval
        self.connectionTimeout = connectionTimeout
        self.clientTimeout = clientTimeout
        self.fecEnabled = fecEnabled
        self.encryptionEnabled = encryptionEnabled
    }
}

// MARK: - Transport Factory

/// トランスポート種別
public enum NetworkTransportType: Sendable {
    /// 直接UDP接続（LAN内専用）
    case directUDP
    
    /// WebRTC接続（NAT越え対応）将来実装
    case webRTC
    
    /// TURNリレー接続（フォールバック）将来実装
    case turnRelay
}

/// トランスポートファクトリー
/// 将来的に異なるトランスポート実装を切り替え可能にする
public enum NetworkTransportFactory {
    
    /// 現在利用可能なトランスポート種別
    public static var availableTransports: [NetworkTransportType] {
        // Phase 0: 直接UDPのみ
        // Phase 2以降: WebRTC, TURNリレーを追加
        return [.directUDP]
    }
    
    /// 最適なトランスポートを自動選択
    /// Phase 2以降: ネットワーク環境に応じて自動選択
    public static func recommendedTransport() -> NetworkTransportType {
        // 現在は直接UDP固定
        // 将来: ICE候補に基づいて選択
        return .directUDP
    }
}
