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
import SwiftUI

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
    @Published var port: String = "\(NetworkTransportConfiguration.default.videoPort)"
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
    
    /// ★ Phase 2: 全知全能ステート（HUD表示用）
    @Published var currentOmniscientState: OmniscientState?
    
    /// ★ Phase 2: HUD表示フラグ（デフォルトON）
    @Published var showHUD = true
    
    // MARK: - Components
    
    let networkReceiver = NetworkReceiver()
    let decoder = VideoDecoder()
    let previewCoordinator = PreviewViewCoordinator()

    let inputSender = InputSender()
    let deviceSensor = DeviceSensor()  // ★ Phase 1: デバイスセンサー
    
    /// バックグラウンド遷移前の接続情報
    private var backgroundConnectionInfo: (host: String, port: String)?
    
    /// Notification購読
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    
    // MARK: - Private Properties
    
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameCount = 0
    private var pngReceiveCount = 0  // ★ PNG受信カウンター
    private var fpsTimer: Timer?
    private let savedHostsKey = "savedHosts"
    
    // MARK: - Pipeline Latency Measurement (Phase 1)
    /// フレーム受信時刻（デコード前）
    private var lastReceiveTimestamp: CFAbsoluteTime = 0
    /// デコード開始時刻
    private var lastDecodeStartTimestamp: CFAbsoluteTime = 0
    /// EMA計測値
    private var emaReceiveToDecodeMs: Double = 0
    private var emaDecodeDurationMs: Double = 0
    private var emaRenderMs: Double = 0
    private var emaNetworkTransitMs: Double = 0
    private let emaAlpha: Double = 0.1
    /// 最後のレンダー時刻
    private var lastRenderTimestamp: CFAbsoluteTime = 0
    
    // ★ 接続診断用プロパティ
    private var connectionTimeoutTimer: Timer?
    private var connectionRetryCount = 0
    private let maxRetryCount = 3
    /// ★ B-1: TURN relayを考慮した接続タイムアウト（15秒）
    private let connectionTimeout: TimeInterval = 15.0
    
    /// ★ B-1: TURN接続進行中フラグ（disconnect()をブロック）
    private var isTURNInProgress: Bool = false
    
    /// ★ B-1: P2Pマネージャー保持（TURN状態維持用）
    private var activeP2PManager: P2PConnectionManager?
    
    // MARK: - Initialization
    
    init() {
        setupDelegates()
        loadSavedHosts()
        networkReceiver.prefetchUserRecordID()  // ★ Phase 3: userRecordIDを事前取得
        setupLifecycleObservers()
    }
    
    deinit {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Lifecycle Management
    
    private func setupLifecycleObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: .appDidEnterBackground,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleBackgroundTransition()
        }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: .appDidBecomeActive,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleForegroundTransition()
        }
    }
    
    /// バックグラウンド遷移: リソース解放
    func handleBackgroundTransition() {
        Logger.app("📱 バックグラウンド: リソース解放開始")
        
        // 接続情報を保存（復帰時に使用）
        if isConnected {
            backgroundConnectionInfo = (host: hostAddress, port: port)
        }
        
        // デコーダー停止（VTDecompressionSession解放）
        decoder.teardown()
        
        // FPSモニタリング停止
        stopFPSMonitoring()
        
        // ネットワーク切断（バッテリー消費防止）
        networkReceiver.disconnect()
        inputSender.disconnect()
        
        isConnected = false
        isConnecting = false
        
        Logger.app("📱 バックグラウンド: リソース解放完了")
    }
    
    /// フォアグラウンド復帰: 再接続
    func handleForegroundTransition() {
        Logger.app("📱 フォアグラウンド復帰: 再接続開始")
        
        // バックグラウンド前に接続していた場合のみ再接続
        if let info = backgroundConnectionInfo {
            hostAddress = info.host
            port = info.port
            backgroundConnectionInfo = nil
            
            // 少し遅延して再接続（UI安定化のため）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.connect()
            }
        }
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
    
    /// ホストに接続（スマート接続：直接 -> CloudKit/TURNフォールバック）
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
        
        Logger.shared.connectionStart()
        Logger.network("🚀 スマート接続開始: \(hostAddress):\(portNumber)")
        
        // 1. まずは直接接続を試みる（LAN内最速）
        networkReceiver.connect(to: hostAddress, port: portNumber)
        inputSender.connect(to: hostAddress)
        deviceSensor.startMonitoring()
        
        // 2. 並行してCloudKitから当該ホストのICE候補を探す（NAT越え準備）
        // ★ Step 2最適化: ICE候補取得後、直接接続が未完了なら即座にICE接続を並行開始
        if isPrivateIP(hostAddress) {
            Task {
                Logger.network("🔄 LAN内IP(\(hostAddress))を検出。CloudKitでICE候補を検索中...")
                do {
                    // CloudKit上の全ホストを取得
                    let hosts = try await CloudKitSignalingManager.shared.discoverMyHosts()
                    
                    // IPが一致する、または最新のホストを探す
                    if let targetHost = hosts.first(where: { $0.connectionAddress == hostAddress }) ?? hosts.first {
                        Logger.network("✅ 対応するCloudKitホストを発見: \(targetHost.deviceName)")
                        
                        // ICE候補を取得
                        let candidates = try await CloudKitSignalingManager.shared.fetchICECandidates(for: targetHost)
                        Logger.p2p("📥 バックグラウンドICE候補取得: \(candidates.count)件")
                        
                        if !candidates.isEmpty {
                            await MainActor.run {
                                self.cachedICECandidates = candidates
                                
                                // ★ Step 2: 直接接続が未完了なら、ICE候補で即座に並行接続開始
                                // Starbucks等の異なるNAT環境では直接TCP接続が不可能なため、
                                // 5秒タイムアウトを待たずにICE候補（P2P/TURN）を試行
                                if !self.isConnected && self.isWaitingForAuth {
                                    Logger.network("🚀 直接接続未完了 → ICE候補(\(candidates.count)件)で並行NAT越え接続開始")
                                    self.connectWithICE(candidates: candidates)
                                }
                            }
                        }
                    }
                } catch {
                    Logger.network("⚠️ CloudKitホスト検索失敗: \(error.localizedDescription)")
                }
            }
        }
        
        // 登録パケット送信
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            let listenPort = self.networkReceiver.listenPort
            let userRecordID = self.networkReceiver.cachedUserRecordID
            self.inputSender.sendRegistration(listenPort: listenPort, userRecordID: userRecordID)
        }
        
        // 接続タイムアウト検知
        startConnectionTimeout()
        startFPSMonitoring()
    }
    
    /// プライベートIPかどうか判定
    private func isPrivateIP(_ ip: String) -> Bool {
        return ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")
    }
    
    /// 取得したICE候補（リトライ用キャッシュ）
    private var cachedICECandidates: [ICECandidate] = []
    
    /// 切断
    func disconnect() {
        // ★ B-1: TURN接続進行中は切断をブロック
        if isTURNInProgress {
            Logger.pipeline("⏸️ TURN接続進行中のため切断を保留", sampling: .always)
            return
        }
        
        Logger.pipeline("★ 切断処理開始 (connected=\(isConnected), connecting=\(isConnecting))", sampling: .always)
        
        // ★ タイマークリア
        cancelConnectionTimeout()
        connectionRetryCount = 0
        
        networkReceiver.disconnect()
        inputSender.disconnect()  // 入力送信も切断
        deviceSensor.stopMonitoring() // ★ Phase 1
        decoder.teardown()
        previewCoordinator.flush()
        
        stopFPSMonitoring()
        isConnected = false
        isConnecting = false
        decodedFrameCount = 0
        frameRate = 0
        
        Logger.pipeline("★ 切断処理完了", sampling: .always)
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
        deviceSensor.delegate = self  // ★ Phase 1
        inputSender.delegate = self    // ★ UDP認証結果受信用
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
                // ★ 0FPS警告（接続中のみ）
                if self.frameCount == 0 && self.isConnected {
                    Logger.pipeline("⚠️ FPS=0 検出 (接続中なのに映像なし) decoded=\(self.decodedFrameCount)", level: .warning, sampling: .throttle(5.0))
                }
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
            Logger.pipeline("★ VPS受信: \(data.count) bytes → HEVCストリーム検出", sampling: .always)
            decoder.setVPS(data)
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceiveSPS data: Data) {
        Task { @MainActor in
            Logger.pipeline("★ SPS受信: \(data.count) bytes", sampling: .always)
            decoder.setSPS(data)
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceivePPS data: Data) {
        Task { @MainActor in
            Logger.pipeline("★ PPS受信: \(data.count) bytes", sampling: .always)
            decoder.setPPS(data)
        }
    }
    
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceiveVideoFrame data: Data, isKeyFrame: Bool, timestamp: UInt64) {
        // ★ Phase 1: 受信時刻記録（nonisolated安全）
        let receiveTime = CFAbsoluteTimeGetCurrent()
        
        Task { @MainActor in
            // ★ Phase 1: 受信時刻保存
            self.lastReceiveTimestamp = receiveTime
            
            // 動画フレームを受信したらPNGデータをクリア（動画モードに復帰）
            if currentPNGData != nil {
                currentPNGData = nil
            }
            
            // ★ Phase 1: デコード開始時刻記録
            self.lastDecodeStartTimestamp = CFAbsoluteTimeGetCurrent()
            
            let presentationTime = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000)
            decoder.decode(annexBData: data, presentationTime: presentationTime)
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
                Logger.pipeline("✅ 認証成功: 接続確立", sampling: .always)
            } else {
                // 認証拒否
                authDenied = true
                isConnected = false
                isConnecting = false
                connectionError = "接続が拒否されました"
                Logger.pipeline("❌ 認証拒否: 切断実行", sampling: .always)
                disconnect()
            }
        }
    }
    
    // ★ Phase 2: 全知全能ステート受信
    nonisolated func networkReceiver(_ receiver: NetworkReceiver, didReceiveOmniscientState state: OmniscientState) {
        Task { @MainActor in
            // ★ Phase 1: iPhone側ローカルメトリクスを注入
            var enrichedState = state
            
            // macOS側からの壁時計を使ってネットワーク遊延を推定
            // （NTP同期なしの粗推定だが、相対変化は追跡可能）
            if state.hostWallClockMs > 0 {
                let localMs = CFAbsoluteTimeGetCurrent() * 1000.0
                let transitMs = max(0, localMs - state.hostWallClockMs)
                // RTT/2との整合性チェック: 10秒以上のズレは時計同期エラーとみなしRTT/2を使用
                if transitMs < 10000 {
                    emaNetworkTransitMs = emaNetworkTransitMs == 0 ? transitMs
                        : emaNetworkTransitMs * (1.0 - emaAlpha) + transitMs * emaAlpha
                } else {
                    emaNetworkTransitMs = state.rtt * 1000.0 / 2.0
                }
            }
            
            // ★ Phase 1: iPhone側ローカル計測値を注入
            enrichedState.networkTransitMs = emaNetworkTransitMs
            enrichedState.receiveToDecodeMs = emaReceiveToDecodeMs
            enrichedState.decodeDurationMs = emaDecodeDurationMs
            enrichedState.renderMs = emaRenderMs
            
            // End-to-End合計 = macOS側(Capture+Encode+Packetize) + Network + iPhone側(Receive→Decode+Render)
            enrichedState.endToEndMs = enrichedState.captureToEncodeMs
                + enrichedState.encodeDurationMs
                + enrichedState.packetizeMs
                + emaNetworkTransitMs
                + emaReceiveToDecodeMs
                + emaRenderMs
            
            // アニメーション付きで更新（滑らかに）
            withAnimation(.linear(duration: 0.2)) {
                self.currentOmniscientState = enrichedState
            }
        }
    }
}

// MARK: - VideoDecoderDelegate

extension RemoteViewModel: VideoDecoderDelegate {
    nonisolated func videoDecoder(_ decoder: VideoDecoder, didOutputPixelBuffer pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        // ★ Phase 1: デコード完了時刻（nonisolated安全）
        let decodeEndTime = CFAbsoluteTimeGetCurrent()
        
        Task { @MainActor in
            // ★ Phase 1: デコード所要時間計算
            if lastDecodeStartTimestamp > 0 {
                let decodeDurationMs = (decodeEndTime - lastDecodeStartTimestamp) * 1000.0
                emaDecodeDurationMs = emaDecodeDurationMs == 0 ? decodeDurationMs
                    : emaDecodeDurationMs * (1.0 - emaAlpha) + decodeDurationMs * emaAlpha
            }
            
            // ★ Phase 1: 受信→デコード完了の全体時間
            if lastReceiveTimestamp > 0 {
                let receiveToDecodeMs = (decodeEndTime - lastReceiveTimestamp) * 1000.0
                emaReceiveToDecodeMs = emaReceiveToDecodeMs == 0 ? receiveToDecodeMs
                    : emaReceiveToDecodeMs * (1.0 - emaAlpha) + receiveToDecodeMs * emaAlpha
            }
            
            decodedFrameCount += 1
            frameCount += 1
            
            // ★ Phase 1: レンダー開始時刻
            let renderStart = CFAbsoluteTimeGetCurrent()
            previewCoordinator.display(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            let renderMs = (CFAbsoluteTimeGetCurrent() - renderStart) * 1000.0
            emaRenderMs = emaRenderMs == 0 ? renderMs
                : emaRenderMs * (1.0 - emaAlpha) + renderMs * emaAlpha
            lastRenderTimestamp = CFAbsoluteTimeGetCurrent()
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
        Logger.network("⚠️ 接続タイムアウト (リトライ: \(connectionRetryCount)/\(maxRetryCount))")
        
        if connectionRetryCount < maxRetryCount {
            // 自動リトライ
            Logger.network("🔄 自動リトライ開始...")
            
            // 一旦切断してから再接続
            networkReceiver.disconnect()
            inputSender.disconnect()
            
            // ★ スマートリトライロジック
            // ICE候補が取得できている場合は、P2P/TURN接続への切り替えを試みる
            if !cachedICECandidates.isEmpty {
                Logger.network("🚀 CloudKitのICE候補(\(cachedICECandidates.count)件)を使用してNAT越えリトライを実行します")
                connectWithICE(candidates: cachedICECandidates)
                return
            }
            
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
            Logger.network("❌ 接続失敗: 最大リトライ回数超過")
            
            isConnecting = false
            isWaitingForAuth = false
            
            if !cachedICECandidates.isEmpty {
                 connectionError = "接続タイムアウト: NAT越え(TURN)も失敗しました。\n・モバイル回線の電波状況を確認してください\n・Mac側でTURNサーバーへの接続が許可されているか確認してください"
            } else {
                 connectionError = "接続タイムアウト: Macに接続できません。\n・同じWi-Fiに接続していますか？\n・Macのファイアウォール設定を確認してください"
            }
            
            // 接続クリーンアップ
            networkReceiver.disconnect()
            inputSender.disconnect()
            connectionRetryCount = 0
            cachedICECandidates = [] // キャッシュクリア
        }
    }
    
    /// ICE候補を使って接続（P2Pマネージャーへ委譲）
    private func connectWithICE(candidates: [ICECandidate]) {
        // ★ Step 2: 直接接続が既に成功している場合はICE接続を開始しない
        if isConnected && !isWaitingForAuth {
            Logger.p2p("ICE接続スキップ: 直接接続が既に成功")
            return
        }
        
        // ★ B-1: TURN接続進行中フラグを設定
        isTURNInProgress = true
        
        // タイマー停止（P2Pマネージャーが独自にタイムアウト管理するため）
        cancelConnectionTimeout()
        
        Task { @MainActor in
            let p2pManager = P2PConnectionManager()
            self.activeP2PManager = p2pManager  // ★ B-1: 保持
            
            // 状態監視
            p2pManager.setConnectionHandler { [weak self] (state: P2PConnectionState) in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    // ★ Step 2: 直接接続が既に成功していたらICE結果を無視
                    if self.isConnected && !self.isWaitingForAuth {
                        Logger.p2p("ICE結果無視: 直接接続が既に成功")
                        return
                    }
                    
                    switch state {
                    case .connected(let endpoint):
                        Logger.p2p("✅ スマートリトライ成功: \(endpoint)")
                        
                        // ★ Step 2: TURN経由の場合はTURNデータパスを使用
                        if endpoint.hasPrefix("TURN:") {
                            Logger.network("🔄 TURN relay接続成功 → TURNデータパス構築")
                            
                            // NetworkReceiverをTURNモードに切り替え
                            self.networkReceiver.connectViaTURN()
                            
                            // TURNClient.onDataReceived → NetworkReceiver.injectTURNData()
                            if let turnClient = p2pManager.turnClient {
                                Task {
                                    await turnClient.setDataHandler { [weak self] data in
                                        self?.networkReceiver.injectTURNData(data)
                                    }
                                    
                                    // ★ A-3: TURN経由で登録パケット(0xFE)をMacに送信
                                    // Mac側のenableTURNReception()がこれを検出してTURNモードに切替
                                    do {
                                        var regPacket = Data()
                                        regPacket.append(0xFE)  // 登録パケットタイプ
                                        // ポート番号（2バイト）
                                        let listenPort: UInt16 = 5001
                                        regPacket.append(UInt8(listenPort >> 8))
                                        regPacket.append(UInt8(listenPort & 0xFF))
                                        
                                        // ★ A-2修正: iPhoneのrelayアドレスを含める（Mac→iPhone送信用）
                                        // relayIP（NULL終端文字列）
                                        let myRelayIP = p2pManager.myRelayIP
                                        let myRelayPort = p2pManager.myRelayPort
                                        if let ipData = myRelayIP.data(using: .utf8) {
                                            regPacket.append(ipData)
                                        }
                                        regPacket.append(0x00) // NULL終端
                                        // relayPort（2バイト BigEndian）
                                        regPacket.append(UInt8(myRelayPort >> 8))
                                        regPacket.append(UInt8(myRelayPort & 0xFF))
                                        
                                        // userRecordID
                                        if let userID = self.networkReceiver.cachedUserRecordID,
                                           let idData = userID.data(using: .utf8) {
                                            regPacket.append(idData)
                                        }
                                        
                                        // endpointからMacのrelay addressを抽出
                                        let turnParts = endpoint.replacingOccurrences(of: "TURN:", with: "").split(separator: ":")
                                        if turnParts.count >= 2,
                                           let peerPort = UInt16(turnParts.last!) {
                                            let peerIP = String(turnParts.dropLast().joined(separator: ":"))
                                            try await turnClient.sendData(regPacket, to: peerIP, peerPort: peerPort)
                                            Logger.network("✅ TURN経由で登録パケット送信完了 → \(peerIP):\(peerPort) (myRelay=\(myRelayIP):\(myRelayPort))")
                                        }
                                    } catch {
                                        Logger.network("⚠️ TURN登録パケット送信失敗: \(error)", level: .warning)
                                    }
                                }
                            }
                            
                            // 成功扱い
                            self.isConnected = true
                            self.isWaitingForAuth = false
                            self.isConnecting = false
                            self.markConnectionSuccessful()
                        } else {
                            // ★ host/STUN候補での接続成功 → 従来の直接接続
                            let parts = endpoint.split(separator: ":")
                            if parts.count >= 2 {
                                let host = String(parts[parts.count-2])
                                let port = String(parts[parts.count-1])
                                
                                self.hostAddress = host
                                self.port = port
                                
                                if let portNum = UInt16(port) {
                                    self.networkReceiver.connect(to: host, port: portNum)
                                    self.inputSender.connect(to: host)
                                    self.markConnectionSuccessful()
                                }
                            }
                        }
                        
                    case .failed(let reason):
                        Logger.p2p("スマートリトライ失敗: \(reason)", level: .warning)
                        Task { @MainActor in
                            // ★ B-1: TURN含む全候補失敗時のみここに到達
                            self.isTURNInProgress = false
                            self.connectionError = "NAT越え接続失敗: \(reason)"
                            self.isConnecting = false
                            self.isWaitingForAuth = false
                            self.disconnect()
                        }
                    default:
                        break
                    }
                }
            }
            
            // 接続開始
            p2pManager.connectWithICE(candidates: candidates)
        }
    }
    
    /// 接続成功時にタイムアウトをキャンセル
    func markConnectionSuccessful() {
        cancelConnectionTimeout()
        connectionRetryCount = 0
        print("[RemoteViewModel] ✅ 接続成功確認 - タイムアウトキャンセル")
    }
}

// MARK: - DeviceSensorDelegate

extension RemoteViewModel: DeviceSensorDelegate {
    nonisolated func deviceSensor(_ sensor: DeviceSensor, didUpdateMetrics metrics: ClientDeviceMetrics) {
        Task { @MainActor in
            // InputSender経由でHostへ送信
            guard isConnected else { return }
            inputSender.sendTelemetry(metrics: metrics, fps: frameRate)
        }
    }
}

// MARK: - InputSenderDelegate

extension RemoteViewModel: InputSenderDelegate {
    nonisolated func inputSender(_ sender: InputSender, didChangeState connected: Bool) {
        Task { @MainActor in
            Logger.network("📡 InputSender状態変化: \(connected ? "接続済み" : "切断")")
        }
    }
    
    nonisolated func inputSender(_ sender: InputSender, didFailWithError error: Error) {
        Task { @MainActor in
            Logger.network("❌ InputSenderエラー: \(error.localizedDescription)", level: .error)
        }
    }
    
    nonisolated func inputSender(_ sender: InputSender, didReceiveAuthResult approved: Bool) {
        Task { @MainActor in
            Logger.network("🔑 UDP認証結果受信: \(approved ? "許可✅" : "拒否❌")")
            if approved {
                // ★ タイムアウトキャンセル＆接続成功マーク
                self.markConnectionSuccessful()
                
                // 接続状態を更新（まだ未接続なら）
                if !self.isConnected {
                    self.isConnected = true
                    self.isConnecting = false
                    self.connectionError = nil
                    Logger.network("✅ UDP認証経由で接続確立")
                }
            } else {
                self.connectionError = "接続が拒否されました"
                self.isConnecting = false
            }
        }
    }
}
