//
//  AdaptiveQualityEngine.swift
//  MyRemoteHost
//
//  Omniscient Auto-Pilot: MECE設計に基づく全指標自動制御エンジン
//  5レベルカスケード（Emergency/Network/Device/Content/Mode）を統合的に評価し、
//  全キャプチャ・エンコード・トランスポートパラメータを自動決定する
//

import Foundation
import CoreGraphics
import VideoToolbox

// MARK: - Quality Decision Output

/// 品質エンジンの出力パラメータ（全10パラメータ）
struct QualityDecision: Equatable {
    // === Encoding Parameters ===
    /// ビットレート (Mbps)
    var bitRateMbps: Double = 15
    /// フレームレート
    var targetFPS: Double = 60
    /// キーフレーム間隔
    var keyFrameInterval: Int = 60
    /// エンコーダ品質値 (0.5-1.0)
    var qualityValue: Float = 0.80
    /// コーデック (0=H.264, 1=HEVC)
    var codecIndex: Int = 1
    /// プロファイル (0=Baseline, 1=Main, 2=High)
    var profileIndex: Int = 2
    
    // === Capture Parameters ===
    /// キャプチャスケール: 1.0 = 論理解像度, 2.0 = Retina物理解像度
    var captureScale: CGFloat = 1.0
    /// 解像度スケール (0.25-1.0)
    var resolutionScale: Double = 1.0
    
    // === Transport Parameters ===
    /// 低遅延モード
    var lowLatencyMode: Bool = true
    /// ピークビットレート倍率 (1.0-3.0)
    var peakMultiplier: Double = 2.0
    
    /// 決定理由（デバッグ用）
    var reason: String = ""
    
    /// Retina有効かどうか
    var isRetina: Bool { captureScale >= 2.0 }
}

// MARK: - Screen Activity Tracker

/// 画面の動き状態を追跡するトラッカー
class ScreenActivityTracker: @unchecked Sendable {
    
    private let lock = NSLock()
    
    /// 動き量（0.0〜1.0）
    private(set) var motionRatio: Double = 0.0
    
    /// Dirty Rects数
    private(set) var dirtyRectCount: Int = 0
    
    /// 静止持続時間（秒）
    private(set) var staticDuration: TimeInterval = 0.0
    
    /// 動き量の移動平均
    private var motionHistory: [Double] = []
    private let historySize = 30
    
    /// 静止判定のしきい値
    private let staticThreshold: Double = 0.05
    
    /// 静止開始時刻
    private var staticStartTime: Date?
    
    /// 画面サイズ
    private var screenWidth: CGFloat = 1710
    private var screenHeight: CGFloat = 1108
    
    // MARK: - Activity Level
    
    enum ActivityLevel: String {
        case staticScreen = "Static"
        case lightMotion = "Light"
        case heavyMotion = "Heavy"
    }
    
    var activityLevel: ActivityLevel {
        lock.withLock {
            let avg = _averageMotionRatio
            if avg < 0.05 { return .staticScreen }
            else if avg < 0.30 { return .lightMotion }
            else { return .heavyMotion }
        }
    }
    
    var averageMotionRatio: Double {
        lock.withLock { _averageMotionRatio }
    }
    
    private var _averageMotionRatio: Double {
        guard !motionHistory.isEmpty else { return 0.0 }
        return motionHistory.reduce(0, +) / Double(motionHistory.count)
    }
    
    // MARK: - Public Methods
    
    func updateScreenSize(width: CGFloat, height: CGFloat) {
        lock.withLock {
            screenWidth = width
            screenHeight = height
        }
    }
    
    func recordDirtyRects(_ rects: [CGRect]) {
        lock.withLock {
            dirtyRectCount = rects.count
            let screenArea = Double(screenWidth * screenHeight)
            guard screenArea > 0 else { return }
            
            let dirtyArea = rects.reduce(0.0) { sum, rect in
                sum + Double(rect.width * rect.height)
            }
            
            motionRatio = min(dirtyArea / screenArea, 1.0)
            
            motionHistory.append(motionRatio)
            if motionHistory.count > historySize {
                motionHistory.removeFirst()
            }
            
            updateStaticDuration()
        }
    }
    
    func recordStaticFrame() {
        lock.withLock {
            motionRatio = 0.0
            dirtyRectCount = 0
            
            motionHistory.append(0.0)
            if motionHistory.count > historySize {
                motionHistory.removeFirst()
            }
            
            updateStaticDuration()
        }
    }
    
    func reset() {
        lock.withLock {
            motionHistory.removeAll()
            motionRatio = 0.0
            dirtyRectCount = 0
            staticDuration = 0.0
            staticStartTime = nil
        }
    }
    
    // MARK: - Private
    
    private func updateStaticDuration() {
        if _averageMotionRatio < staticThreshold {
            if staticStartTime == nil {
                staticStartTime = Date()
            }
            staticDuration = Date().timeIntervalSince(staticStartTime!)
        } else {
            staticStartTime = nil
            staticDuration = 0.0
        }
    }
}

// MARK: - Encoder Load Tracker

/// エンコーダ負荷を追跡
class EncoderLoadTracker: @unchecked Sendable {
    
    private let lock = NSLock()
    
    /// フレームドロップ率（0.0〜1.0）
    private(set) var frameDropRate: Double = 0.0
    
    private var encodeCallCount: Int = 0
    private var encodeOutputCount: Int = 0
    
    private let windowDuration: TimeInterval = 2.0
    private var windowStartTime: Date = Date()
    
    /// ★ エンコーダ再構成中はトラッキング一時停止
    private var isPaused: Bool = false
    
    /// ★ 最小サンプル数（これ未満ではDrop率を0とみなす → 起動時の誤検知防止）
    private let minimumSampleCount: Int = 10
    
    /// ★ 起動猶予期間（この期間中はDrop率を常に0とみなす）
    private var trackerStartTime: Date = Date()
    
    /// エンコーダ再構成開始時に呼ぶ（FrameDrop誤検知防止）
    func pauseTracking() {
        lock.withLock {
            isPaused = true
            // ウィンドウをリセットして過去のDrop率をクリア
            encodeCallCount = 0
            encodeOutputCount = 0
            frameDropRate = 0.0
            windowStartTime = Date()
        }
    }
    
    /// エンコーダ再構成完了時に呼ぶ
    func resumeTracking() {
        lock.withLock {
            isPaused = false
            // クリーンな状態からカウント再開
            encodeCallCount = 0
            encodeOutputCount = 0
            frameDropRate = 0.0
            windowStartTime = Date()
            // ★ 猶予期間もリセット（再構成直後のDrop誤検知を防止）
            trackerStartTime = Date()
        }
    }
    
    func recordEncodeCall() {
        lock.withLock {
            guard !isPaused else { return }  // ★ 再構成中はカウントしない
            resetWindowIfNeeded()
            encodeCallCount += 1
            updateDropRate()
        }
    }
    
    func recordEncodeOutput() {
        lock.withLock {
            guard !isPaused else { return }  // ★ 再構成中はカウントしない
            resetWindowIfNeeded()
            encodeOutputCount += 1
            updateDropRate()
        }
    }
    
    var isOverloaded: Bool {
        lock.withLock {
            guard encodeCallCount >= minimumSampleCount else { return false }
            guard Date().timeIntervalSince(trackerStartTime) > 5.0 else { return false }
            return frameDropRate > 0.10
        }
    }
    var isCritical: Bool {
        lock.withLock {
            guard encodeCallCount >= minimumSampleCount else { return false }
            guard Date().timeIntervalSince(trackerStartTime) > 5.0 else { return false }
            return frameDropRate > 0.20
        }
    }
    
    private func resetWindowIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(windowStartTime) > windowDuration {
            encodeCallCount = 0
            encodeOutputCount = 0
            windowStartTime = now
        }
    }
    
    private func updateDropRate() {
        guard encodeCallCount > 0 else {
            frameDropRate = 0.0
            return
        }
        frameDropRate = max(0.0, 1.0 - Double(encodeOutputCount) / Double(encodeCallCount))
    }
}

// MARK: - Adaptive Quality Engine (Omniscient Auto-Pilot)

/// MECE 5レベルカスケード全指標自動制御エンジン
class AdaptiveQualityEngine: @unchecked Sendable {
    
    private let lock = NSLock()
    
    // MARK: - Input Trackers
    
    let screenActivity = ScreenActivityTracker()
    let encoderLoad = EncoderLoadTracker()
    
    // MARK: - Current Sensor State
    
    private(set) var currentZoomScale: CGFloat = 1.0
    private(set) var currentNetworkQuality: NetworkQualityLevel = .good
    private(set) var currentMetrics: NetworkQualityMetrics = NetworkQualityMetrics()
    private(set) var hostDeviceMetrics: DeviceMetrics = DeviceMetrics()
    private(set) var clientDeviceMetrics: ClientDeviceMetrics = ClientDeviceMetrics()
    private(set) var inputPhysics: ScrollPhysicsState = ScrollPhysicsState()
    
    // MARK: - Engine State
    
    /// 現在のエンジンモード（自動選択）
    private(set) var currentMode: EngineMode = .balanced
    
    /// 最後の品質決定
    private(set) var lastDecision: QualityDecision = QualityDecision()
    
    /// 品質変更コールバック
    var onQualityChanged: ((QualityDecision) -> Void)?
    
    // MARK: - Engine Mode
    
    public enum EngineMode: String, Sendable {
        case balanced = "Balanced"
        case performance = "Performance"
        case quality = "Quality"
        case eco = "Eco"
        case networkLimited = "Limited"
    }
    
    // MARK: - Hysteresis & Cooldown
    
    /// Retina切替しきい値
    private let retinaStaticDuration: TimeInterval = 10.0  // ★ 2s→10s: 振動防止
    private let retinaMotionThreshold: Double = 0.08
    private let zoomRetinaThreshold: CGFloat = 1.5
    
    /// ★ Retina切替クールダウン（振動防止）
    private var lastRetinaSwitchTime: Date = Date.distantPast
    private let retinaSwitchCooldown: TimeInterval = 30.0
    
    /// 品質変更のクールダウン
    private var lastQualityChangeTime: Date = Date.distantPast
    private let qualityChangeCooldown: TimeInterval = 1.5
    
    /// 負荷ペナルティ（振動防止）
    private var loadPenaltyEndTime: Date = Date.distantPast
    private let loadPenaltyDuration: TimeInterval = 10.0
    
    /// コーデック切替クールダウン（エンコーダ再構成が重いため）
    private var lastCodecChangeTime: Date = Date.distantPast
    private let codecChangeCooldown: TimeInterval = 15.0
    
    /// モード切替クールダウン
    private var lastModeChangeTime: Date = Date.distantPast
    private let modeChangeCooldown: TimeInterval = 5.0
    
    /// BWE (Bandwidth Estimation)
    private var estimatedBandwidth: Double = 50.0
    
    // MARK: - Public Update Methods
    
    func updateZoomState(scale: CGFloat) {
        lock.withLock { currentZoomScale = scale }
    }
    
    func updateNetworkQuality(_ quality: NetworkQualityLevel, metrics: NetworkQualityMetrics) {
        lock.withLock {
            currentNetworkQuality = quality
            currentMetrics = metrics
            if metrics.bandwidth > 0 {
                estimatedBandwidth = metrics.bandwidth
            }
        }
    }
    
    func updateHostMetrics(_ metrics: DeviceMetrics) {
        lock.withLock { hostDeviceMetrics = metrics }
    }
    
    func updateClientMetrics(_ metrics: ClientDeviceMetrics) {
        lock.withLock { clientDeviceMetrics = metrics }
    }
    
    func updateInputPhysics(_ physics: ScrollPhysicsState) {
        lock.withLock { inputPhysics = physics }
    }
    
    // MARK: - Pipeline Latency Metrics (Phase 1)
    
    /// パイプライン遅延計測値（CaptureViewModelから更新される）
    private var pipelineCaptureToEncodeMs: Double = 0
    private var pipelineEncodeDurationMs: Double = 0
    private var pipelinePacketizeMs: Double = 0
    
    /// パイプライン遅延メトリクスを更新
    func updatePipelineMetrics(captureToEncodeMs: Double, encodeDurationMs: Double, packetizeMs: Double) {
        lock.withLock {
            pipelineCaptureToEncodeMs = captureToEncodeMs
            pipelineEncodeDurationMs = encodeDurationMs
            pipelinePacketizeMs = packetizeMs
        }
    }
    
    // MARK: - OmniscientState生成
    
    var currentOmniscientState: OmniscientState {
        lock.withLock {
            var state = OmniscientState()
            
            // Host Metrics
            state.hostCPU = Float(hostDeviceMetrics.cpuUsage)
            state.hostMemory = Float(hostDeviceMetrics.memoryUsage)
            state.hostThermalState = Int(hostDeviceMetrics.thermalState)
            state.hostBattery = 1.0
            state.isHostCharging = true
            
            // Network Metrics
            state.rtt = currentMetrics.rtt
            state.packetLoss = currentMetrics.packetLossRate
            state.bandwidthMbps = currentMetrics.bandwidth
            state.networkQuality = currentNetworkQuality.rawValue
            
            // Input/Content
            state.scrollVelocity = sqrt(pow(inputPhysics.velocityX, 2) + pow(inputPhysics.velocityY, 2))
            state.isScrolling = inputPhysics.isScrolling
            state.contentMotionRatio = screenActivity.averageMotionRatio
            state.isContentStatic = screenActivity.staticDuration > 0
            
            // Client Metrics
            state.clientThermalState = clientDeviceMetrics.thermalState
            state.clientBattery = clientDeviceMetrics.batteryLevel
            state.clientFPS = Double(clientDeviceMetrics.currentFPS)
            
            // Decision (全パラメータ)
            state.targetBitrateMbps = lastDecision.bitRateMbps
            state.targetFPS = lastDecision.targetFPS
            state.captureScale = Double(lastDecision.captureScale)
            state.encoderQuality = lastDecision.qualityValue
            state.keyFrameInterval = lastDecision.keyFrameInterval
            state.codecName = lastDecision.codecIndex == 0 ? "H.264" : "HEVC"
            state.profileName = ["Baseline", "Main", "High"][min(lastDecision.profileIndex, 2)]
            state.resolutionScale = lastDecision.resolutionScale
            state.lowLatencyMode = lastDecision.lowLatencyMode
            state.peakMultiplier = lastDecision.peakMultiplier
            state.decisionReason = lastDecision.reason
            
            // Engine Mode
            state.engineMode = currentMode.rawValue
            
            // Pipeline Latency Metrics (Phase 1)
            state.captureToEncodeMs = pipelineCaptureToEncodeMs
            state.encodeDurationMs = pipelineEncodeDurationMs
            state.packetizeMs = pipelinePacketizeMs
            state.hostWallClockMs = CFAbsoluteTimeGetCurrent() * 1000.0
            
            return state
        }
    }
    
    // MARK: - Core Evaluate — 5レベルカスケード
    
    func evaluate() -> QualityDecision {
        lock.withLock {
            var decision = QualityDecision()
            var reasons: [String] = []
            
            // ═══════════════════════════════════════
            // Step 0: 自動モード選択
            // ═══════════════════════════════════════
            let autoMode = determineMode()
            if autoMode != currentMode {
                let now = Date()
                if now.timeIntervalSince(lastModeChangeTime) >= modeChangeCooldown {
                    currentMode = autoMode
                    lastModeChangeTime = now
                    print("[AutoPilot] 🔄 モード切替: \(autoMode.rawValue)")
                }
            }
            
            // ═══════════════════════════════════════
            // Level 0: Emergency（最優先）
            // ═══════════════════════════════════════
            
            if encoderLoad.isCritical {
                decision = emergencyDecision(reason: "FrameDrop>\(Int(encoderLoad.frameDropRate * 100))%")
                loadPenaltyEndTime = Date().addingTimeInterval(loadPenaltyDuration)
                applyIfChanged(decision)
                return decision
            }
            
            if clientDeviceMetrics.thermalState >= 3 {
                decision = emergencyDecision(reason: "ClientThermal=Critical")
                applyIfChanged(decision)
                return decision
            }
            
            if currentMetrics.packetLossRate > 0.10 {
                decision = emergencyDecision(reason: "Loss>\(Int(currentMetrics.packetLossRate * 100))%")
                applyIfChanged(decision)
                return decision
            }
            
            // ═══════════════════════════════════════
            // Level 1: Network Gate（帯域制約）
            // ═══════════════════════════════════════
            
            let bw = estimatedBandwidth > 0 ? estimatedBandwidth : 50.0
            
            let networkBitrateCeiling: Double
            let networkFPSCeiling: Double
            let canRetina: Bool
            
            switch currentNetworkQuality {
            case .excellent:
                networkBitrateCeiling = min(bw * 0.9, 100)
                networkFPSCeiling = 120
                canRetina = true
            case .good:
                networkBitrateCeiling = min(bw * 0.8, 60)
                networkFPSCeiling = 60
                canRetina = true
            case .moderate:
                networkBitrateCeiling = min(bw * 0.7, 25)
                networkFPSCeiling = 30
                canRetina = false
            case .poor:
                networkBitrateCeiling = min(bw * 0.5, 15)
                networkFPSCeiling = 30
                canRetina = false
            }
            
            // パケットロスが高め → キーフレーム間隔短縮
            if currentMetrics.packetLossRate > 0.03 {
                decision.keyFrameInterval = 15
                reasons.append("Loss→KF=15")
            }
            
            reasons.append("Net:\(currentNetworkQuality.rawValue)")
            
            // ═══════════════════════════════════════
            // Level 2: Device Gate（ハードウェア制約）
            // ═══════════════════════════════════════
            
            var deviceFPSCap: Double = 120
            var deviceResCap: Double = 1.0
            
            // Host CPU高負荷
            if hostDeviceMetrics.cpuUsage > 0.80 {
                deviceFPSCap = min(deviceFPSCap, 30)
                deviceResCap = min(deviceResCap, 0.75)
                reasons.append("HostCPU>\(Int(hostDeviceMetrics.cpuUsage * 100))%")
            } else if hostDeviceMetrics.cpuUsage > 0.60 {
                deviceFPSCap = min(deviceFPSCap, 60)
            }
            
            // Host Thermal
            if hostDeviceMetrics.thermalState >= 2 {
                deviceFPSCap = min(deviceFPSCap, 30)
                deviceResCap = min(deviceResCap, 0.5)
                reasons.append("HostThm=Serious")
            }
            
            // Client Battery低下
            if clientDeviceMetrics.batteryLevel < 0.15 && !clientDeviceMetrics.isCharging {
                deviceFPSCap = min(deviceFPSCap, 24)
                reasons.append("ClientBat<15%")
            }
            
            // Client Thermal
            if clientDeviceMetrics.thermalState >= 2 {
                deviceFPSCap = min(deviceFPSCap, 30)
                reasons.append("ClientThm=Serious")
            }
            
            // Encoder overloaded (非Critical)
            let inLoadPenalty = Date() < loadPenaltyEndTime
            if encoderLoad.isOverloaded || inLoadPenalty {
                deviceResCap = min(deviceResCap, 0.75)
                if inLoadPenalty { reasons.append("LoadPenalty") }
            }
            
            // ═══════════════════════════════════════
            // Level 3: Content Adaptation（コンテンツ適応）
            // ═══════════════════════════════════════
            
            let activity = screenActivity.activityLevel
            var contentBitrateAdjust: Double = 1.0
            var contentQualityTarget: Float = 0.80
            var contentFPSTarget: Double = 60
            var contentKFTarget: Int = 60
            
            switch activity {
            case .staticScreen:
                if screenActivity.staticDuration >= retinaStaticDuration {
                    contentQualityTarget = 0.95
                    contentBitrateAdjust = 0.5  // 静止時はビットレート節約可能
                    contentFPSTarget = 30       // 静止時はFPS下げてOK
                    contentKFTarget = 120       // 変化少ないためKF間隔長め
                    reasons.append("Static:\(String(format: "%.0f", screenActivity.staticDuration))s")
                } else {
                    contentFPSTarget = 60
                    reasons.append("Static(wait)")
                }
            case .lightMotion:
                contentQualityTarget = 0.80
                contentBitrateAdjust = 1.0
                contentFPSTarget = 60
                contentKFTarget = 60
                reasons.append("LightMotion")
            case .heavyMotion:
                contentQualityTarget = 0.70
                contentBitrateAdjust = 1.3  // 動き時はビットレート上げ
                contentFPSTarget = 60
                contentKFTarget = 30        // 動き時はKF短め
                reasons.append("HeavyMotion")
            }
            
            // ズーム→Retina
            var retinaFromContent = false
            if currentZoomScale >= zoomRetinaThreshold {
                retinaFromContent = true
                reasons.append("Zoom:\(String(format: "%.1f", currentZoomScale))x")
            } else if canRetina && !encoderLoad.isOverloaded && !inLoadPenalty {
                // ★ Retina切替クールダウンチェック
                let retinaCooldownOK = Date().timeIntervalSince(lastRetinaSwitchTime) >= retinaSwitchCooldown
                if activity == .staticScreen && screenActivity.staticDuration >= retinaStaticDuration && retinaCooldownOK {
                    retinaFromContent = true
                }
            }
            
            // ═══════════════════════════════════════
            // Level 4: Mode Policy（モード別微調整）
            // ═══════════════════════════════════════
            
            let modeProfile = getModeProfile(currentMode)
            reasons.append("Mode:\(currentMode.rawValue)")
            
            // === 最終パラメータ計算 ===
            
            // Bitrate: min(Network上限, Mode値 × コンテンツ係数)
            decision.bitRateMbps = min(networkBitrateCeiling, modeProfile.bitrate * contentBitrateAdjust)
            
            // FPS: min(Network上限, Device上限, Mode値, コンテンツ推奨)
            decision.targetFPS = min(networkFPSCeiling, deviceFPSCap, modeProfile.fps, contentFPSTarget)
            
            // Quality
            decision.qualityValue = max(modeProfile.quality, contentQualityTarget)
            
            // Keyframe: パケロス→短縮優先、それ以外はコンテンツ×モードの短い方
            if decision.keyFrameInterval == 60 { // Level 1でLoSSにより設定されていなければ
                decision.keyFrameInterval = min(contentKFTarget, modeProfile.keyframe)
            }
            
            // Codec: コーデック切替にはクールダウン適用
            let now = Date()
            let desiredCodec = modeProfile.codecIndex
            if desiredCodec != lastDecision.codecIndex {
                if now.timeIntervalSince(lastCodecChangeTime) >= codecChangeCooldown {
                    decision.codecIndex = desiredCodec
                    lastCodecChangeTime = now
                } else {
                    decision.codecIndex = lastDecision.codecIndex // 据え置き
                }
            } else {
                decision.codecIndex = desiredCodec
            }
            
            // Profile
            decision.profileIndex = modeProfile.profileIndex
            
            // Resolution Scale: min(Device上限, Mode値)
            decision.resolutionScale = min(deviceResCap, modeProfile.resolutionScale)
            
            // Capture Scale (Retina)
            decision.captureScale = (retinaFromContent && canRetina) ? 2.0 : 1.0
            
            // Low Latency
            decision.lowLatencyMode = modeProfile.lowLatency
            
            // Peak Multiplier
            decision.peakMultiplier = modeProfile.peakMultiplier
            
            // Reason
            decision.reason = reasons.joined(separator: " | ")
            
            applyIfChanged(decision)
            return decision
        }
    }
    
    // MARK: - 自動モード選択
    
    /// MECE条件チェーンで最適モードを自動選択
    private func determineMode() -> EngineMode {
        // 最優先: バッテリー危機 or 熱問題
        if (clientDeviceMetrics.batteryLevel < 0.20 && !clientDeviceMetrics.isCharging) ||
           hostDeviceMetrics.thermalState >= 2 || clientDeviceMetrics.thermalState >= 2 {
            return .eco
        }
        
        // ネットワーク制約
        if currentMetrics.packetLossRate > 0.05 || estimatedBandwidth < 5.0 ||
           currentNetworkQuality == .poor {
            return .networkLimited
        }
        
        // コンテンツ適応
        let activity = screenActivity.activityLevel
        
        if activity == .staticScreen && screenActivity.staticDuration > 3.0 &&
           (currentNetworkQuality == .excellent || currentNetworkQuality == .good) {
            return .quality
        }
        
        if activity == .heavyMotion &&
           (currentNetworkQuality == .excellent || currentNetworkQuality == .good) {
            return .performance
        }
        
        return .balanced
    }
    
    // MARK: - Mode Profiles
    
    private struct ModeProfile {
        let bitrate: Double
        let fps: Double
        let keyframe: Int
        let quality: Float
        let codecIndex: Int    // 0=H.264, 1=HEVC
        let profileIndex: Int  // 0=Baseline, 1=Main, 2=High
        let resolutionScale: Double
        let lowLatency: Bool
        let peakMultiplier: Double
    }
    
    private func getModeProfile(_ mode: EngineMode) -> ModeProfile {
        switch mode {
        case .balanced:
            return ModeProfile(
                bitrate: 50, fps: 60, keyframe: 60, quality: 0.80,
                codecIndex: 1, profileIndex: 2, resolutionScale: 1.0,
                lowLatency: true, peakMultiplier: 2.0
            )
        case .performance:
            return ModeProfile(
                bitrate: 40, fps: 60, keyframe: 30, quality: 0.70,
                codecIndex: 0, profileIndex: 1, resolutionScale: 0.75,
                lowLatency: true, peakMultiplier: 2.5
            )
        case .quality:
            return ModeProfile(
                bitrate: 80, fps: 30, keyframe: 120, quality: 0.95,
                codecIndex: 1, profileIndex: 2, resolutionScale: 1.0,
                lowLatency: false, peakMultiplier: 1.5
            )
        case .eco:
            return ModeProfile(
                bitrate: 10, fps: 24, keyframe: 60, quality: 0.60,
                codecIndex: 0, profileIndex: 0, resolutionScale: 0.5,
                lowLatency: false, peakMultiplier: 1.0
            )
        case .networkLimited:
            return ModeProfile(
                bitrate: 15, fps: 30, keyframe: 30, quality: 0.60,
                codecIndex: 0, profileIndex: 1, resolutionScale: 0.5,
                lowLatency: true, peakMultiplier: 1.0
            )
        }
    }
    
    // MARK: - Emergency Decision
    
    private func emergencyDecision(reason: String) -> QualityDecision {
        var d = QualityDecision()
        d.bitRateMbps = 5
        d.targetFPS = 15
        d.keyFrameInterval = 15
        d.qualityValue = 0.50
        // ★ コーデック切替禁止: Emergency時は現在のコーデックを維持
        // コーデック切替はエンコーダ再構成を伴い、さらに負荷が増大するため逆効果
        d.codecIndex = lastDecision.codecIndex
        d.profileIndex = lastDecision.profileIndex
        d.captureScale = 1.0
        d.resolutionScale = 0.5
        d.lowLatencyMode = true
        d.peakMultiplier = 1.0
        d.reason = "⚠️ Emergency: \(reason)"
        return d
    }
    
    // MARK: - Apply with Change Detection
    
    private func applyIfChanged(_ newDecision: QualityDecision) {
        let now = Date()
        guard now.timeIntervalSince(lastQualityChangeTime) >= qualityChangeCooldown else { return }
        
        // いずれかのパラメータが変わった場合のみ通知
        let changed =
            newDecision.captureScale != lastDecision.captureScale ||
            abs(newDecision.bitRateMbps - lastDecision.bitRateMbps) > 1.0 ||
            newDecision.targetFPS != lastDecision.targetFPS ||
            newDecision.keyFrameInterval != lastDecision.keyFrameInterval ||
            abs(newDecision.qualityValue - lastDecision.qualityValue) > 0.05 ||
            newDecision.codecIndex != lastDecision.codecIndex ||
            newDecision.profileIndex != lastDecision.profileIndex ||
            abs(newDecision.resolutionScale - lastDecision.resolutionScale) > 0.05 ||
            newDecision.lowLatencyMode != lastDecision.lowLatencyMode ||
            abs(newDecision.peakMultiplier - lastDecision.peakMultiplier) > 0.1
        
        guard changed else { return }
        
        // ★ Retina切替時刻を記録（振動防止クールダウン用）
        if newDecision.captureScale != lastDecision.captureScale {
            lastRetinaSwitchTime = now
        }
        
        lastDecision = newDecision
        lastQualityChangeTime = now
        
        let codec = newDecision.codecIndex == 0 ? "H.264" : "HEVC"
        let profile = ["BL", "Main", "High"][min(newDecision.profileIndex, 2)]
        print("[AutoPilot] 🎯 \(newDecision.reason) → BR:\(Int(newDecision.bitRateMbps))M FPS:\(Int(newDecision.targetFPS)) Q:\(String(format: "%.0f", newDecision.qualityValue * 100))% KF:\(newDecision.keyFrameInterval) \(codec)/\(profile) Res:\(String(format: "%.0f", newDecision.resolutionScale * 100))% LL:\(newDecision.lowLatencyMode ? "ON" : "OFF") Peak:\(String(format: "%.1f", newDecision.peakMultiplier))x")
        
        onQualityChanged?(newDecision)
    }
}
