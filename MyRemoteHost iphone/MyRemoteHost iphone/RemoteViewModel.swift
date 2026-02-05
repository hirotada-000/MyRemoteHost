//
//  RemoteViewModel.swift
//  MyRemoteClient
//
//  リモート接続とデコードを管理するViewModel
//

import Foundation
import CoreMedia
import CoreVideo
import Combine
import UIKit

/// 保存済みホスト情報
struct SavedHost: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let address: String
    let port: UInt16
    var lastConnected: Date
    
    init(name: String? = nil, address: String, port: UInt16) {
        self.id = UUID()
        self.name = name ?? address
        self.address = address
        self.port = port
        self.lastConnected = Date()
    }
}

/// リモートデスクトップクライアントのViewModel
@MainActor
class RemoteViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var hostAddress: String = ""
    @Published var port: String = "5000"
    @Published var connectionError: String?
    @Published var frameRate: Double = 0
    @Published var decodedFrameCount: Int = 0
    
    /// 受信したPNGデータ（静止画モード用）
    @Published var currentPNGData: Data?
    
    /// 認証待機中
    @Published var isWaitingForAuth = false
    
    /// 認証拒否された
    @Published var authDenied = false
    
    /// 保存済みホスト一覧
    @Published var savedHosts: [SavedHost] = []
    
    /// ★ Phase 1: CloudKitで発見したホスト一覧
    @Published var discoveredHosts: [HostDeviceRecord] = []
    
    /// ★ Phase 1: ホスト発見中
    @Published var isDiscoveringHosts = false
    
    // MARK: - Components
    
    let networkReceiver = NetworkReceiver()
    let decoder = VideoDecoder()
    let previewCoordinator = PreviewViewCoordinator()
    let inputSender = InputSender()
    
    // MARK: - Private Properties
    
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameCount = 0
    private var pngReceiveCount = 0  // ★ PNG受信カウンター
    private var fpsTimer: Timer?
    private let savedHostsKey = "savedHosts"
    
    // ★ 接続診断用プロパティ
    private var connectionTimeoutTimer: Timer?
    private var connectionRetryCount = 0
    private let maxRetryCount = 3
    private let connectionTimeout: TimeInterval = 5.0
    
    // MARK: - Initialization
    
    init() {
        setupDelegates()
        loadSavedHosts()
        networkReceiver.prefetchUserRecordID()  // ★ Phase 3: userRecordIDを事前取得
    }
    
    // MARK: - Zoom State
    
    /// 現在のズームスケール
    @Published var zoomScale: CGFloat = 1.0
    
    /// ズーム時の表示領域（正規化座標 0〜1）
    @Published var visibleRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    
    /// ズーム状態を更新（ZoomableScrollViewから呼ばれる）
    func updateZoomState(scale: CGFloat, visibleRect: CGRect) {
        self.zoomScale = scale
        self.visibleRect = visibleRect
        
        // ズーム倍率1.5倍以上の時、Mac側にROIリクエストを送信
        if scale >= 1.5 {
            inputSender.sendZoomRequest(isZooming: true, visibleRect: visibleRect, zoomScale: scale)
            // ★ ログ抑制: 0.5秒間隔でのみ出力
            logZoomStateIfNeeded(scale: scale, rect: visibleRect)
        } else if scale < 1.1 {
            // ほぼ1倍に戻ったらズーム解除を通知
            inputSender.sendZoomRequest(isZooming: false, visibleRect: visibleRect, zoomScale: scale)
        }
    }
    
    /// ★ ログ抑制用: 最後にログを出力した時間
    private static var lastZoomLogTime: Date = .distantPast
    
    private func logZoomStateIfNeeded(scale: CGFloat, rect: CGRect) {
        let now = Date()
        if now.timeIntervalSince(Self.lastZoomLogTime) > 0.5 {
            Self.lastZoomLogTime = now
            // print("[RemoteViewModel] 🔍 ズーム: \(String(format: "%.1f", scale))x")
        }
    }
    
    // MARK: - Public Methods
    
    /// ホストに接続
    func connect() {
        guard !hostAddress.isEmpty else {
            connectionError = "ホストアドレスを入力してください"
            return
        }
        
        guard let portNumber = UInt16(port) else {
            connectionError = "ポート番号が無効です"
            return
        }
        
        connectionError = nil
        isConnecting = true
        isWaitingForAuth = true  // 認証待機状態
        authDenied = false
        
        Logger.shared.connectionStart()  // ★ ログ追加
        Logger.network("接続開始: \(hostAddress):\(portNumber) (リトライ: \(connectionRetryCount)/\(maxRetryCount))")
        
        networkReceiver.connect(to: hostAddress, port: portNumber)
        inputSender.connect(to: hostAddress)  // 入力送信も接続
        
        // ★ InputSender経由で登録パケット送信（少し待ってから）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            let listenPort = self.networkReceiver.listenPort
            let userRecordID = self.networkReceiver.cachedUserRecordID
            self.inputSender.sendRegistration(listenPort: listenPort, userRecordID: userRecordID)
        }
        
        // ★ 接続タイムアウト検知
        startConnectionTimeout()
        
        startFPSMonitoring()
    }
    
    /// 切断
    func disconnect() {
        // ★ タイマークリア
        cancelConnectionTimeout()
        connectionRetryCount = 0
        
        networkReceiver.disconnect()
        inputSender.disconnect()  // 入力送信も切断
        decoder.teardown()
        previewCoordinator.flush()
        
        stopFPSMonitoring()
        isConnected = false
        isConnecting = false
        decodedFrameCount = 0
        frameRate = 0
    }
    
    /// 保存済みホストに接続
    func connectToSavedHost(_ host: SavedHost) {
        hostAddress = host.address
        port = String(host.port)
        connect()
    }
    
    /// 保存済みホストを削除
    func deleteSavedHost(_ host: SavedHost) {
        savedHosts.removeAll { $0.id == host.id }
        saveSavedHosts()
    }
    
    // MARK: - ★ Phase 1: CloudKit Host Discovery
    
    /// CloudKitから自分のホストを発見
    func discoverHosts() {
        guard !isDiscoveringHosts else { return }
        
        isDiscoveringHosts = true
        connectionError = nil
        
        Task {
            do {
                let hosts = try await CloudKitSignalingManager.shared.discoverMyHosts()
                await MainActor.run {
                    discoveredHosts = hosts
                    isDiscoveringHosts = false
                    
                    if hosts.isEmpty {
                        // print("[RemoteViewModel] ☁️ オンラインのホストが見つかりませんでした")
                    } else {
                        // print("[RemoteViewModel] ☁️ \(hosts.count)台のホストを発見")
                    }
                }
            } catch {
                await MainActor.run {
                    isDiscoveringHosts = false
                    connectionError = "ホスト発見失敗: \(error.localizedDescription)"
                    // print("[RemoteViewModel] ☁️ ホスト発見エラー: \(error)")
                }
            }
        }
    }
    
    /// CloudKitで発見したホストに接続（P2Pホールパンチング使用）
    func connectToDiscoveredHost(_ host: HostDeviceRecord) {
        connectionError = nil
        isConnecting = true
        isWaitingForAuth = true
        authDenied = false
        
        // ★ Phase 1 (強化P2P): ICE候補を取得してP2P接続を試行
        Task {
            do {
                // CloudKitからICE候補を取得
                let candidates = try await CloudKitSignalingManager.shared.fetchICECandidates(for: host)
                Logger.p2p("📥 ICE候補取得: \(candidates.count)件")
                
                await MainActor.run {
                    let p2pManager = P2PConnectionManager()
                    
                    p2pManager.onStateChange = { [weak self] state in
                        DispatchQueue.main.async {
                            switch state {
                            case .connected(let endpoint):
                                Logger.p2p("✅ P2P接続成功: \(endpoint)")
                            case .failed(let reason):
                                Logger.p2p("P2P接続失敗: \(reason)", level: .warning)
                                // フォールバック: 従来の直接接続を試行
                                self?.hostAddress = host.connectionAddress
                                self?.port = String(host.connectionPort)
                                self?.connect()
                            default:
                                break
                            }
                        }
                    }
                    
                    p2pManager.onConnected = { [weak self] connection in
                        // P2P接続成功後、NetworkReceiverに引き継ぐ
                        DispatchQueue.main.async {
                            self?.hostAddress = host.connectionAddress
                            self?.port = String(host.connectionPort)
                            self?.connect()
                        }
                    }
                    
                    // ICE候補がある場合は強化版接続を使用
                    if !candidates.isEmpty {
                        Logger.p2p("🚀 ICE候補を使用したP2P接続開始")
                        p2pManager.connectWithICE(candidates: candidates)
                    } else {
                        // 従来の接続方式にフォールバック
                        Logger.p2p("📍 ICE候補なし、従来接続にフォールバック")
                        p2pManager.connect(to: host)
                    }
                }
            } catch {
                // ICE候補取得失敗時は従来方式にフォールバック
                Logger.p2p("⚠️ ICE候補取得失敗: \(error.localizedDescription)", level: .warning)
                await MainActor.run {
                    self.hostAddress = host.connectionAddress
                    self.port = String(host.connectionPort)
                    self.connect()
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupDelegates() {
        networkReceiver.delegate = self
        decoder.delegate = self
    }
    
    /// 現在の接続先を保存
    private func saveCurrentHost() {
        guard let portNumber = UInt16(port), !hostAddress.isEmpty else { return }
        
        // 既存のホストを検索
        if let index = savedHosts.firstIndex(where: { $0.address == hostAddress && $0.port == portNumber }) {
            // 既存: 最終接続時刻を更新
            savedHosts[index].lastConnected = Date()
        } else {
            // 新規: 追加
            let newHost = SavedHost(address: hostAddress, port: portNumber)
            savedHosts.insert(newHost, at: 0)
            
            // 最大5件まで保持
            if savedHosts.count > 5 {
                savedHosts = Array(savedHosts.prefix(5))
            }
        }
        
        // 最近の接続順にソート
        savedHosts.sort { $0.lastConnected > $1.lastConnected }
        saveSavedHosts()
        // print("[RemoteViewModel] ホスト保存: \(hostAddress):\(port)")
    }
    
    /// 保存済みホストを読み込み
    private func loadSavedHosts() {
        guard let data = UserDefaults.standard.data(forKey: savedHostsKey) else { return }
        
        do {
            savedHosts = try JSONDecoder().decode([SavedHost].self, from: data)
            // print("[RemoteViewModel] 保存済みホスト読み込み: \(savedHosts.count)件")
        } catch {
            // print("[RemoteViewModel] 保存済みホスト読み込みエラー: \(error)")
        }
    }
    
    /// 保存済みホストを永続化
    private func saveSavedHosts() {
        do {
            let data = try JSONEncoder().encode(savedHosts)
            UserDefaults.standard.set(data, forKey: savedHostsKey)
        } catch {
            // print("[RemoteViewModel] 保存済みホスト保存エラー: \(error)")
        }
    }
    
    private func startFPSMonitoring() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.frameRate = Double(self.frameCount)
                self.frameCount = 0
            }
        }
    }
    
    private func stopFPSMonitoring() {
        fpsTimer?.invalidate()
        fpsTimer = nil
    }
}

// MARK: - NetworkReceiverDelegate

extension RemoteViewModel: NetworkReceiverDelegate {
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceiveVPS data: Data) {
        Task { @MainActor in
            decoder.setVPS(data)
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceiveSPS data: Data) {
        Task { @MainActor in
            decoder.setSPS(data)
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceivePPS data: Data) {
        Task { @MainActor in
            decoder.setPPS(data)
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceiveVideoFrame data: Data, isKeyFrame: Bool, timestamp: UInt64) {
        Task { @MainActor in
            // 動画フレームを受信したらPNGデータをクリア（動画モードに復帰）
            if currentPNGData != nil {
                currentPNGData = nil
            }
            let presentationTime = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000)
            decoder.decode(annexBData: data, presentationTime: presentationTime)
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceivePNG data: Data) {
        Task { @MainActor in
            // PNGデータを受信したら更新
            currentPNGData = data
            // Coordinator に表示を依頼（デコードはCoordinator内で最適化されている）
            previewCoordinator.displayPNG(data)
            
            // ★ ログは軽量化（メインスレッドでのUIImage生成を廃止）
            pngReceiveCount += 1
            if pngReceiveCount == 1 || pngReceiveCount % 100 == 0 {
                // print("[RemoteViewModel] 🖼️ PNG受信: \(data.count / 1024)KB (累計\(pngReceiveCount)回)")
            }
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didChangeState state: NetworkReceiver.ConnectionState) {
        Task { @MainActor in
            switch state {
            case .listening:
                isConnecting = true
            case .receiving:
                isConnected = true
                isConnecting = false
            case .disconnected:
                isConnected = false
                isConnecting = false
            case .connecting:
                isConnecting = true
            case .failed(let error):
                isConnected = false
                isConnecting = false
                connectionError = error.localizedDescription
            }
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didFailWithError error: Error) {
        Task { @MainActor in
            connectionError = error.localizedDescription
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceiveAuthResult approved: Bool) {
        Task { @MainActor in
            isWaitingForAuth = false
            
            if approved {
                // 認証成功
                authDenied = false
                isConnected = true  // ★ 重要: 接続状態をtrueに設定
                isConnecting = false
                saveCurrentHost()  // ★ 接続成功時にホスト情報を保存
                // print("[RemoteViewModel] ✅ 認証成功")
            } else {
                // 認証拒否
                authDenied = true
                isConnected = false
                isConnecting = false
                connectionError = "接続が拒否されました"
                disconnect()
                // print("[RemoteViewModel] ❌ 認証拒否")
            }
        }
    }
}

// MARK: - VideoDecoderDelegate

extension RemoteViewModel: VideoDecoderDelegate {
    nonisolated func videoDecoder(_ decoder: VideoDecoder, didOutputPixelBuffer pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        Task { @MainActor in
            decodedFrameCount += 1
            frameCount += 1
            previewCoordinator.display(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        }
    }
    
    nonisolated func videoDecoder(_ decoder: VideoDecoder, didFailWithError error: Error) {
        Task { @MainActor in
            connectionError = "デコードエラー: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Connection Timeout & Retry
    
    /// 接続タイムアウトタイマーを開始
    private func startConnectionTimeout() {
        cancelConnectionTimeout()
        
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            self?.handleConnectionTimeout()
        }
        
        print("[RemoteViewModel] ⏱️ 接続タイムアウトタイマー開始: \(connectionTimeout)秒")
    }
    
    /// 接続タイムアウトタイマーをキャンセル
    private func cancelConnectionTimeout() {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
    }
    
    /// 接続タイムアウト処理
    private func handleConnectionTimeout() {
        guard isWaitingForAuth && !isConnected else {
            // 既に接続成功している場合は何もしない
            return
        }
        
        connectionRetryCount += 1
        print("[RemoteViewModel] ⚠️ 接続タイムアウト (リトライ: \(connectionRetryCount)/\(maxRetryCount))")
        
        if connectionRetryCount < maxRetryCount {
            // 自動リトライ
            print("[RemoteViewModel] 🔄 自動リトライ開始...")
            
            // 一旦切断してから再接続
            networkReceiver.disconnect()
            inputSender.disconnect()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let portNumber = UInt16(self.port) else { return }
                
                self.networkReceiver.connect(to: self.hostAddress, port: portNumber)
                self.inputSender.connect(to: self.hostAddress)
                
                // 再登録送信
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }
                    let listenPort = self.networkReceiver.listenPort
                    let userRecordID = self.networkReceiver.cachedUserRecordID
                    self.inputSender.sendRegistration(listenPort: listenPort, userRecordID: userRecordID)
                }
                
                self.startConnectionTimeout()
            }
        } else {
            // 最大リトライ回数に達した → エラー表示
            print("[RemoteViewModel] ❌ 接続失敗: 最大リトライ回数超過")
            
            isConnecting = false
            isWaitingForAuth = false
            connectionError = "接続タイムアウト: Macに接続できません。\n・同じWi-Fiに接続していますか？\n・Macのファイアウォール設定を確認してください"
            
            // 接続クリーンアップ
            networkReceiver.disconnect()
            inputSender.disconnect()
            connectionRetryCount = 0
        }
    }
    
    /// 接続成功時にタイムアウトをキャンセル
    func markConnectionSuccessful() {
        cancelConnectionTimeout()
        connectionRetryCount = 0
        print("[RemoteViewModel] ✅ 接続成功確認 - タイムアウトキャンセル")
    }
}
