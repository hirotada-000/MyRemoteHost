//
//  VideoEncoder.swift
//  MyRemoteHost
//
//  H.264 ハードウェアエンコーダー
//  VideoToolbox の VTCompressionSession を使用して超低遅延エンコードを実現
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// エンコードされたデータを受け取るデリゲート
protocol VideoEncoderDelegate: AnyObject {
    /// VPSデータを受信（HEVCのみ、ストリーム開始時に1回）
    func videoEncoder(_ encoder: VideoEncoder, didOutputVPS vps: Data)
    /// SPSデータを受信（ストリーム開始時に1回）
    func videoEncoder(_ encoder: VideoEncoder, didOutputSPS sps: Data)
    /// PPSデータを受信（ストリーム開始時に1回）
    func videoEncoder(_ encoder: VideoEncoder, didOutputPPS pps: Data)
    /// エンコードされたNALユニットを受信（Annex B形式）
    func videoEncoder(_ encoder: VideoEncoder, didOutputEncodedData data: Data, isKeyFrame: Bool, presentationTime: CMTime)
    /// エラー発生
    func videoEncoder(_ encoder: VideoEncoder, didFailWithError error: Error)
}

/// コーデック選択
enum VideoCodec: String, CaseIterable {
    case h264 = "H.264"
    case hevc = "HEVC"
}

/// H.264 / HEVC ハードウェアエンコーダー
class VideoEncoder {
    
    // MARK: - Configuration
    
    /// ビットレート（bps） - ★ 画質改善: 15Mbps
    /// テキストの鮮明さを優先し、Retinaクラスの画質を実現
    var bitRate: Int = 15_000_000 
    
    /// キーフレーム間隔（フレーム数）- 60 = 1秒に1回 (データ圧縮優先)
    var maxKeyFrameInterval: Int = 60
    
    /// H.264 プロファイル - Baseline = 最も低負荷
    var profile: CFString = kVTProfileLevel_H264_Baseline_AutoLevel
    
    /// HEVC プロファイル - Main = 標準 (10-bit無効)
    var hevcProfile: CFString = kVTProfileLevel_HEVC_Main_AutoLevel
    
    /// 目標フレームレート
    var targetFrameRate: Int = 60
    
    /// 超低遅延モード有効化
    var ultraLowLatencyMode: Bool = true
    
    /// 品質優先モード - 動画は品質を少し下げる
    var qualityMode: Bool = true
    
    /// ピークビットレート倍率 - バーストを抑える
    var peakBitRateMultiplier: Double = 1.2
    
    /// コーデック選択（HEVC = 高画質、H.264 = 互換性）
    var codec: VideoCodec = .hevc {
        didSet {
            if oldValue != codec {
                Logger.pipeline("★ エンコーダ コーデック変更: \(oldValue.rawValue) → \(codec.rawValue)", sampling: .always)
            }
        }
    }
    
    // ★ 新規: 高画質テキストモード
    /// テキスト高画質モード（4:4:4 相当の高品質設定）
    var textQualityMode: Bool = true
    
    /// Quality 値 - 静止時画質はMAX
    var qualityValue: Float = 0.95
    
    // MARK: - Delegate
    
    weak var delegate: VideoEncoderDelegate?
    
    // MARK: - Private Properties
    
    private var compressionSession: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var hasOutputParameterSets = false
    
    /// ★ Phase 2: セッション準備状態（nonisolatedから安全にアクセス可能）
    var isReady: Bool { compressionSession != nil }
    
    /// ★ Phase 2: プリウォーム済みセッション（裏で準備、アトミック切替）
    private var pendingSession: VTCompressionSession?
    private var pendingWidth: Int32 = 0
    private var pendingHeight: Int32 = 0
    
    /// パラメータセットログ済みフラグ（初回のみログ）
    private var hasLoggedParameterSets = false
    
    /// Annex B スタートコード
    private let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    
    // MARK: - Public Methods
    
    /// エンコーダーを初期化
    func setup(width: Int32, height: Int32) throws {
        self.width = width
        self.height = height
        
        Logger.pipeline("★ エンコーダ セットアップ開始: \(width)x\(height) \(codec.rawValue)", sampling: .always)
        
        // 既存のセッションを破棄
        teardown()
        
        // 低遅延エンコーダー仕様（WWDC 2021推奨）
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        
        // コーデック選択
        let codecType: CMVideoCodecType = (codec == .hevc) 
            ? kCMVideoCodecType_HEVC 
            : kCMVideoCodecType_H264
        
        // print("[VideoEncoder] コーデック: \(codec.rawValue)")
        
        // セッション作成（コールバックはnil、後で非同期処理を使用）
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &compressionSession
        )
        
        guard status == noErr, let session = compressionSession else {
            throw EncoderError.sessionCreationFailed(status)
        }
        
        // プロパティ設定
        try configureSession(session)
        
        // セッション準備
        VTCompressionSessionPrepareToEncodeFrames(session)
        
        hasOutputParameterSets = false
        Logger.pipeline("✅ エンコーダ セットアップ完了: \(width)x\(height) \(codec.rawValue)", sampling: .always)
    }
    
    /// フレームをエンコード
    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, duration: CMTime) {
        guard let session = compressionSession else {
            Logger.pipeline("⚠️ エンコード失敗: セッション未初期化", level: .warning, sampling: .throttle(3.0))
            return
        }
        
        // フレームプロパティ（キーフレーム強制が必要な場合は設定）
        var frameProperties: CFDictionary? = nil
        if forceNextKeyFrame {
            // print("[VideoEncoder] 強制キーフレームを適用")
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceNextKeyFrame = false
        }
        
        // 非同期エンコード（コールバックの代わりにEncodeFrameWithOutputHandlerを使用）
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, infoFlags, sampleBuffer in
            self?.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
        }
        
        if status != noErr {
            Logger.pipeline("❌ エンコードエラー: status=\(status)", level: .error, sampling: .throttle(3.0))
        }
    }
    
    /// 次のフレームでキーフレームを強制するフラグ
    private var forceNextKeyFrame = false
    
    /// 強制キーフレームをリクエスト
    func forceKeyFrame() {
        forceNextKeyFrame = true
        Logger.pipeline("★ キーフレーム強制リクエスト", sampling: .always)
    }
    
    /// エンコーダーをクリーンアップ
    func teardown() {
        Logger.pipeline("★ エンコーダ teardown開始 (session=\(compressionSession != nil), pending=\(pendingSession != nil))", sampling: .always)
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        // プリウォームセッションも破棄
        if let pending = pendingSession {
            VTCompressionSessionInvalidate(pending)
            pendingSession = nil
        }
        Logger.pipeline("★ エンコーダ teardown完了", sampling: .always)
    }
    
    // MARK: - ★ Phase 2: プリウォーム（エンコーダ再構成のフリーズ解消）
    
    /// 新しいセッションを裏で準備（コーデック/解像度変更時に事前呼び出し）
    func prewarmSession(width: Int32, height: Int32) {
        // 同じ解像度ならスキップ
        guard width != self.width || height != self.height else { return }
        
        let codecType: CMVideoCodecType = (codec == .hevc)
            ? kCMVideoCodecType_HEVC
            : kCMVideoCodecType_H264
        
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        
        guard status == noErr, let session = newSession else {
            Logger.pipeline("⚠️ プリウォーム失敗: \(status)", level: .warning, sampling: .always)
            return
        }
        
        do {
            try configureSession(session)
            VTCompressionSessionPrepareToEncodeFrames(session)
            
            // 古いプリウォームを破棄
            if let old = pendingSession {
                VTCompressionSessionInvalidate(old)
            }
            pendingSession = session
            pendingWidth = width
            pendingHeight = height
            Logger.pipeline("★ プリウォーム完了: \(width)x\(height)", sampling: .always)
        } catch {
            VTCompressionSessionInvalidate(session)
            Logger.pipeline("⚠️ プリウォーム設定失敗: \(error)", level: .warning, sampling: .always)
        }
    }
    
    /// プリウォーム済みセッションにアトミック切替（フレームドロップなし）
    func swapToPrewarmedSession() -> Bool {
        guard let newSession = pendingSession else { return false }
        
        // 旧セッションを破棄
        if let oldSession = compressionSession {
            VTCompressionSessionCompleteFrames(oldSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(oldSession)
        }
        
        // アトミック切替
        compressionSession = newSession
        width = pendingWidth
        height = pendingHeight
        pendingSession = nil
        hasOutputParameterSets = false
        
        Logger.pipeline("★ セッション切替完了: \(width)x\(height)", sampling: .always)
        return true
    }
    
    // MARK: - ★ 最適化 4-A: セッション再作成なしのパラメータ即時更新
    
    /// セッション再作成なしでパラメータを即時更新（ビットレート/品質/FPS/KF間隔のみ）
    /// 解像度・コーデック変更時はsetup()またはprewarmSession()を使用
    func updateRuntimeParameters(bitRate newBitRate: Int? = nil,
                                  quality newQuality: Float? = nil,
                                  fps newFPS: Int? = nil,
                                  keyFrameInterval newKFInterval: Int? = nil) {
        guard let session = compressionSession else { return }
        
        if let br = newBitRate, br != bitRate {
            bitRate = br
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: br as CFNumber)
            let peak = Int(Double(br) * peakBitRateMultiplier)
            let limits = [peak, 1] as CFArray
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        }
        
        if let q = newQuality, q != qualityValue {
            qualityValue = q
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: q as CFNumber)
        }
        
        if let f = newFPS, f != targetFrameRate {
            targetFrameRate = f
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: f as CFNumber)
        }
        
        if let kf = newKFInterval, kf != maxKeyFrameInterval {
            maxKeyFrameInterval = kf
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: kf as CFNumber)
        }
    }
    
    // MARK: - Private Methods
    
    private func configureSession(_ session: VTCompressionSession) throws {
        var status: OSStatus
        
        // ═══════════════════════════════════════════
        // 【必須】リアルタイムモード
        // ═══════════════════════════════════════════
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        guard status == noErr else { throw EncoderError.propertySetFailed("RealTime", status) }
        
        // ═══════════════════════════════════════════
        // 【超重要】低遅延レート制御 — macOS 12.3+ / iOS 15.4+
        // ═══════════════════════════════════════════
        if ultraLowLatencyMode {
            // EnableLowLatencyRateControl は macOS 12.3+ のみ
            // シンボルが見つからない場合は直接文字列で指定
            let enableLowLatencyKey = "EnableLowLatencyRateControl" as CFString
            status = VTSessionSetProperty(session,
                key: enableLowLatencyKey,
                value: kCFBooleanTrue)
            if status == noErr {
                // print("[VideoEncoder] ★ 低遅延レート制御: 有効")
            } else {
                // print("[VideoEncoder] 低遅延レート制御: 非サポート (status: \(status))")
            }
        }
        
        // ═══════════════════════════════════════════
        // プロファイル設定 - コーデックに応じて選択
        // ═══════════════════════════════════════════
        let activeProfile: CFString = (codec == .hevc) ? hevcProfile : profile
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: activeProfile)
        guard status == noErr else { throw EncoderError.propertySetFailed("ProfileLevel", status) }
        // print("[VideoEncoder] ★ プロファイル: \(activeProfile)")
        
        // ═══════════════════════════════════════════
        // ビットレート（平均）
        // ═══════════════════════════════════════════
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        guard status == noErr else { throw EncoderError.propertySetFailed("AverageBitRate", status) }
        
        // ═══════════════════════════════════════════
        // 【Phase 1】ピークビットレート制限（バースト許容）
        // ═══════════════════════════════════════════
        let peakBitRate = Int(Double(bitRate) * peakBitRateMultiplier)
        let dataRateLimits = [peakBitRate, 1] as CFArray
        status = VTSessionSetProperty(session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits)
        if status == noErr {
            // print("[VideoEncoder] ★ ピークビットレート: \(peakBitRate/1_000_000)Mbps")
        }
        
        // ═══════════════════════════════════════════
        // 【根本的画質最適化】Constant Quality モード
        // qualityValue で動的に品質設定
        // ═══════════════════════════════════════════
        if qualityMode {
            // ★ qualityValue を使用 (UI から調整可能)
            status = VTSessionSetProperty(session,
                key: kVTCompressionPropertyKey_Quality,
                value: qualityValue as CFNumber)  // 0.0-1.0、高いほど高品質
            if status == noErr {
                // print("[VideoEncoder] ★ 品質モード: Quality=\(String(format: "%.2f", qualityValue))")
            }
        }
        
        // ═══════════════════════════════════════════
        // 【核心】キーフレーム間隔
        // ═══════════════════════════════════════════
        status = VTSessionSetProperty(session, 
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval, 
            value: maxKeyFrameInterval as CFNumber)
        guard status == noErr else { throw EncoderError.propertySetFailed("MaxKeyFrameInterval", status) }
        
        // ═══════════════════════════════════════════
        // 【核心】Bフレーム完全排除 = フレーム並べ替え禁止
        // ═══════════════════════════════════════════
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        guard status == noErr else { throw EncoderError.propertySetFailed("AllowFrameReordering", status) }
        
        // ═══════════════════════════════════════════
        // 【Overkill】最大フレームデルタ = 即座に出力
        // ═══════════════════════════════════════════
        status = VTSessionSetProperty(session,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: 0 as CFNumber)  // ★ バッファリングなし
        if status == noErr {
            // print("[VideoEncoder] ★ MaxFrameDelayCount: 0 (バッファリングなし)")
        }
        
        // ═══════════════════════════════════════════
        // 期待フレームレート（レート制御のヒント）
        // ═══════════════════════════════════════════
        status = VTSessionSetProperty(session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: targetFrameRate as CFNumber)
        if status == noErr {
            // print("[VideoEncoder] ★ ExpectedFrameRate: \(targetFrameRate)fps")
        }
        
        // ═══════════════════════════════════════════
        // エントロピーエンコーディング - High プロファイルは CABAC 対応
        // ═══════════════════════════════════════════
        let isHighProfile = CFEqual(profile, kVTProfileLevel_H264_High_AutoLevel)
        if isHighProfile {
            // High プロファイルでは CABAC が自動的に使用される
            // print("[VideoEncoder] ★ High プロファイル: CABAC エントロピー符号化有効")
        }
        
        // print("[VideoEncoder] ★ 超高画質設定完了: \(bitRate/1_000_000)Mbps, I-Frame間隔: \(maxKeyFrameInterval)フレーム, 品質モード: \(qualityMode)")
    }
    
    private func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr else {
            // print("[VideoEncoder] エンコードコールバックエラー: \(status)")
            delegate?.videoEncoder(self, didFailWithError: EncoderError.encodingFailed(status))
            return
        }
        
        guard let sampleBuffer = sampleBuffer else { return }
        
        // SPS/PPS を最初に一度だけ出力
        if !hasOutputParameterSets {
            extractAndOutputParameterSets(from: sampleBuffer)
            hasOutputParameterSets = true
        }
        
        // NALユニットを抽出してAnnex B形式に変換
        extractNALUnits(from: sampleBuffer)
    }
    
    private func extractAndOutputParameterSets(from sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        
        if codec == .hevc {
            extractHEVCParameterSets(from: formatDescription)
        } else {
            extractH264ParameterSets(from: formatDescription)
        }
    }
    
    /// H.264 パラメータセット抽出 (SPS/PPS)
    private func extractH264ParameterSets(from formatDescription: CMFormatDescription) {
        // SPS
        var spsSize: Int = 0
        var spsCount: Int = 0
        var spsPointer: UnsafePointer<UInt8>?
        
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )
        
        if status == noErr, let sps = spsPointer {
            var spsData = Data(startCode)
            spsData.append(sps, count: spsSize)
            delegate?.videoEncoder(self, didOutputSPS: spsData)
            if !hasLoggedParameterSets {
                // print("[VideoEncoder] H.264 SPS出力: \(spsSize)バイト")
            }
        }
        
        // PPS
        var ppsSize: Int = 0
        var ppsPointer: UnsafePointer<UInt8>?
        
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        
        if status == noErr, let pps = ppsPointer {
            var ppsData = Data(startCode)
            ppsData.append(pps, count: ppsSize)
            delegate?.videoEncoder(self, didOutputPPS: ppsData)
            if !hasLoggedParameterSets {
                // print("[VideoEncoder] H.264 PPS出力: \(ppsSize)バイト")
                hasLoggedParameterSets = true
            }
        }
    }
    
    /// HEVC パラメータセット抽出 (VPS/SPS/PPS)
    private func extractHEVCParameterSets(from formatDescription: CMFormatDescription) {
        // VPS (HEVCのみ)
        var vpsSize: Int = 0
        var vpsPointer: UnsafePointer<UInt8>?
        
        var status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &vpsPointer,
            parameterSetSizeOut: &vpsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        
        if status == noErr, let vps = vpsPointer {
            var vpsData = Data(startCode)
            vpsData.append(vps, count: vpsSize)
            delegate?.videoEncoder(self, didOutputVPS: vpsData)
            if !hasLoggedParameterSets {
                // print("[VideoEncoder] HEVC VPS出力: \(vpsSize)バイト")
            }
        }
        
        // SPS
        var spsSize: Int = 0
        var spsPointer: UnsafePointer<UInt8>?
        
        status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        
        if status == noErr, let sps = spsPointer {
            var spsData = Data(startCode)
            spsData.append(sps, count: spsSize)
            delegate?.videoEncoder(self, didOutputSPS: spsData)
            if !hasLoggedParameterSets {
                // print("[VideoEncoder] HEVC SPS出力: \(spsSize)バイト")
            }
        }
        
        // PPS
        var ppsSize: Int = 0
        var ppsPointer: UnsafePointer<UInt8>?
        
        status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 2,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        
        if status == noErr, let pps = ppsPointer {
            var ppsData = Data(startCode)
            ppsData.append(pps, count: ppsSize)
            delegate?.videoEncoder(self, didOutputPPS: ppsData)
            if !hasLoggedParameterSets {
                // print("[VideoEncoder] HEVC PPS出力: \(ppsSize)バイト")
                hasLoggedParameterSets = true
            }
        }
    }
    
    private func extractNALUnits(from sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // キーフレーム判定
        // Apple VideoToolbox: kCMSampleAttachmentKey_NotSync
        //   - 存在しない or false → 同期フレーム（キーフレーム）
        //   - true → 非同期フレーム（P-frame）
        var isKeyFrame = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let attachment = attachments.first {
            // ★ 修正: NotSync が nil（存在しない）= キーフレーム → デフォルト false
            let notSync = attachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isKeyFrame = !notSync
        }
        
        // データ取得
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == noErr, let pointer = dataPointer else { return }
        
        // AVCC形式からAnnex B形式へ変換
        var annexBData = Data()
        var offset = 0
        
        while offset < length - 4 {
            // 4バイトの長さプレフィックスを読む（ビッグエンディアン）
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            
            offset += 4
            
            guard offset + Int(nalLength) <= length else { break }
            
            // スタートコードを追加
            annexBData.append(contentsOf: startCode)
            
            // NALユニットデータを追加
            annexBData.append(Data(bytes: pointer.advanced(by: offset), count: Int(nalLength)))
            
            offset += Int(nalLength)
        }
        
        if !annexBData.isEmpty {
            delegate?.videoEncoder(self, didOutputEncodedData: annexBData, isKeyFrame: isKeyFrame, presentationTime: presentationTime)
        }
    }
}

// MARK: - Errors

enum EncoderError: LocalizedError {
    case sessionCreationFailed(OSStatus)
    case propertySetFailed(String, OSStatus)
    case encodingFailed(OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "エンコードセッション作成失敗: \(status)"
        case .propertySetFailed(let property, let status):
            return "プロパティ設定失敗 (\(property)): \(status)"
        case .encodingFailed(let status):
            return "エンコード失敗: \(status)"
        }
    }
}
