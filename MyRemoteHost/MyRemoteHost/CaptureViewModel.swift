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
        didSet { guard !suppressDidSet else { return }; applyEncoderSettings() }
    }
    
    /// フレームレート - 範囲: 15-120
    @Published var targetFPS: Double = 60 {
        didSet { guard !suppressDidSet else { return }; applyEncoderSettings() }
    }
    
    /// キーフレーム間隔 - 範囲: 1-120
    /// ★初期値: 60 (動画モードでの圧縮効率とスムーズさを優先)
    @Published var keyFrameInterval: Double = 60 {
        didSet { guard !suppressDidSet else { return }; applyEncoderSettings() }
    }
    
    /// 解像度スケール - 範囲: 0.25-1.0
    @Published var resolutionScale: Double = 1.0 {
        didSet { guard !suppressDidSet else { return }; applyResolutionScale() }
    }
    
    /// プロファイル (0=Baseline, 1=Main, 2=High)
    @Published var profileIndex: Int = 2 {
        didSet { guard !suppressDidSet else { return }; applyEncoderSettings() }
    }
    
    // MARK: - 詳細設定 (新規追加)
    
    /// ★ 品質 (Quality) - 範囲: 0.5-1.0 (高いほど高品質)
    /// ★初期値: 0.65 (動画モード中の負荷軽減)
    @Published var quality: Double = 0.65 {
        didSet { guard !suppressDidSet else { return }; applyEncoderSettings() }
    }
    
    /// ★ コーデック選択 (0=H.264, 1=HEVC)
    @Published var codecIndex: Int = 1 {
        didSet { guard !suppressDidSet else { return }; applyEncoderSettings() }
    }
    
    /// ★ 低遅延モード
    @Published var lowLatencyMode: Bool = true {
        didSet { guard !suppressDidSet else { return }; applyEncoderSettings() }
    }
    
    /// ★ ピークビットレート倍率 - 範囲: 1.0-3.0
    @Published var peakBitRateMultiplier: Double = 2.0 {
        didSet { guard !suppressDidSet else { return }; applyEncoderSettings() }
    }
    
    /// ★ 適応型品質制御モード (Phase 1)
    /// ネットワーク状況に応じてビットレート/FPS/解像度を自動調整
    @Published var adaptiveQualityMode: Bool = true
    
    /// ★ エンコーダ再構成中フラグ（stopCapture競合防止）
    private var isReconfiguringEncoder = false
    
    /// ★ 現在のネットワーク品質レベル表示
    @Published var networkQualityDisplay: String = "Good"
    
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
    /// ★ Phase 2: nonisolated(unsafe) — キャプチャキューから直接encode()を呼べるように
    nonisolated(unsafe) let encoder = VideoEncoder()
    let decoder = VideoDecoder()
    let previewCoordinator = PreviewViewCoordinator()
    
    /// ★ Phase 5: ネットワークセッションマネージャ
    let sessionManager = NetworkSessionManager()
    
    /// ★ Phase 5: 認証マネージャ
    let authManager = AuthenticationManager()
    
    /// ★ Phase 1: デバイスセンサー
    let deviceSensor = DeviceSensor()
    
    /// ★ Phase 3: 適応型品質エンジン
    private(set) var adaptiveQualityEngine = AdaptiveQualityEngine()
    

    
    // networkSender, inputReceiver, networkQualityMonitor は sessionManager が保持
    var networkSender: NetworkSender { return sessionManager.sender } // 互換性のため
    /// ★ 最適化 1-A: nonisolatedから安全にアクセスするための直接参照
    /// NetworkSenderは内部でsendQueueを使用するためスレッドセーフ
    nonisolated(unsafe) private lazy var _networkSenderRef: NetworkSender = sessionManager.sender
    var inputReceiver: InputReceiver { return sessionManager.inputReceiver }
    var networkQualityMonitor: NetworkQualityMonitor { return sessionManager.qualityMonitor }
    
    /// ★ A-2: P2PConnectionManager（TURN Allocation維持用）
    private var p2pManager = P2PConnectionManager()
    
    /// 現在のキャプチャスケール（1.0 or 2.0）
    @Published var currentCaptureScale: CGFloat = 1.0
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private var vpsData: Data?  // HEVC用
    private var spsData: Data?
    private var ppsData: Data?
    
    /// ★ キャプチャ開始中フラグ（二重開始防止）
    private var isStartingCapture = false
    
    /// ★ エンコーダー初期化済みフラグ
    private var isEncoderReady = false
    
    /// ★ AutoPilot一括設定中はdidSetを抑制（カスケード防止）
    private var suppressDidSet = false
    
    /// ★ 設定更新debounceタイマー
    private var settingsDebounceTask: Task<Void, Never>?
    private var resolutionDebounceTask: Task<Void, Never>?
    
    /// 前回のズーム状態
    private var lastZoomState: Bool = false
    
    // MARK: - Pipeline Latency Measurement (Phase 1)
    /// キャプチャコールバック受信時刻 (CFAbsoluteTime)
    private var lastCaptureTimestamp: CFAbsoluteTime = 0
    /// エンコード開始時刻 (CFAbsoluteTime)
    private var lastEncodeStartTimestamp: CFAbsoluteTime = 0
    /// パイプライン遅延計測の移動平均 (EMA)
    private var emaCaptureToEncodeMs: Double = 0
    private var emaEncodeDurationMs: Double = 0
    private var emaPacketizeMs: Double = 0
    /// EMAの平滑化係数 (0.1 = 安定性重視)
    private let emaAlpha: Double = 0.1
    /// フレームドロップカウンター
    private var pipelineFrameDropCount: Int = 0
    
    // MARK: - Initialization
    
    init() {
        setupBindings()
        setupDelegates()
        setupAdaptiveQualityEngine()
    }
    
    /// ★ Phase 3: 適応型品質エンジンの初期化
    private func setupAdaptiveQualityEngine() {
        adaptiveQualityEngine.onQualityChanged = { [weak self] decision in
            guard let self = self else { return }
            Task { @MainActor in
                self.applyQualityDecision(decision)
            }
        }
    }
    
    /// ★ Omniscient Auto-Pilot: 全パラメータ決定を適用
    @MainActor
    private func applyQualityDecision(_ decision: QualityDecision) {
        let previousScale = currentCaptureScale
        let previousCodec = codecIndex
        
        Logger.pipeline("★ applyQualityDecision開始: \(decision.reason)", sampling: .always)
        
        // ★ didSetカスケード抑制: 一括設定中はdidSetを発火させない
        suppressDidSet = true
        
        // === Encoding Parameters ===
        // ★ Phase 1: TURN接続時は品質制限（キーフレームサイズ削減）
        var effectiveBitRate = decision.bitRateMbps
        var effectiveFPS = decision.targetFPS
        var effectiveResScale = decision.resolutionScale
        var effectiveKFInterval = decision.keyFrameInterval
        if networkSender.isTURNMode {
            effectiveBitRate = min(decision.bitRateMbps, 15.0)      // 最大15Mbps
            effectiveFPS = min(decision.targetFPS, 30.0)            // 最大30fps
            effectiveResScale = min(decision.resolutionScale, 0.5)  // 最大50%
            effectiveKFInterval = max(decision.keyFrameInterval, 120) // 最低120フレーム間隔
        }
        
        bitRateMbps = effectiveBitRate
        targetFPS = effectiveFPS
        keyFrameInterval = Double(effectiveKFInterval)
        quality = Double(decision.qualityValue)
        encoder.qualityValue = decision.qualityValue
        
        // コーデック切替 (エンコーダ再構成あり)
        // ★ TURN経由ではコーデック切替を抑制（再構成によるキーフレーム欠落を防止）
        if decision.codecIndex != previousCodec && !networkSender.isTURNMode {
            codecIndex = decision.codecIndex
            Logger.pipeline("🔄 コーデック切替: \(decision.codecIndex == 0 ? "H.264" : "HEVC")", sampling: .always)
            
            // ★ セーフティネット: コーデック切替後に新しいパラメータセットを再送
            // エンコーダ再構成完了後、新しいVPS/SPS/PPSが生成されたらiPhoneに送信
            Task { @MainActor in
                // エンコーダ再構成待ち（200ms）
                try? await Task.sleep(nanoseconds: 300_000_000)
                
                // 新しいパラメータセットを再送
                if let vps = self.vpsData {
                    self.sessionManager.sendVPS(vps)
                    Logger.pipeline("🔄 VPS再送: \(vps.count)bytes", sampling: .always)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                if let sps = self.spsData {
                    self.sessionManager.sendSPS(sps)
                    Logger.pipeline("🔄 SPS再送: \(sps.count)bytes", sampling: .always)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                if let pps = self.ppsData {
                    self.sessionManager.sendPPS(pps)
                    Logger.pipeline("🔄 PPS再送: \(pps.count)bytes", sampling: .always)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                
                // キーフレーム強制
                self.encoder.forceKeyFrame()
                Logger.pipeline("🔄 コーデック切替後キーフレーム強制", sampling: .always)
            }
        }
        
        // プロファイル
        profileIndex = decision.profileIndex
        
        // === Capture Parameters ===
        resolutionScale = effectiveResScale
        
        // === Transport Parameters ===
        lowLatencyMode = decision.lowLatencyMode
        peakBitRateMultiplier = decision.peakMultiplier
        
        // ★ didSet抑制解除
        suppressDidSet = false
        
        // ★ 1回だけエンコーダ設定を適用（didSetカスケードの代わり）
        applyEncoderSettings()
        
        Logger.pipeline("✅ applyQualityDecision完了: BR=\(Int(effectiveBitRate))M FPS=\(Int(effectiveFPS)) Scale=\(decision.captureScale) Codec=\(decision.codecIndex == 0 ? "H.264" : "HEVC")\(networkSender.isTURNMode ? " [TURN制限]" : "")", sampling: .always)
        
        // captureScale変更 → Retina切替 + ★ Phase 2: プリウォーム
        if decision.captureScale != previousScale {
            currentCaptureScale = decision.captureScale
            
            // ★ 再構成中フラグON（onClientDisconnected競合防止）
            isReconfiguringEncoder = true
            Logger.pipeline("★ エンコーダ再構成開始 (isReconfiguringEncoder=true)", sampling: .always)
            
            // ★ Phase 2: 新解像度のセッションを裏で準備
            if let display = captureManager.selectedDisplay {
                let newScale = min(Double(captureManager.captureWidth) / Double(display.width), decision.captureScale)
                var newWidth = Int32(Double(display.width) * newScale)
                var newHeight = Int32(Double(display.height) * newScale)
                newWidth += (newWidth % 2 == 0 ? 0 : 1)  // 偶数補正
                newHeight += (newHeight % 2 == 0 ? 0 : 1)
                encoder.prewarmSession(width: newWidth, height: newHeight)
            }
            
            isEncoderReady = false
            adaptiveQualityEngine.encoderLoad.pauseTracking()  // ★ 再構成中のFrameDrop誤検知防止
            
            Task {
                do {
                    try await captureManager.updateRetinaScale(
                        decision.captureScale,
                        fps: Int(decision.targetFPS)
                    )
                    // ★ Phase 2: プリウォーム済みセッションに切替（フレーム停止なし）
                    if encoder.swapToPrewarmedSession() {
                        isEncoderReady = true
                        Logger.pipeline("★ プリウォーム切替完了", sampling: .always)
                    }
                    Logger.pipeline("★ Retina切替完了: \(decision.captureScale)x", sampling: .always)
                } catch {
                    Logger.pipeline("⚠️ Retina切替失敗: \(error)", level: .warning, sampling: .always)
                }
                
                // ★ 再構成完了: フラグOFF
                isReconfiguringEncoder = false
                Logger.pipeline("★ エンコーダ再構成完了 (isReconfiguringEncoder=false)", sampling: .always)
            }
        }
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
            deviceSensor.startMonitoring()           // ★ Phase 1: デバイスモニタリング開始
            isListening = true
            
            // ★ Phase 1: CloudKitにデバイス登録
            Task {
                await registerToCloudKit()
            }
            // ★ Phase 2: OmniscientState定期送信開始
            startOmniscientStateTransmission()
            
        } catch {
            print("[CaptureViewModel] ❌ ネットワーク開始失敗: \(error)")
            captureError = "ネットワーク開始失敗: \(error.localizedDescription)"
        }
    }
    
    /// ★ Phase 2: OmniscientState定期送信
    private func startOmniscientStateTransmission() {
        // 既存のタスクがあればキャンセル
        omniscientStateTask?.cancel()
        
        omniscientStateTask = Task {
            while !Task.isCancelled {
                // 接続中のクライアントがいれば送信
                if isListening && connectedClients > 0 {
                    let state = adaptiveQualityEngine.currentOmniscientState
                    networkSender.sendOmniscientState(state)
                }
                
                // 0.5秒ごとに送信（HUD更新頻度）
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    
    private var omniscientStateTask: Task<Void, Error>?
    
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
                localPort: Int(NetworkTransportConfiguration.default.videoPort)
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
            // ★ A-2: p2pManagerをプロパティとして保持（TURN Allocation維持）
            let candidates = try await p2pManager.gatherCandidates(localPort: Int(NetworkTransportConfiguration.default.videoPort))
            
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
            
            // ★ A-2: TURN Allocation状態をログ
            let turnClient = await p2pManager.activeTURNClient
            if turnClient != nil {
                print("[CaptureViewModel] 🔄 TURN Allocation維持中（relay準備完了）")
                // ★ A-2: TURN受信ループを開始（iPhone側からのTURN経由パケットを待機）
                await enableTURNReception()
            }
            
            print("[CaptureViewModel] 📤 ICE候補保存完了: \(candidates.count)件")
        } catch {
            print("[CaptureViewModel] ⚠️ STUN/ICE候補収集失敗（ローカル接続のみ）: \(error.localizedDescription)")
            // STUN失敗してもローカル接続は継続
        }
    }
    
    // MARK: - ★ A-2: TURN Relay統合
    
    /// TURN経由のデータ受信を有効化
    /// iPhone側がTURN relay経由で登録パケットを送信してきた場合に自動検出し、
    /// TURNモードに切り替える
    private func enableTURNReception() async {
        guard let turnClient = await p2pManager.activeTURNClient else {
            print("[CaptureViewModel] ⚠️ TURN受信設定スキップ: TURNClient未確立")
            return
        }
        
        // TURN受信コールバックを設定
        await turnClient.setDataHandler { [weak self] data in
            guard let self = self else { return }
            
            // 受信データを解析
            guard data.count >= 1 else { return }
            
            let packetType = data[0]
            
            if packetType == 0xFE && data.count >= 3 {
                // ★ 登録パケット受信 → TURNモードに切替
                print("[CaptureViewModel] 🔔 TURN経由で登録パケット受信! TURNモードに切替")
                
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    
                    // 登録パケット解析:
                    // [0xFE][port:2B][relayIP:NUL-terminated][relayPort:2B][userRecordID]
                    let clientPort = UInt16(data[1]) << 8 | UInt16(data[2])
                    
                    // relayIPを解析（NULL終端文字列）
                    var relayIP = ""
                    var relayPort: UInt16 = 0
                    var userRecordID = ""
                    
                    var offset = 3
                    // relayIP: NULL終端まで読む
                    if let nullIndex = data[offset...].firstIndex(of: 0x00) {
                        relayIP = String(data: data[offset..<nullIndex], encoding: .utf8) ?? ""
                        offset = nullIndex + 1  // NULL byte skip
                        // relayPort: 2バイト BigEndian
                        if offset + 2 <= data.count {
                            relayPort = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
                            offset += 2
                            // 残りはuserRecordID
                            if offset < data.count {
                                userRecordID = String(data: data[offset...], encoding: .utf8) ?? ""
                            }
                        }
                    }
                    
                    print("[CaptureViewModel] 📱 TURNクライアント登録: port=\(clientPort) relay=\(relayIP):\(relayPort) user=\(userRecordID)")
                    
                    // ★ A-2修正: Mac→iPhone送信先をiPhoneのrelayアドレスに設定
                    self.networkSender.turnClient = turnClient
                    self.networkSender.isTURNMode = true
                    self.networkSender.turnPeerIP = relayIP
                    self.networkSender.turnPeerPort = relayPort
                    self.connectedClients = 1
                    print("[CaptureViewModel] ✅ TURN送信モード有効化完了 → 送信先: \(relayIP):\(relayPort)")
                    
                    // ★ A-2修正: Mac側TURNクライアントでiPhoneのrelayに対してPermission+ChannelBind
                    if !relayIP.isEmpty && relayPort > 0 {
                        do {
                            try await turnClient.createPermission(for: relayIP, peerPort: relayPort)
                            print("[CaptureViewModel] ✅ TURN Permission作成: \(relayIP):\(relayPort)")
                            
                            let channel = try await turnClient.channelBind(peerIP: relayIP, peerPort: relayPort)
                            print("[CaptureViewModel] ✅ TURN ChannelBind完了: ch=\(String(format: "0x%04X", channel)) → \(relayIP):\(relayPort)")
                        } catch {
                            print("[CaptureViewModel] ⚠️ TURN Permission/ChannelBind失敗: \(error) - SendIndication fallbackで送信")
                        }
                    }
                    
                    // ★ A-6: TURN接続でもSPS/PPS→KeyFrame即送信
                    // 直接接続のonClientConnected(L687-718)と同等のフロー
                    if !self.isCapturing {
                        await self.startCapture()
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    
                    // ネットワーク安定化待機
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    
                    // VPS/SPS/PPS送信
                    if let vps = self.vpsData {
                        self.sessionManager.sendVPS(vps)
                        print("[CaptureViewModel] 📹 TURN経由VPS送信: \(vps.count)bytes")
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                    if let sps = self.spsData {
                        self.sessionManager.sendSPS(sps)
                        print("[CaptureViewModel] 📹 TURN経由SPS送信: \(sps.count)bytes")
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                    if let pps = self.ppsData {
                        self.sessionManager.sendPPS(pps)
                        print("[CaptureViewModel] 📹 TURN経由PPS送信: \(pps.count)bytes")
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                    
                    // KeyFrame強制
                    print("[CaptureViewModel] 🔑 TURN接続後キーフレーム強制送信")
                    self.encoder.forceKeyFrame()
                }
            } else if packetType == 0xFD {
                // ★ キーフレーム要求受信
                Task { @MainActor [weak self] in
                    self?.encoder.forceKeyFrame()
                    print("[CaptureViewModel] 🔑 TURN経由キーフレーム要求受信")
                }
            } else if packetType == 0xFF {
                // ★ 切断パケット受信
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.networkSender.isTURNMode = false
                    self.networkSender.turnClient = nil
                    self.connectedClients = 0
                    print("[CaptureViewModel] 🔌 TURN経由切断パケット受信")
                }
            }
        }
        
        print("[CaptureViewModel] 📡 TURN受信ループ開始 → iPhone接続を待機中")
    }
    
    /// TURN送信モードを有効化（外部から手動で呼べる）
    /// - Parameters:
    ///   - peerIP: iPhoneのTURN relayアドレスIP
    ///   - peerPort: iPhoneのTURN relayアドレスポート
    func enableTURNSending(peerIP: String, peerPort: UInt16) async {
        guard let turnClient = await p2pManager.activeTURNClient else {
            print("[CaptureViewModel] ❌ TURN送信有効化失敗: TURNClient未確立")
            return
        }
        
        do {
            // Permission作成（iPhone側からのデータ受信を許可）
            try await turnClient.createPermission(for: peerIP, peerPort: peerPort)
            print("[CaptureViewModel] ✅ TURN Permission作成: \(peerIP):\(peerPort)")
            
            // ChannelBind（効率的データ転送）
            let channel = try await turnClient.channelBind(peerIP: peerIP, peerPort: peerPort)
            print("[CaptureViewModel] ✅ TURN ChannelBind完了: ch=\(String(format: "0x%04X", channel))")
            
            // NetworkSenderにTURN送信モードを設定
            networkSender.turnClient = turnClient
            networkSender.isTURNMode = true
            
            print("[CaptureViewModel] ✅ TURN送信モード有効化完了")
        } catch {
            print("[CaptureViewModel] ❌ TURN送信設定失敗: \(error.localizedDescription)")
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
        deviceSensor.stopMonitoring()           // ★ Phase 1: デバイスモニタリング停止
        isListening = false
        connectedClients = 0
        
        // ★ Phase 2: 定期送信停止
        omniscientStateTask?.cancel()
        omniscientStateTask = nil
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
    func stopCapture(caller: String = #function, file: String = #file, line: Int = #line) async {
        let fileName = (file as NSString).lastPathComponent
        print("[CaptureViewModel] ⚠️ stopCapture() 呼び出し元: \(fileName):\(line) \(caller)")
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
            
        // ★ Phase 5: NetworkSessionManagerとの同期
        sessionManager.$isListening
            .receive(on: DispatchQueue.main)
            .assign(to: &$isListening)
            
        sessionManager.$connectedClients
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectedClients)
            
        sessionManager.$error
            .receive(on: DispatchQueue.main)
            .assign(to: &$captureError)
            
        // ★ Phase 5: AuthenticationManagerとの同期
        authManager.$pendingAuthClient
            .receive(on: DispatchQueue.main)
            .assign(to: &$pendingAuthClient)
            
        authManager.$isAuthLocked
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAuthLocked)
            
        authManager.$authFailureCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$authFailureCount)
            
        authManager.$requireAuthentication
            .receive(on: DispatchQueue.main)
            .assign(to: &$requireAuthentication)
            
        // 設定変更の逆同期（ViewModel -> Manager）
        $requireAuthentication
            .dropFirst()
            .sink { [weak self] value in
                self?.authManager.requireAuthentication = value
            }
            .store(in: &cancellables)
            
        // 認証コールバック設定 (SessionManagerへ委譲)
        authManager.onApprove = { [weak self] host, port in
            self?.sessionManager.approveClient(host: host, port: port)
            // ★ UDP経由でも認証結果を送信（TCP経路が通らない場合のバックアップ）
            self?.sessionManager.inputReceiver.sendAuthResult(approved: true, toHost: host, port: port)
        }
        
        authManager.onDeny = { [weak self] host, port in
            self?.sessionManager.denyClient(host: host, port: port)
        }
        
        // ★ SessionManagerからの認証リクエストをAuthManagerへ転送
        sessionManager.onAuthRequest = { [weak self] host, port, userRecordID in
            self?.authManager.handleAuthRequest(host: host, port: port, userRecordID: userRecordID)
        }
        
        // ★ Phase 3: クライアントからのキーフレーム要求をエンコーダに転送
        sessionManager.onKeyFrameRequest = { [weak self] in
            self?.encoder.forceKeyFrame()
            Logger.pipeline("★ キーフレーム強制送信（クライアント要求）")
        }
        
        // セッションコールバック設定
        sessionManager.onClientConnected = { [weak self] key in
            guard let self = self else { return }
            Logger.pipeline("★ クライアント接続: \(key), 接続数: \(self.sessionManager.connectedClients)", sampling: .always)
            print("[CaptureViewModel] クライアント接続: \(key) -> キャプチャ自動開始")
            
            Task { @MainActor in
                // 自動でネットワークモードを有効化
                if !self.isNetworkMode {
                    self.isNetworkMode = true
                    print("[CaptureViewModel] ネットワークモード自動有効化")
                }
                
                // 1. キャプチャ開始
                if !self.isCapturing {
                    await self.startCapture()
                    // エンコーダー初期化待ち
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                
                // 2. ネットワーク通信安定化待機
                try? await Task.sleep(nanoseconds: 50_000_000)
                
                // 3. ヘッダ情報(VPS/SPS/PPS)を送信
                if let vps = self.vpsData {
                    self.sessionManager.sendVPS(vps)
                    print("[CaptureViewModel] VPS送信: \(vps.count)bytes")
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                
                if let sps = self.spsData {
                    self.sessionManager.sendSPS(sps)
                    print("[CaptureViewModel] SPS送信: \(sps.count)bytes")
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                
                if let pps = self.ppsData {
                    self.sessionManager.sendPPS(pps)
                    print("[CaptureViewModel] PPS送信: \(pps.count)bytes")
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                
                // 4. キーフレーム強制
                print("[CaptureViewModel] キーフレーム強制リクエスト")
                self.encoder.forceKeyFrame()
            }
        }
        
        sessionManager.onClientDisconnected = { [weak self] key in
            guard let self = self else { return }
            Logger.pipeline("★ クライアント切断: \(key), 残接続数: \(self.sessionManager.connectedClients), 再構成中: \(self.isReconfiguringEncoder)", sampling: .always)
            print("[CaptureViewModel] クライアント切断: \(key)")
            
            guard self.sessionManager.connectedClients == 0 else { return }
            
            // ★ エンコーダ再構成中は即座にstopCaptureしない（完了を待つ）
            if self.isReconfiguringEncoder {
                Logger.pipeline("⚠️ 再構成中のため切断処理を遅延 (最大2秒待機)", sampling: .always)
                Task { @MainActor in
                    // 最大2秒待機して再チェック
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if self.sessionManager.connectedClients == 0 {
                        Logger.pipeline("★ 遅延後確認: クライアント0 -> stopCapture実行", sampling: .always)
                        if self.isCapturing {
                            await self.stopCapture()
                        }
                        self.isNetworkMode = false
                    } else {
                        Logger.pipeline("★ 遅延後確認: クライアント再接続済み -> stopCapture中止", sampling: .always)
                    }
                }
                return
            }
            
            // 通常切断処理
            if self.isCapturing {
                Logger.pipeline("★ 全クライアント切断 -> stopCapture実行", sampling: .always)
                Task { await self.stopCapture() }
            }
            self.isNetworkMode = false
            print("[CaptureViewModel] 全クライアント切断 -> キャプチャ停止 & ネットワークモード解除")
        }
    }
    
    private func setupDelegates() {
        captureManager.delegate = self
        encoder.delegate = self
        decoder.delegate = self
        
        // InputReceiverDelegate: ズームリクエスト等をここ(CaptureViewModel)で処理
        sessionManager.inputReceiver.delegate = self
        
        // NetworkQualityMonitorDelegate: 同じくここ(CaptureViewModel)で処理
        // sessionManager.qualityMonitorは公開されている前提
        sessionManager.qualityMonitor.delegate = self
        
        // ★ Phase 1: DeviceSensorDelegate
        deviceSensor.delegate = self
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
        
        // ★ debounce: 連続呼び出し抑制（ログも最終値のみ出力）
        // ★ 最適化 2-B: debounce 200ms → 100ms（適応速度改善）
        settingsDebounceTask?.cancel()
        settingsDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms（旧200ms）
            guard !Task.isCancelled else { return }
            
            let codecName = (codecIndex == 0) ? "H.264" : "HEVC"
            print("[CaptureViewModel] 設定更新: \(Int(bitRateMbps))Mbps, \(Int(targetFPS))fps, KF=\(Int(keyFrameInterval)), \(codecName), Quality=\(String(format: "%.2f", quality))")
            
            // キャプチャ中ならエンコーダーを再構成
            if isCapturing {
                encodedFrameCount = 0
                isEncoderReady = false
                adaptiveQualityEngine.encoderLoad.pauseTracking()  // ★ 再構成中のFrameDrop誤検知防止
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
        
        // ★ 最適化 2-B: debounce 200ms → 100ms（適応速度改善）
        resolutionDebounceTask?.cancel()
        resolutionDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms（旧200ms）
            guard !Task.isCancelled else { return }
            
            do {
                try await captureManager.updateResolutionScale(resolutionScale, fps: Int(targetFPS))
                // 解像度変更時もエンコーダー再構成
                encodedFrameCount = 0
                isEncoderReady = false
                adaptiveQualityEngine.encoderLoad.pauseTracking()  // ★ 再構成中のFrameDrop誤検知防止
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
    
    // MARK: - Authentication Methods (Delegated)
    
    /// 接続リクエストを処理（AuthenticationManagerへ委譲）
    func handleAuthRequest(host: String, port: UInt16, userRecordID: String?) {
        authManager.handleAuthRequest(host: host, port: port, userRecordID: userRecordID)
    }
    
    /// 接続を許可（AuthenticationManagerへ委譲）
    func approveWithSystemAuth() {
        authManager.approveWithSystemAuth()
    }
    
    /// 接続を拒否（AuthenticationManagerへ委譲）
    func denyConnection() {
        authManager.denyConnection()
    }
    
    // MARK: - Phase 4: Verification / Testing
    
    /// ネットワーク状態をシミュレーション（テスト用）
    func simulateNetworkCondition(_ condition: String) {
        let debugCondition: NetworkQualityMonitor.DebugNetworkCondition
        switch condition.lowercased() {
        case "poor": debugCondition = .highLatency
        case "loss": debugCondition = .packetLoss
        case "excellent": debugCondition = .excellent
        default: debugCondition = .normal
        }
        
        // sessionManager経由でqualityMonitorにアクセスできると仮定、
        // または直接プロパティとして持っていればそれを使う。
        // ここでは sessionManager.qualityMonitor が公開されている前提。
        sessionManager.qualityMonitor.debugSimulation = debugCondition
        print("[CaptureViewModel] 🧪 Test Simulation: \(condition)")
    }
}

// MARK: - ScreenCaptureDelegate

extension CaptureViewModel: ScreenCaptureDelegate {
    /// ★ 最適化 1-B: dirtyRects無し版も高速パスで処理（MainActorバイパス）
    nonisolated func screenCapture(_ manager: ScreenCaptureManager, didCaptureFrame sampleBuffer: CMSampleBuffer) {
        // dirtyRects版と同じ高速パスを使用（static frameとして扱う）
        let captureTime = CFAbsoluteTimeGetCurrent()
        processFrameAsHEVCFast(sampleBuffer, captureTime: captureTime)
        
        // Static frame通知（MainActor非同期、クリティカルパス外）
        Task { @MainActor [weak self] in
            self?.lastCaptureTimestamp = captureTime
            self?.adaptiveQualityEngine.screenActivity.recordStaticFrame()
            self?.adaptiveQualityEngine.encoderLoad.recordEncodeCall()
        }
    }
    
    nonisolated func screenCapture(_ manager: ScreenCaptureManager, didFailWithError error: Error) {
        Task { @MainActor in
            captureError = "キャプチャエラー: \(error.localizedDescription)"
            isCapturing = false
        }
    }
    
    /// ★ Dirty Rects付きフレームをキャプチャ（動画一本化: 全フレームを動画エンコード）
    /// ★ Phase 2: MainActor排除 — キャプチャキュー上で直接実行
    nonisolated func screenCapture(_ manager: ScreenCaptureManager, didCaptureFrame sampleBuffer: CMSampleBuffer, dirtyRects: [CGRect]) {
        // ★ Phase 1: キャプチャ時刻記録（nonisolated安全: CFAbsoluteTimeGetCurrent はスレッドセーフ）
        let captureTime = CFAbsoluteTimeGetCurrent()
        
        // ★ Phase 2: エンコード処理を直接キャプチャキュー上で実行（MainActor不要）
        processFrameAsHEVCFast(sampleBuffer, captureTime: captureTime)
        
        // MainActor依存の処理は非同期で（クリティカルパス外）
        Task { @MainActor in
            // Phase 1: キャプチャ時刻を保存（計測用）
            self.lastCaptureTimestamp = captureTime
            
            // AdaptiveQualityEngine更新（MainActorプロパティ）
            if dirtyRects.isEmpty {
                self.adaptiveQualityEngine.screenActivity.recordStaticFrame()
            } else {
                self.adaptiveQualityEngine.screenActivity.recordDirtyRects(dirtyRects)
            }
            self.adaptiveQualityEngine.encoderLoad.recordEncodeCall()
            
            // ★ 最適化 2-A: 品質評価頻度を向上（10→5フレーム周期）
            if self.encodedFrameCount % 5 == 0 && self.adaptiveQualityMode {
                _ = self.adaptiveQualityEngine.evaluate()
            }
        }
    }
    
    /// ★ Phase 2: nonisolatedエンコード処理 — キャプチャキュー上で直接実行
    nonisolated private func processFrameAsHEVCFast(_ sampleBuffer: CMSampleBuffer, captureTime: CFAbsoluteTime) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        // エンコーダセットアップ（初回のみ）— MainActorが必要なのでMainActorで実行
        if !encoder.isReady {
            Task { @MainActor in
                if !self.isEncoderReady {
                    let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
                    let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
                    do {
                        try self.encoder.setup(width: width, height: height)
                        self.isEncoderReady = true
                        self.adaptiveQualityEngine.encoderLoad.resumeTracking()  // ★ 再構成完了
                    } catch {
                        print("[CaptureViewModel] エンコーダーセットアップエラー: \(error)")
                    }
                }
            }
            return // セットアップ中のフレームはスキップ（次フレームで対応）
        }
        
        // ★ Phase 1: エンコード開始時刻記録
        let encodeStart = CFAbsoluteTimeGetCurrent()
        let captureToEncodeMs = (encodeStart - captureTime) * 1000.0
        
        // エンコード実行（VideoEncoder.encode()はスレッドセーフ）
        encoder.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime, duration: duration)
        
        // EMA計算をMainActorに非同期で投げる（計測変数はMainActor上）
        Task { @MainActor in
            self.lastEncodeStartTimestamp = encodeStart
            self.emaCaptureToEncodeMs = self.emaCaptureToEncodeMs == 0 ? captureToEncodeMs
                : self.emaCaptureToEncodeMs * (1.0 - self.emaAlpha) + captureToEncodeMs * self.emaAlpha
        }
    }
    
    /// 旧バージョン（後方互換用）
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
                adaptiveQualityEngine.encoderLoad.resumeTracking()  // ★ 再構成完了
            } catch {
                print("[CaptureViewModel] エンコーダーセットアップエラー: \(error)")
                return
            }
        }
        
        lastEncodeStartTimestamp = CFAbsoluteTimeGetCurrent()
        if lastCaptureTimestamp > 0 {
            let captureToEncodeMs = (lastEncodeStartTimestamp - lastCaptureTimestamp) * 1000.0
            emaCaptureToEncodeMs = emaCaptureToEncodeMs == 0 ? captureToEncodeMs
                : emaCaptureToEncodeMs * (1.0 - emaAlpha) + captureToEncodeMs * emaAlpha
        }
        
        encoder.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime, duration: duration)
    }
    
    // ★ 動画一本化: sendHighResPNG / sendAsJPEG / createJPEGPacket は廃止
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
        // ★ 最適化 1-A: エンコード完了時刻記録（nonisolated安全）
        let encodeEndTime = CFAbsoluteTimeGetCurrent()
        
        // ★ 最適化 1-A: ネットワーク送信はMainActorを経由せず直接実行
        // _networkSenderRefはnonisolated(unsafe)、sendVideoFrame()はsendQueue上で動作
        // → MainActorホップ(3-8ms)を完全除去
        let timestamp = UInt64(presentationTime.seconds * 1_000_000_000)
        _networkSenderRef.sendVideoFrame(data, isKeyFrame: isKeyFrame, timestamp: timestamp)
        
        // メトリクス・カウンタ更新は非クリティカルパス → MainActorへ非同期
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // エンコード出力追跡（フレームドロップ率計算用）
            self.adaptiveQualityEngine.encoderLoad.recordEncodeOutput()
            
            // エンコード所要時間計算
            if self.lastEncodeStartTimestamp > 0 {
                let encodeDurationMs = (encodeEndTime - self.lastEncodeStartTimestamp) * 1000.0
                self.emaEncodeDurationMs = self.emaEncodeDurationMs == 0 ? encodeDurationMs
                    : self.emaEncodeDurationMs * (1.0 - self.emaAlpha) + encodeDurationMs * self.emaAlpha
            }
            
            self.encodedFrameCount += 1
            
            // ローカルループバック（テスト用）
            if self.isLoopbackMode {
                self.decoder.decode(annexBData: data, presentationTime: presentationTime)
            }
            
            // パイプラインメトリクス更新
            if self.isNetworkMode {
                self.adaptiveQualityEngine.updatePipelineMetrics(
                    captureToEncodeMs: self.emaCaptureToEncodeMs,
                    encodeDurationMs: self.emaEncodeDurationMs,
                    packetizeMs: self.emaPacketizeMs
                )
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



// MARK: - NetworkQualityMonitorDelegate (Phase 1: 適応型品質制御)

extension CaptureViewModel: NetworkQualityMonitorDelegate {
    
    nonisolated func networkQualityMonitor(_ monitor: NetworkQualityMonitor, didChangeQuality quality: NetworkQualityLevel) {
        Task { @MainActor in
            networkQualityDisplay = quality.rawValue
            
            // ★ Phase 3: AdaptiveQualityEngineにネットワーク品質を通知
            adaptiveQualityEngine.updateNetworkQuality(quality, metrics: monitor.currentMetrics)
            
            // 適応型品質制御が有効な場合、即座に再評価
            guard adaptiveQualityMode else { return }
            _ = adaptiveQualityEngine.evaluate()
        }
    }
    
    nonisolated func networkQualityMonitor(_ monitor: NetworkQualityMonitor, didUpdateMetrics metrics: NetworkQualityMetrics) {
        // ★ Phase 3: メトリクス更新もエンジンに通知（metrics.qualityLevelはSendable安全）
        Task { @MainActor in
            adaptiveQualityEngine.updateNetworkQuality(metrics.qualityLevel, metrics: metrics)
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
    
    // ★ Phase 1: Client Telemetry
    nonisolated func inputReceiver(_ receiver: InputReceiver, didReceiveTelemetry metrics: ClientDeviceMetrics) {
        Task { @MainActor in
            adaptiveQualityEngine.updateClientMetrics(metrics)
        }
    }
    
    // ★ Phase 1: Input Physics
    nonisolated func inputReceiver(_ receiver: InputReceiver, didUpdateScrollMetrics velocity: CGPoint, isScrolling: Bool) {
        let state = ScrollPhysicsState(
            velocityX: Double(velocity.x),
            velocityY: Double(velocity.y),
            isScrolling: isScrolling,
            lastUpdateTime: Date()
        )
        Task { @MainActor in
            adaptiveQualityEngine.updateInputPhysics(state)
        }
    }
    
    nonisolated func inputReceiver(_ receiver: InputReceiver, didReceiveZoomRequest isZooming: Bool, rect: CGRect, scale: CGFloat) {
        
        Task { @MainActor in
            // ★ Phase 3: ズーム状態をAdaptiveQualityEngineに通知
            adaptiveQualityEngine.updateZoomState(scale: isZooming ? scale : 1.0)
            
            // 状態変化時のみログ出力
            if isZooming != lastZoomState {
                if isZooming {
                    print("[CaptureViewModel] 🔍 ズーム開始: \(String(format: "%.1f", scale))x rect=(\(String(format: "%.2f", rect.origin.x)), \(String(format: "%.2f", rect.origin.y)), \(String(format: "%.2f", rect.width)), \(String(format: "%.2f", rect.height)))")
                } else {
                    print("[CaptureViewModel] 🔍 ズーム解除 → 全画面復帰")
                }
                lastZoomState = isZooming
            }
            
            // ★ ズーム連動キャプチャ: Mac側のキャプチャ領域をiPhoneのvisibleRectに追従
            do {
                if isZooming {
                    // ズーム中: iPhoneが見ている領域だけをキャプチャ
                    try await captureManager.updateCaptureRegion(rect)
                    
                    // ★ エンコーダーをリセットして新しい領域に対応
                    isEncoderReady = false
                    
                    // ★ Phase 3: ズーム時に即座に品質再評価
                    if adaptiveQualityMode {
                        _ = adaptiveQualityEngine.evaluate()
                    }
                } else {
                    // ズーム解除: 全画面キャプチャに戻す
                    try await captureManager.updateCaptureRegion(nil)
                    isEncoderReady = false
                    
                    // ★ Phase 3: ズーム解除時に品質再評価
                    if adaptiveQualityMode {
                        _ = adaptiveQualityEngine.evaluate()
                    }
                }
            } catch {
                print("[CaptureViewModel] ⚠️ キャプチャ領域変更失敗: \(error)")
            }
        }
    }
    
    /// ★ InputReceiver経由で登録を受信
    nonisolated func inputReceiver(_ receiver: InputReceiver, didReceiveRegistration listenPort: UInt16, userRecordID: String?, clientHost: String) {
        Task { @MainActor in
            print("[CaptureViewModel] 🔔 クライアント登録: \(clientHost):\(listenPort)")
            
            networkSender.registerClientFromInput(host: clientHost, port: listenPort, userRecordID: userRecordID)
        }
    }
}

// MARK: - DeviceSensorDelegate
extension CaptureViewModel: DeviceSensorDelegate {
    nonisolated func deviceSensor(_ sensor: DeviceSensor, didUpdateMetrics metrics: DeviceMetrics) {
        Task { @MainActor in
            // エンジンに通知
            adaptiveQualityEngine.updateHostMetrics(metrics)
        }
    }
}
