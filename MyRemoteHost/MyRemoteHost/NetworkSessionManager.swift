//
//  NetworkSessionManager.swift
//  MyRemoteHost
//
//  ネットワークセッションのライフサイクルを管理するマネージャ
//  - NetworkSender / InputReceiver の保持と制御
//  - CloudKit / STUN / Signaling の連携
//  - クライアント接続状態の管理
//

import Foundation
import Network
import Combine

@MainActor
class NetworkSessionManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// リスニング中かどうか
    @Published var isListening: Bool = false
    
    /// 接続中のクライアント数
    @Published var connectedClients: Int = 0
    
    /// ネットワーク品質モニター
    let qualityMonitor = NetworkQualityMonitor()
    
    /// ネットワークエラー
    @Published var error: String?
    
    // MARK: - Components
    
    /// 映像送信 (NetworkSender)
    let sender: NetworkSender
    
    /// 入力受信 (InputReceiver)
    let inputReceiver: InputReceiver
    
    // MARK: - Callbacks / Delegates
    
    /// クライアント接続通知 (key)
    var onClientConnected: ((String) -> Void)?
    
    /// クライアント切断通知 (key)
    var onClientDisconnected: ((String) -> Void)?
    
    /// 認証要求通知 (host, port, userRecordID)
    var onAuthRequest: ((String, UInt16, String?) -> Void)?
    
    /// ★ Phase 3: キーフレーム要求通知
    var onKeyFrameRequest: (() -> Void)?
    
    // MARK: - Initialization
    
    init() {
        // ★ ポート不一致修正: CloudKit登録(5000)とListen(5100)が不一致だったため修正
        // NetworkTransportConfiguration.default.videoPort (5000) に統一
        self.sender = NetworkSender(port: UInt16(NetworkTransportConfiguration.default.videoPort))
        self.inputReceiver = InputReceiver(port: NetworkTransportConfiguration.default.inputPort)
        
        setupDelegates()
    }
    
    private func setupDelegates() {
        sender.delegate = self
        // InputReceiverのデリゲートはCaptureViewModelが設定する（Zoom制御などがあるため）
        // あるいはInputReceiverDelegateもここで受けて、ViewModelに通知するか？
        // 現状はViewModelがZoomロジックを持っているので、ViewModelがInputReceiverDelegateになるのが自然。
        // -> senderはここでラップするが、inputReceiverは公開してViewModelに触らせる。
    }
    
    // MARK: - Session Control
    
    /// ネットワークセッション開始 (Listening + CloudKit登録)
    func startSession() async {
        do {
            print("[NetworkSessionManager] 🚀 セッション開始中...")
            try sender.startListening()
            try inputReceiver.startListening()
            qualityMonitor.startMonitoring()
            
            isListening = true
            error = nil
            
            print("[NetworkSessionManager] ✅ リスニング開始成功")
            
            // CloudKitに登録
            await registerToCloudKit()
            
        } catch {
            print("[NetworkSessionManager] ❌ セッション開始失敗: \(error)")
            self.error = "ネットワーク開始失敗: \(error.localizedDescription)"
            isListening = false
        }
    }
    
    /// ネットワークセッション停止
    func stopSession() {
        print("[NetworkSessionManager] 🛑 セッション停止")
        
        // CloudKitから登録抹消
        Task {
            await CloudKitSignalingManager.shared.unregisterHost()
        }
        
        sender.stop()
        inputReceiver.stop()
        qualityMonitor.stopMonitoring()
        
        isListening = false
        connectedClients = 0
    }
    
    // MARK: - Signaling / CloudKit
    
    private func registerToCloudKit() async {
        guard let localIP = CloudKitSignalingManager.getLocalIPAddress() else {
            print("[NetworkSessionManager] ⚠️ ローカルIP取得失敗: CloudKit登録スキップ")
            return
        }
        
        let deviceName = Host.current().localizedName ?? "Mac"
        
        do {
            // 1. ローカルIP登録
            try await CloudKitSignalingManager.shared.registerHost(
                deviceName: deviceName,
                localIP: localIP,
                localPort: Int(NetworkTransportConfiguration.default.videoPort)
            )
            print("[NetworkSessionManager] ☁️ CloudKit登録完了: \(deviceName)")
            
            // 2. STUNで公開エンドポイント取得 (Fire & Forget)
            await discoverPublicEndpoint()
            
        } catch {
            print("[NetworkSessionManager] ⚠️ CloudKit登録失敗: \(error.localizedDescription)")
            // ローカル接続は継続
        }
    }
    
    private func discoverPublicEndpoint() async {
        do {
            let p2pManager = P2PConnectionManager()
            let candidates = try await p2pManager.gatherCandidates(localPort: Int(NetworkTransportConfiguration.default.videoPort))
            
            try await CloudKitSignalingManager.shared.saveICECandidates(candidates)
            
            if let srflxCandidate = candidates.first(where: { $0.type == .serverReflexive }) {
                try await CloudKitSignalingManager.shared.updatePublicEndpoint(
                    publicIP: srflxCandidate.ip,
                    publicPort: srflxCandidate.port
                )
                print("[NetworkSessionManager] 🌐 STUN完了: \(srflxCandidate.ip):\(srflxCandidate.port)")
            }
        } catch {
            print("[NetworkSessionManager] ⚠️ STUN失敗: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Pass-through Methods for Video Transmission
    
    /// 認証許可 (AuthenticationManagerから呼ばれる)
    func approveClient(host: String, port: UInt16) {
        sender.approveClient(host: host, port: port)
    }
    
    func denyClient(host: String, port: UInt16) {
        sender.denyClient(host: host, port: port)
    }
    
    func sendVPS(_ data: Data) { sender.sendVPS(data) }
    func sendSPS(_ data: Data) { sender.sendSPS(data) }
    func sendPPS(_ data: Data) { sender.sendPPS(data) }
    func sendVideoFrame(_ data: Data, isKeyFrame: Bool, timestamp: UInt64) {
        sender.sendVideoFrame(data, isKeyFrame: isKeyFrame, timestamp: timestamp)
    }
}

// MARK: - NetworkSenderDelegate
extension NetworkSessionManager: NetworkSenderDelegate {
    nonisolated func networkSender(_ sender: NetworkSender, didChangeState state: NetworkSender.ConnectionState) {
        Task { @MainActor in
            switch state {
            case .idle, .failed:
                self.isListening = false
            case .listening, .ready:
                self.isListening = true
            case .cancelled:
                self.isListening = false
            }
            
            if case .failed(let err) = state {
                // ★ ポート競合検出: 旧プロセスがポートを占有している場合
                let errorDesc = err.localizedDescription
                if errorDesc.contains("48") || errorDesc.contains("Address already in use") {
                    self.error = "ポート競合: 旧MyRemoteHostプロセスが実行中です。アクティビティモニタで「MyRemoteHost」を終了してから再起動してください"
                } else {
                    self.error = "ネットワークエラー: \(errorDesc)"
                }
            }
        }
    }
    
    nonisolated func networkSender(_ sender: NetworkSender, didConnectToClient key: String) {
        Task { @MainActor in
            self.connectedClients += 1
            self.onClientConnected?(key)
        }
    }
    
    nonisolated func networkSender(_ sender: NetworkSender, didDisconnectClient key: String, remainingClients: Int) {
        Task { @MainActor in
            self.connectedClients = remainingClients
            self.onClientDisconnected?(key)
        }
    }
    
    nonisolated func networkSender(_ sender: NetworkSender, didFailWithError error: Error) {
        Task { @MainActor in
            self.error = "送受信エラー: \(error.localizedDescription)"
        }
    }
    
    nonisolated func networkSender(_ sender: NetworkSender, didReceiveAuthRequest host: String, port: UInt16, userRecordID: String?) {
        Task { @MainActor in
            self.onAuthRequest?(host, port, userRecordID)
        }
    }
    
    /// ★ Phase 3: キーフレーム要求受信
    nonisolated func networkSenderDidReceiveKeyFrameRequest(_ sender: NetworkSender) {
        Task { @MainActor in
            self.onKeyFrameRequest?()
        }
    }
}
