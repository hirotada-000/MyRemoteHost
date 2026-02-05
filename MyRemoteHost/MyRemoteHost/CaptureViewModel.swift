//
//  CaptureViewModel.swift
//  MyRemoteHost
//
//  キャプチャ機能を統合するViewModel
//  ScreenCaptureManager, VideoEncoder, VideoDecoder, NetworkSender を連携
//

import Foundation
import CoreMedia
import CoreVideo
import Combine
import ScreenCaptureKit
import Network
import VideoToolbox
import LocalAuthentication

/// 認証待ちクライアント情報
struct PendingClient: Identifiable {
    let id = UUID()
    let host: String
    let port: UInt16
    let requestTime: Date
}

/// キャプチャパイプライン全体を管理するViewModel
@MainActor
class CaptureViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isCapturing = false
    @Published var frameRate: Double = 0
    @Published var encodedFrameCount: Int = 0
    @Published var decodedFrameCount: Int = 0
    @Published var captureError: String?
    @Published var availableDisplays: [SCDisplay] = []
    @Published var selectedDisplayIndex: Int = 0
    
    /// ローカルループバックモード（エンコード→デコードをMac内で完結）
    @Published var isLoopbackMode = true
    
    /// ネットワーク送信モード
    @Published var isNetworkMode = false
    @Published var isListening = false
    @Published var connectedClients: Int = 0
    
    // MARK: - Quality Settings (リアルタイム調整可能)
    
    // MARK: - Quality Settings (リアルタイム調整可能)
    
    /// ビットレート（Mbps）- 範囲: 1-100
    /// ★初期値: 15Mbps (動きのスムーズさのために下げる)
    @Published var bitRateMbps: Double = 15 {
        didSet { applyEncoderSettings() }
    }
    
    /// フレームレート - 範囲: 15-120
    @Published var targetFPS: Double = 60 {
        didSet { applyEncoderSettings() }
    }
    
    /// キーフレーム間隔 - 範囲: 1-120
    /// ★初期値: 60 (動画モードでの圧縮効率とスムーズさを優先)
    @Published var keyFrameInterval: Double = 60 {
        didSet { applyEncoderSettings() }
    }
    
    /// 解像度スケール - 範囲: 0.25-1.0
    @Published var resolutionScale: Double = 1.0 {
        didSet { applyResolutionScale() }
    }
    
    /// プロファイル (0=Baseline, 1=Main, 2=High)
    @Published var profileIndex: Int = 2 {
        didSet { applyEncoderSettings() }
    }
    
    // MARK: - 詳細設定 (新規追加)
    
    /// ★ 品質 (Quality) - 範囲: 0.5-1.0 (高いほど高品質)
    /// ★初期値: 0.65 (動画モード中の負荷軽減)
    @Published var quality: Double = 0.65 {
        didSet { applyEncoderSettings() }
    }
    
    /// ★ コーデック選択 (0=H.264, 1=HEVC)
    @Published var codecIndex: Int = 1 {
        didSet { applyEncoderSettings() }
    }
    
    /// ★ 低遅延モード
    @Published var lowLatencyMode: Bool = true {
        didSet { applyEncoderSettings() }
    }
    
    /// ★ ピークビットレート倍率 - 範囲: 1.0-3.0
    @Published var peakBitRateMultiplier: Double = 2.0 {
        didSet { applyEncoderSettings() }
    }
    
    // MARK: - ハイブリッドモード設定 (新規)
    
    /// ★ ハイブリッドモード有効化 (動きがない時は JPEG 送信)
    /// ★初期値: true (静止時の最高画質を担保するためデフォルトON)
    @Published var hybridMode: Bool = true
    
    /// ★ 適応型品質制御モード (Phase 1)
    /// ネットワーク状況に応じてビットレート/FPS/解像度を自動調整
    @Published var adaptiveQualityMode: Bool = true
    
    /// ★ 現在のネットワーク品質レベル表示
    @Published var networkQualityDisplay: String = "Good"
    
    /// ★ 静止画 JPEG 品質 - 不要のため削除予定だがビルドエラー回避と互換性のため一旦残すか、削除する
    /// 可逆圧縮PNG採用により品質設定は不要になった
    // @Published var jpegQuality: Double = 1.0 (削除)
    
    /// ★ 動き検出しきい値 (Dirty Rects の面積比率)
    @Published var motionThreshold: Double = 0.01  // 1% 以下なら静止画と判定
    
    /// ★ 静止フレームカウント (連続で動きがないフレーム数)
    @Published var staticFrameCount: Int = 0
    
    /// ★ 静止判定に必要なフレーム数
    /// ★初期値: 3 (より素早く高画質に切り替え)
    @Published var staticFrameThreshold: Int = 3
    
    /// ★ 現在のモード表示 (デバッグ用)
    @Published var currentMode: String = "HEVC"
    
    // MARK: - Authentication Settings
    
    /// 認証が必要かどうか
    @Published var requireAuthentication: Bool = true
    
    /// 接続パスワード
    @Published var connectionPassword: String = "1234"
    
    /// 認証待ちのクライアント情報
    @Published var pendingAuthClient: PendingClient? = nil
    
    /// 認証失敗回数
    @Published var authFailureCount: Int = 0
    
    /// 認証ロック中
    @Published var isAuthLocked: Bool = false
    
    // MARK: - Components
    
    let captureManager = ScreenCaptureManager()
    let encoder = VideoEncoder()
    let decoder = VideoDecoder()
    let previewCoordinator = PreviewViewCoordinator()
    let networkSender = NetworkSender(port: 5100)
    let inputReceiver = InputReceiver(port: 5002)
    let networkQualityMonitor = NetworkQualityMonitor()  // ★ Phase 1: 品質モニター
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private var vpsData: Data?  // HEVC用
    private var spsData: Data?
    private var ppsData: Data?
    
    /// ★ キャプチャ開始中フラグ（二重開始防止）
    private var isStartingCapture = false
    
    /// ★ エンコーダー初期化済みフラグ
    private var isEncoderReady = false
    
    /// ★ 設定更新debounceタイマー
    private var settingsDebounceTask: Task<Void, Never>?
    private var resolutionDebounceTask: Task<Void, Never>?
    
    // MARK: - ログ頻度制御
    
    /// PNG送信カウンター
    private var pngSendCount = 0
    
    /// ★ PNG送信頻度制御（1秒に1回）
    private var lastPNGSendTime: Date?
    
    /// 前回のズーム状態
    private var lastZoomState: Bool = false
    
    /// ★ 接続安定化タイマー（接続後2秒間はPNG送信無効）
    private var connectionStabilizedTime: Date?
    
    // MARK: - Initialization
    
    init() {
        setupBindings()
        setupDelegates()
    }
    
    // MARK: - Public Methods
    
    /// 利用可能なディスプレイを取得
    func fetchDisplays() async {
        do {
            try await captureManager.fetchAvailableDisplays()
            availableDisplays = captureManager.availableDisplays
        } catch {
            captureError = "ディスプレイ取得失敗: \(error.localizedDescription)"
        }
    }
    
    /// ネットワークリスナーを開始
    func startNetworkListener() {
        do {
            print("[CaptureViewModel] 🚀 NetworkSender開始中...")
            try networkSender.startListening()
            print("[CaptureViewModel] ✅ NetworkSender開始成功")
            try inputReceiver.startListening()  // 入力受信も開始
            networkQualityMonitor.startMonitoring()  // ★ Phase 1: 品質モニタリング開始
            isListening = true
            
            // ★ Phase 1: CloudKitにデバイス登録
            Task {
                await registerToCloudKit()
            }
        } catch {
            print("[CaptureViewModel] ❌ ネットワーク開始失敗: \(error)")
            captureError = "ネットワーク開始失敗: \(error.localizedDescription)"
        }
    }
    
    /// CloudKitにホストデバイスを登録
    private func registerToCloudKit() async {
        guard let localIP = CloudKitSignalingManager.getLocalIPAddress() else {
            print("[CaptureViewModel] ⚠️ ローカルIP取得失敗: CloudKit登録スキップ")
            return
        }
        
        let deviceName = Host.current().localizedName ?? "Mac"
        
        do {
            // 1. CloudKitにローカルIPで登録
            try await CloudKitSignalingManager.shared.registerHost(
                deviceName: deviceName,
                localIP: localIP,
                localPort: 5000
            )
            print("[CaptureViewModel] ☁️ CloudKit登録完了: \(deviceName)")
            
            // 2. ★ Phase 2: STUNで公開IP取得
            await discoverPublicEndpoint()
        } catch {
            print("[CaptureViewModel] ⚠️ CloudKit登録失敗: \(error.localizedDescription)")
            // 登録失敗してもローカル接続は継続
        }
    }
    
    /// ★ Phase 2: STUNで公開IPを取得しCloudKitに保存
    /// ★ Phase 1 (強化P2P): ICE候補を収集してCloudKitに保存
    private func discoverPublicEndpoint() async {
        do {
            // 1. P2PConnectionManagerでICE候補を収集
            let p2pManager = P2PConnectionManager()
            let candidates = try await p2pManager.gatherCandidates(localPort: 5000)
            
            // 2. ICE候補をCloudKitに保存
            try await CloudKitSignalingManager.shared.saveICECandidates(candidates)
            
            // 3. パブリックIP/ポートも保存（従来互換）
            if let srflxCandidate = candidates.first(where: { $0.type == .serverReflexive }) {
                try await CloudKitSignalingManager.shared.updatePublicEndpoint(
                    publicIP: srflxCandidate.ip,
                    publicPort: srflxCandidate.port
                )
                print("[CaptureViewModel] 🌐 STUN完了: \(srflxCandidate.ip):\(srflxCandidate.port)")
            }
            
            print("[CaptureViewModel] 📤 ICE候補保存完了: \(candidates.count)件")
        } catch {
            print("[CaptureViewModel] ⚠️ STUN/ICE候補収集失敗（ローカル接続のみ）: \(error.localizedDescription)")
            // STUN失敗してもローカル接続は継続
        }
    }
    
    /// ネットワークリスナーを停止
    func stopNetworkListener() {
        // ★ Phase 1: CloudKitからオフライン通知
        Task {
            await CloudKitSignalingManager.shared.unregisterHost()
        }
        
        networkSender.stop()
        inputReceiver.stop()  // 入力受信も停止
        networkQualityMonitor.stopMonitoring()  // ★ Phase 1: 品質モニタリング停止
        isListening = false
        connectedClients = 0
    }
    
    /// キャプチャを開始
    func startCapture() async {
        guard !isCapturing && !isStartingCapture else { return }
        
        isStartingCapture = true
        captureError = nil
        
        // ディスプレイ選択
        if selectedDisplayIndex < availableDisplays.count {
            captureManager.selectDisplay(availableDisplays[selectedDisplayIndex])
        }
        
        do {
            try await captureManager.startCapture()
            
            // ★ 高画質モード: フルスケールでキャプチャ
            // 帯域に余裕があれば1.0で最高画質
            if let display = captureManager.selectedDisplay {
                if display.width > 2560 {
                    try await captureManager.updateResolutionScale(1.0)
                    print("[CaptureViewModel] 🚀 高画質モード: スケール 1.0 (フル解像度)")
                }
            }
            
            isCapturing = true
        } catch {
            captureError = "キャプチャ開始失敗: \(error.localizedDescription)"
        }
        
        isStartingCapture = false
    }
    
    /// キャプチャを停止
    func stopCapture() async {
        guard isCapturing else { return }
        
        // ★ 先にフラグをfalseにして新しいフレーム処理を止める
        isCapturing = false
        isEncoderReady = false
        
        // ★ キャプチャを停止（フレーム生成を止める）
        await captureManager.stopCapture()
        
        // ★ その後でエンコーダーを破棄
        encoder.teardown()
        decoder.teardown()
        previewCoordinator.flush()
        
        encodedFrameCount = 0
        decodedFrameCount = 0
        spsData = nil
        ppsData = nil
    }
    
    // MARK: - Private Methods
    
    private func setupBindings() {
        captureManager.$frameRate
            .receive(on: DispatchQueue.main)
            .assign(to: &$frameRate)
    }
    
    private func setupDelegates() {
        captureManager.delegate = self
        encoder.delegate = self
        decoder.delegate = self
        networkSender.delegate = self
        networkQualityMonitor.delegate = self  // ★ Phase 1: 品質モニター
        inputReceiver.delegate = self  // ★ ズームリクエスト受信用
    }
    
    /// エンコーダー設定を適用（セッションを再構成して即座に反映）
    private func applyEncoderSettings() {
        encoder.bitRate = Int(bitRateMbps * 1_000_000)
        encoder.targetFrameRate = Int(targetFPS)
        encoder.maxKeyFrameInterval = Int(keyFrameInterval)
        
        // ★ 新規: 詳細設定
        encoder.qualityMode = true  // 品質優先モード有効
        encoder.ultraLowLatencyMode = lowLatencyMode
        encoder.peakBitRateMultiplier = peakBitRateMultiplier
        
        // ★ Quality 値を反映
        encoder.qualityValue = Float(quality)
        
        // ★ コーデック選択
        encoder.codec = (codecIndex == 0) ? .h264 : .hevc
        
        // プロファイル設定
        switch profileIndex {
        case 0:
            encoder.profile = kVTProfileLevel_H264_Baseline_AutoLevel
        case 1:
            encoder.profile = kVTProfileLevel_H264_Main_AutoLevel
        case 2:
            encoder.profile = kVTProfileLevel_H264_High_AutoLevel
        default:
            encoder.profile = kVTProfileLevel_H264_Main_AutoLevel
        }
        
        let codecName = (codecIndex == 0) ? "H.264" : "HEVC"
        print("[CaptureViewModel] 設定更新: \(Int(bitRateMbps))Mbps, \(Int(targetFPS))fps, KF=\(Int(keyFrameInterval)), \(codecName), Quality=\(String(format: "%.2f", quality))")
        
        // ★ debounce: 連続呼び出し抑制
        settingsDebounceTask?.cancel()
        settingsDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
            guard !Task.isCancelled else { return }
            
            // キャプチャ中ならエンコーダーを再構成
            if isCapturing {
                encodedFrameCount = 0
                isEncoderReady = false
                print("[CaptureViewModel] ★ エンコーダー再構成をスケジュール")
                
                // キャプチャ設定も更新（フレームレート反映）
                do {
                    try await captureManager.updateResolutionScale(resolutionScale, fps: Int(targetFPS))
                } catch {
                    print("[CaptureViewModel] キャプチャ設定更新エラー: \(error)")
                }
            }
        }
    }
    
    /// 解像度スケールを適用
    private func applyResolutionScale() {
        guard isCapturing else { return }
        
        // ★ debounce: 連続呼び出し抑制
        resolutionDebounceTask?.cancel()
        resolutionDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
            guard !Task.isCancelled else { return }
            
            do {
                try await captureManager.updateResolutionScale(resolutionScale, fps: Int(targetFPS))
                // 解像度変更時もエンコーダー再構成
                encodedFrameCount = 0
                isEncoderReady = false
                print("[CaptureViewModel] 解像度スケール更新: \(resolutionScale)")
            } catch {
                print("[CaptureViewModel] 解像度更新エラー: \(error)")
            }
        }
    }
    
    /// 設定を最高値に設定
    func setMaxQuality() {
        bitRateMbps = 100
        targetFPS = 120
        keyFrameInterval = 1
        resolutionScale = 1.0
        profileIndex = 2  // High
    }
    
    /// 設定を最低値に設定
    func setMinQuality() {
        bitRateMbps = 1
        targetFPS = 15
        keyFrameInterval = 120
        resolutionScale = 0.25
        profileIndex = 0  // Baseline
    }
    
    // MARK: - Authentication Methods
    
    /// 接続リクエストを処理（NetworkSenderから呼ばれる）
    func handleAuthRequest(host: String, port: UInt16, userRecordID: String?) {
        // ★ 最優先: 同じApple IDなら全ての認証をスキップして即許可
        // 「自分のデバイス同士 = 完全に信頼」
        if let clientUserRecordID = userRecordID {
            Task {
                let isSameAppleID = await CloudKitManager.shared.isSameAppleID(as: clientUserRecordID)
                
                if isSameAppleID {
                    // 同じApple ID → 即座に許可（全ての認証をバイパス）
                    networkSender.approveClient(host: host, port: port)
                    print("[CaptureViewModel] ✅ 同一Apple ID - 認証スキップで即許可: \(host):\(port)")
                    return
                }
                
                // 異なるApple ID → 常に認証を要求（設定に関係なく）
                await self.requireAuthForDifferentAppleID(host: host, port: port)
            }
            return
        }
        
        // userRecordIDがない場合 → 設定に従う
        processUnknownDeviceAuth(host: host, port: port)
    }
    
    /// 異なるApple IDの場合の認証（常に認証を要求）
    @MainActor
    private func requireAuthForDifferentAppleID(host: String, port: UInt16) {
        // ロック中は拒否
        guard !isAuthLocked else {
            networkSender.denyClient(host: host, port: port)
            print("[CaptureViewModel] ❌ 認証ロック中 - 拒否: \(host):\(port)")
            return
        }
        
        // 異なるApple IDは常に認証ダイアログを表示（設定に関係なく）
        pendingAuthClient = PendingClient(host: host, port: port, requestTime: Date())
        print("[CaptureViewModel] ⚠️ 異なるApple ID - 認証が必要: \(host):\(port)")
    }
    
    /// 不明なデバイス（userRecordIDなし）の認証
    private func processUnknownDeviceAuth(host: String, port: UInt16) {
        // 認証不要設定の場合は即許可
        guard requireAuthentication else {
            networkSender.approveClient(host: host, port: port)
            print("[CaptureViewModel] 認証不要設定 - 即許可: \(host):\(port)")
            return
        }
        
        // ロック中は拒否
        guard !isAuthLocked else {
            networkSender.denyClient(host: host, port: port)
            print("[CaptureViewModel] ❌ 認証ロック中 - 拒否: \(host):\(port)")
            return
        }
        
        // 認証ダイアログを表示
        pendingAuthClient = PendingClient(host: host, port: port, requestTime: Date())
        print("[CaptureViewModel] 認証リクエスト受信（Apple ID不明）: \(host):\(port)")
    }
    
    /// 接続を許可（Macシステム認証）
    func approveWithSystemAuth() {
        guard let client = pendingAuthClient else { return }
        
        let context = LAContext()
        var error: NSError?
        
        // Touch ID / パスワード認証が利用可能かチェック
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "リモート接続を許可するには認証してください"
            ) { [weak self] success, authError in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    if success {
                        // 認証成功
                        self.networkSender.approveClient(host: client.host, port: client.port)
                        self.pendingAuthClient = nil
                        self.authFailureCount = 0
                        print("[CaptureViewModel] ✅ システム認証成功: \(client.host)")
                    } else {
                        // 認証失敗
                        self.authFailureCount += 1
                        
                        if self.authFailureCount >= 3 {
                            // 3回失敗でロック
                            self.isAuthLocked = true
                            self.networkSender.denyClient(host: client.host, port: client.port)
                            self.pendingAuthClient = nil
                            
                            // 30秒後にロック解除
                            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                                self?.isAuthLocked = false
                                self?.authFailureCount = 0
                            }
                            print("[CaptureViewModel] 🔒 認証ロック: 30秒後に解除")
                        } else {
                            print("[CaptureViewModel] ❌ 認証失敗: \(self.authFailureCount)/3")
                        }
                    }
                }
            }
        } else {
            // 認証機能が利用できない場合はエラーログ
            print("[CaptureViewModel] ⚠️ システム認証が利用できません: \(error?.localizedDescription ?? "不明")")
        }
    }
    
    /// 接続を拒否
    func denyConnection() {
        guard let client = pendingAuthClient else { return }
        
        networkSender.denyClient(host: client.host, port: client.port)
        pendingAuthClient = nil
        print("[CaptureViewModel] 接続拒否: \(client.host)")
    }
}

// MARK: - ScreenCaptureDelegate

extension CaptureViewModel: ScreenCaptureDelegate {
    nonisolated func screenCapture(_ manager: ScreenCaptureManager, didCaptureFrame sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        Task { @MainActor in
            // ★ キャプチャ停止後のフレームは無視
            guard isCapturing else { return }
            
            // エンコーダーをセットアップ（初回または再起動時）
            if !isEncoderReady {
                let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
                let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
                
                do {
                    try encoder.setup(width: width, height: height)
                    isEncoderReady = true
                } catch {
                    captureError = "エンコーダー初期化失敗: \(error.localizedDescription)"
                    return
                }
            }
            
            // エンコード
            encoder.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime, duration: duration)
        }
    }
    
    nonisolated func screenCapture(_ manager: ScreenCaptureManager, didFailWithError error: Error) {
        Task { @MainActor in
            captureError = "キャプチャエラー: \(error.localizedDescription)"
            isCapturing = false
        }
    }
    
    /// ★ Dirty Rects付きフレームをキャプチャ（ハイブリッドモード対応）
    nonisolated func screenCapture(_ manager: ScreenCaptureManager, didCaptureFrame sampleBuffer: CMSampleBuffer, dirtyRects: [CGRect]) {
        // ハイブリッドモードでない場合は通常処理
        Task { @MainActor in
            guard hybridMode else {
                // 通常モード: HEVC エンコード
                processFrameAsHEVC(sampleBuffer)
                return
            }
            
            // ═══════════════════════════════════════════
            // ★ ハイブリッドモード: 動き検出
            // ═══════════════════════════════════════════
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            
            let frameWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let frameHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            let frameArea = frameWidth * frameHeight
            
            // Dirty Rects の総面積を計算
            let dirtyArea = dirtyRects.reduce(0.0) { $0 + $1.width * $1.height }
            let motionRatio = dirtyArea / frameArea
            
            if motionRatio < motionThreshold {
                // ★ 動きが少ない → 静止フレームカウント増加
                staticFrameCount += 1
                
                if staticFrameCount >= staticFrameThreshold {
                    // ★ 接続安定化タイマーが未設定の場合、自動で設定
                    // (didConnectToClient が呼ばれなかった場合の救済措置)
                    if connectionStabilizedTime == nil && connectedClients > 0 {
                        connectionStabilizedTime = Date()
                        print("[CaptureViewModel] ★ 接続安定化タイマー自動設定（PNG送信を2秒後に許可）")
                    }
                    
                    // ★ 接続安定化待機中はPNG送信をスキップ
                    if let stabilizedTime = connectionStabilizedTime {
                        let elapsed = Date().timeIntervalSince(stabilizedTime)
                        if elapsed < 2.0 {
                            if staticFrameCount % 30 == 0 {
                                print("[CaptureViewModel] ⏳ PNG待機: 安定化期間中 (残り\(String(format: "%.1f", 2.0 - elapsed))秒)")
                            }
                            currentMode = "VIDEO"
                            processFrameAsHEVC(sampleBuffer)
                            return
                        }
                    }
                    
                    // ★ 静止判定 → PNG 高品質送信 (ネイティブ解像度)
                    if currentMode != "PNG" {
                        print("[CaptureViewModel] 📸 静止画モード移行: PNG送信準備開始")
                    }
                    currentMode = "PNG"
                    
                    // ★ 排他制御: NetworkSenderがPNG送信中なら新しいPNGを送らない
                    if networkSender.isPNGSending {
                        return
                    }
                    
                    // ★ 頻度制御: 1秒以内なら送信しない
                    if let lastTime = lastPNGSendTime, Date().timeIntervalSince(lastTime) < 1.0 {
                        return
                    }
                    lastPNGSendTime = Date()
                    
                    // ★ PNG送信Taskを開始
                    Task {
                        do {
                            // VideoStreamは縮小されている可能性があるため、別途フル解像度を取得
                            let highResImage = try await captureManager.captureNativeResolutionSnapshot()
                            await sendHighResPNG(highResImage)
                        } catch {
                            print("[CaptureViewModel] 高解像度キャプチャ失敗: \(error)")
                            // フォールバック: 動画モード継続
                            await MainActor.run {
                                currentMode = "VIDEO"
                            }
                        }
                    }
                    return
                }
            } else {
                // ★ 動きあり → カウントリセット
                staticFrameCount = 0
            }
            
            // ★ 動画モード → HEVC エンコード (設定によってはH.264)
            currentMode = "VIDEO"
            processFrameAsHEVC(sampleBuffer)
        }
    }
    
    /// ★ HEVC/H.264 エンコード処理
    @MainActor
    private func processFrameAsHEVC(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        if !isEncoderReady {
            let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
            
            do {
                try encoder.setup(width: width, height: height)
                isEncoderReady = true
            } catch {
                print("[CaptureViewModel] エンコーダーセットアップエラー: \(error)")
                return
            }
        }
        
        encoder.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime, duration: duration)
    }
    
    /// ★ 高解像度スナップショット (CGImage) を PNG (可逆圧縮) で送信
    @MainActor
    private func sendHighResPNG(_ cgImage: CGImage) {
        // ★ ImageIO を使用して PNG 生成 (可逆圧縮 = 劣化ゼロ)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return }
        
        let options: [CFString: Any] = [
            kCGImagePropertyDepth: 8,
            kCGImageDestinationOptimizeColorForSharing: false
        ]
        
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            print("[CaptureViewModel] PNG生成失敗: CGImage")
            return
        }
        let pngData = data as Data
        
        // ★ 生データを送信
        if isNetworkMode {
            print("[CaptureViewModel] 📤 NetworkSenderへPNGデータ渡し: \(pngData.count) bytes")
            networkSender.sendPNGFrame(pngData)
        }
        
        pngSendCount += 1
        if pngSendCount == 1 || pngSendCount % 100 == 0 {
            print("[CaptureViewModel] 🚀 PNG送信完了: \(pngData.count / 1024)KB (累計\(pngSendCount)回)")
        }
    }

    // sendAsJPEG は廃止 (PNG完全移行)
    
    // createJPEGPacket は独自ヘッダーとなるため廃止
}

// MARK: - VideoEncoderDelegate

extension CaptureViewModel: VideoEncoderDelegate {
    nonisolated func videoEncoder(_ encoder: VideoEncoder, didOutputVPS vps: Data) {
        Task { @MainActor in
            vpsData = vps
            
            if isLoopbackMode {
                // ローカルループバック: 直接デコーダーに渡す
                decoder.setVPS(vps)
            }
            
            if isNetworkMode {
                // ネットワーク送信
                networkSender.sendVPS(vps)
            }
        }
    }
    
    nonisolated func videoEncoder(_ encoder: VideoEncoder, didOutputSPS sps: Data) {
        Task { @MainActor in
            spsData = sps
            
            if isLoopbackMode {
                // ローカルループバック: 直接デコーダーに渡す
                decoder.setSPS(sps)
            }
            
            if isNetworkMode {
                // ネットワーク送信
                networkSender.sendSPS(sps)
            }
        }
    }
    
    nonisolated func videoEncoder(_ encoder: VideoEncoder, didOutputPPS pps: Data) {
        Task { @MainActor in
            ppsData = pps
            
            if isLoopbackMode {
                // ローカルループバック: 直接デコーダーに渡す
                decoder.setPPS(pps)
            }
            
            if isNetworkMode {
                // ネットワーク送信
                networkSender.sendPPS(pps)
            }
        }
    }
    
    nonisolated func videoEncoder(_ encoder: VideoEncoder, didOutputEncodedData data: Data, isKeyFrame: Bool, presentationTime: CMTime) {
        Task { @MainActor in
            encodedFrameCount += 1
            
            if isLoopbackMode {
                // ローカルループバック: 直接デコーダーに渡す
                decoder.decode(annexBData: data, presentationTime: presentationTime)
            }
            
            if isNetworkMode {
                // ネットワーク送信
                let timestamp = UInt64(presentationTime.seconds * 1_000_000_000)
                networkSender.sendVideoFrame(data, isKeyFrame: isKeyFrame, timestamp: timestamp)
            }
        }
    }
    
    nonisolated func videoEncoder(_ encoder: VideoEncoder, didFailWithError error: Error) {
        Task { @MainActor in
            captureError = "エンコードエラー: \(error.localizedDescription)"
        }
    }
}

// MARK: - VideoDecoderDelegate

extension CaptureViewModel: VideoDecoderDelegate {
    nonisolated func videoDecoder(_ decoder: VideoDecoder, didOutputPixelBuffer pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        Task { @MainActor in
            decodedFrameCount += 1
            
            // プレビューに表示
            previewCoordinator.display(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        }
    }
    
    nonisolated func videoDecoder(_ decoder: VideoDecoder, didFailWithError error: Error) {
        Task { @MainActor in
            captureError = "デコードエラー: \(error.localizedDescription)"
        }
    }
}

// MARK: - NetworkSenderDelegate

extension CaptureViewModel: NetworkSenderDelegate {
    nonisolated func networkSender(_ sender: NetworkSender, didChangeState state: NetworkSender.ConnectionState) {
        Task { @MainActor in
            switch state {
            case .idle:
                isListening = false
            case .listening:
                isListening = true
            case .ready:
                isListening = true
            case .failed(let error):
                captureError = "ネットワークエラー: \(error.localizedDescription)"
                isListening = false
            }
        }
    }
    
    nonisolated func networkSender(_ sender: NetworkSender, didFailWithError error: Error) {
        Task { @MainActor in
            captureError = "送信エラー: \(error.localizedDescription)"
        }
    }
    
    nonisolated func networkSender(_ sender: NetworkSender, didConnectToClient endpoint: String) {
        Task { @MainActor in
            connectedClients = sender.clientCount
            print("[CaptureViewModel] クライアント接続: \(endpoint), 合計: \(connectedClients)")
            
            // クライアント接続時に自動でネットワークモードを有効化
            if connectedClients > 0 && !isNetworkMode {
                isNetworkMode = true
                print("[CaptureViewModel] ネットワークモード自動有効化")
            }
            
            // ★ オンデマンドキャプチャ: キャプチャ未開始なら自動開始
            if !isCapturing {
                print("[CaptureViewModel] ⚡ オンデマンドキャプチャ開始")
                await startCapture()
                
                // キャプチャ開始待機（エンコーダー初期化まで少し待つ）
                try? await Task.sleep(nanoseconds: 200 * 1_000_000)
            }
            
            // ネットワーク通信安定化のための少しの遅延 (50ms)
            try? await Task.sleep(nanoseconds: 50 * 1_000_000)
            
            // ★ VPS/SPS/PPSをキャッシュから送信（HEVC の場合は VPS → SPS → PPS の順序）
            if let vps = vpsData {
                print("[CaptureViewModel] VPS送信: \(vps.count)バイト")
                networkSender.sendVPS(vps)
                try? await Task.sleep(nanoseconds: 30 * 1_000_000)
            }
            
            if let sps = spsData {
                print("[CaptureViewModel] SPS送信: \(sps.count)バイト")
                networkSender.sendSPS(sps)
                try? await Task.sleep(nanoseconds: 30 * 1_000_000)
            } else {
                print("[CaptureViewModel] ⚠️ SPSキャッシュが空")
            }
            
            if let pps = ppsData {
                print("[CaptureViewModel] PPS送信: \(pps.count)バイト")
                networkSender.sendPPS(pps)
                try? await Task.sleep(nanoseconds: 30 * 1_000_000)
            } else {
                print("[CaptureViewModel] ⚠️ PPSキャッシュが空")
            }
            
            // 新しいキーフレームを強制（次のフレームで適用）
            print("[CaptureViewModel] キーフレーム強制リクエスト")
            encoder.forceKeyFrame()
            
            // ★ 接続安定化タイマー開始（PNG送信を2秒間無効化）
            connectionStabilizedTime = Date()
            print("[CaptureViewModel] ★ 接続安定化期間開始（PNG送信を2秒間無効化）")
        }
    }
    
    nonisolated func networkSender(_ sender: NetworkSender, didDisconnectClient endpoint: String, remainingClients: Int) {
        Task { @MainActor in
            connectedClients = remainingClients
            print("[CaptureViewModel] クライアント切断: \(endpoint), 残り: \(remainingClients)")
            
            // ★ オンデマンドキャプチャ: 全クライアント切断時にキャプチャ停止
            if remainingClients == 0 && isCapturing {
                print("[CaptureViewModel] ⚡ オンデマンドキャプチャ停止（全クライアント切断）")
                await stopCapture()
                isNetworkMode = false
            }
        }
    }
    
    nonisolated func networkSender(_ sender: NetworkSender, didReceiveAuthRequest host: String, port: UInt16, userRecordID: String?) {
        Task { @MainActor in
            handleAuthRequest(host: host, port: port, userRecordID: userRecordID)
        }
    }
}

// MARK: - NetworkQualityMonitorDelegate (Phase 1: 適応型品質制御)

extension CaptureViewModel: NetworkQualityMonitorDelegate {
    
    nonisolated func networkQualityMonitor(_ monitor: NetworkQualityMonitor, didChangeQuality quality: NetworkQualityLevel) {
        Task { @MainActor in
            networkQualityDisplay = quality.rawValue
            
            // 適応型品質制御が有効な場合のみ自動調整
            guard adaptiveQualityMode else { return }
            
            applyAdaptiveQuality(quality)
        }
    }
    
    nonisolated func networkQualityMonitor(_ monitor: NetworkQualityMonitor, didUpdateMetrics metrics: NetworkQualityMetrics) {
        // メトリクス更新時の処理（必要に応じて実装）
    }
    
    /// 品質レベルに応じてエンコーダーパラメータを自動調整
    @MainActor
    private func applyAdaptiveQuality(_ quality: NetworkQualityLevel) {
        let previousBitrate = bitRateMbps
        let previousFPS = targetFPS
        
        // 品質レベルに応じた推奨値を適用
        bitRateMbps = Double(quality.recommendedBitrateMbps)
        targetFPS = Double(quality.recommendedFPS)
        resolutionScale = quality.recommendedResolutionScale
        
        // 変更があった場合のみログ出力
        if previousBitrate != bitRateMbps || previousFPS != targetFPS {
            print("[CaptureViewModel] 🔄 適応型品質調整: \(quality.rawValue) → \(Int(bitRateMbps))Mbps, \(Int(targetFPS))fps, scale=\(resolutionScale)")
        }
    }
}

// MARK: - InputReceiverDelegate

extension CaptureViewModel: InputReceiverDelegate {
    nonisolated func inputReceiver(_ receiver: InputReceiver, didReceiveEvent type: String) {
        // 通常の入力イベント（ログ抑制のため何もしない）
    }
    
    nonisolated func inputReceiver(_ receiver: InputReceiver, didFailWithError error: Error) {
        Task { @MainActor in
            print("[CaptureViewModel] ⚠️ InputReceiver エラー: \(error)")
        }
    }
    
    nonisolated func inputReceiver(_ receiver: InputReceiver, didReceiveZoomRequest isZooming: Bool, rect: CGRect, scale: CGFloat) {
        Task { @MainActor in
            // 状態変化時のみログ出力
            if isZooming != lastZoomState {
                if isZooming {
                    print("[CaptureViewModel] 🔍 ズーム開始: \(String(format: "%.1f", scale))x")
                } else {
                    print("[CaptureViewModel] 🔍 ズーム解除")
                }
                lastZoomState = isZooming
            }
        }
    }
    
    /// ★ InputReceiver経由で登録を受信
    nonisolated func inputReceiver(_ receiver: InputReceiver, didReceiveRegistration listenPort: UInt16, userRecordID: String?, clientHost: String) {
        Task { @MainActor in
            print("[CaptureViewModel] 🔔 クライアント登録: \(clientHost):\(listenPort)")
            
            // NetworkSenderにクライアント登録を転送
            networkSender.registerClientFromInput(host: clientHost, port: listenPort, userRecordID: userRecordID)
        }
    }
}
