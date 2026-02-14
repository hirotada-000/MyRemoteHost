//
//  VideoDecoder.swift
//  MyRemoteClient
//
//  H.264 / HEVC ハードウェアデコーダー（iOS版）
//  VideoToolbox の VTDecompressionSession を使用
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// デコードされたフレームを受け取るデリゲート
protocol VideoDecoderDelegate: AnyObject {
    /// デコードされたフレームを受信
    func videoDecoder(_ decoder: VideoDecoder, didOutputPixelBuffer pixelBuffer: CVPixelBuffer, presentationTime: CMTime)
    /// エラー発生
    func videoDecoder(_ decoder: VideoDecoder, didFailWithError error: Error)
}

/// H.264 / HEVC ハードウェアデコーダー
class VideoDecoder {
    
    // MARK: - Delegate
    
    weak var delegate: VideoDecoderDelegate?
    
    // MARK: - Private Properties
    
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    
    private var vpsData: Data?  // HEVC用
    private var spsData: Data?
    private var ppsData: Data?
    private var isSessionReady = false
    private var isHEVC = false  // HEVCモードフラグ
    
    /// ★ キーフレーム待機フラグ（Pフレームのみではデコード不可）
    private var waitingForKeyFrame = true
    
    /// Annex B スタートコード
    private let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    private let shortStartCode: [UInt8] = [0x00, 0x00, 0x01]
    
    // MARK: - ログ・カウンタ
    
    /// デコードエラーカウンター
    private var decodeErrorCount = 0
    
    /// キーフレーム待機中のPフレームスキップカウンタ
    private var decodeSkipCount = 0
    
    // MARK: - Public Methods
    
    /// VPS を設定（HEVCのみ）
    func setVPS(_ data: Data) {
        let newVPS = removeStartCode(from: data)
        guard !newVPS.isEmpty else { return }  // ★ 空データガード
        
        // ★ コーデック切替検出: VPS受信 = HEVCストリーム
        if !isHEVC {
            Logger.video("★★★ コーデック切替検出: H.264 → HEVC (VPS受信)", sampling: .always)
            // ★ switchCodecではパラメータをクリアしない（VPSはこの後設定するため）
            destroySession()
            isHEVC = true
            spsData = nil  // SPS/PPSは古いのでクリア
            ppsData = nil
            decodeErrorCount = 0
            decodeSkipCount = 0
        }
        
        // ★ パラメータが変更された場合はセッションを破棄して再作成
        if vpsData != nil && vpsData != newVPS {
            Logger.video("★ VPS変更検出 - セッション再作成", sampling: .always)
            destroySession()
        }
        
        vpsData = newVPS
        isHEVC = true  // VPSが送られてきたらHEVC
        Logger.video("HEVC VPS設定: \(newVPS.count)バイト", sampling: .oncePerSession)
        tryCreateSession()
    }
    
    /// SPS を設定
    func setSPS(_ data: Data) {
        let newSPS = removeStartCode(from: data)
        guard !newSPS.isEmpty else { return }  // ★ 空データガード
        
        // ★ NALヘッダーからコーデックを自動判定
        let detectedHEVC = detectCodecFromSPS(newSPS)
        if detectedHEVC != isHEVC {
            Logger.video("★★★ コーデック切替検出: \(isHEVC ? "HEVC" : "H.264") → \(detectedHEVC ? "HEVC" : "H.264") (SPS NAL解析)", sampling: .always)
            destroySession()
            isHEVC = detectedHEVC
            vpsData = nil  // 古いパラメータをクリア
            ppsData = nil
            decodeErrorCount = 0
            decodeSkipCount = 0
        }
        
        // ★ パラメータが変更された場合はセッションを破棄して再作成
        if spsData != nil && spsData != newSPS {
            Logger.video("★ SPS変更検出 - セッション再作成", sampling: .always)
            destroySession()
        }
        
        spsData = newSPS
        Logger.video("SPS設定: \(newSPS.count)バイト (コーデック: \(isHEVC ? "HEVC" : "H.264"))", sampling: .oncePerSession)
        tryCreateSession()
    }
    
    /// PPS を設定
    func setPPS(_ data: Data) {
        let newPPS = removeStartCode(from: data)
        guard !newPPS.isEmpty else { return }  // ★ 空データガード
        
        // ★ パラメータが変更された場合はセッションを破棄して再作成
        if ppsData != nil && ppsData != newPPS {
            Logger.video("★ PPS変更検出 - セッション再作成", sampling: .always)
            destroySession()
        }
        
        ppsData = newPPS
        Logger.video("PPS設定: \(newPPS.count)バイト", sampling: .oncePerSession)
        tryCreateSession()
    }
    
    /// Annex B 形式のデータをデコード
    func decode(annexBData: Data, presentationTime: CMTime) {
        guard isSessionReady, decompressionSession != nil else {
            Logger.video("⚠️ デコードスキップ: セッション未準備 (ready=\(isSessionReady), session=\(decompressionSession != nil), HEVC=\(isHEVC), VPS=\(vpsData?.count ?? 0), SPS=\(spsData?.count ?? 0), PPS=\(ppsData?.count ?? 0))", sampling: .throttle(3.0))
            return
        }
        
        let nalUnits = extractNALUnits(from: annexBData)
        
        for nalUnit in nalUnits {
            decodeNALUnit(nalUnit, presentationTime: presentationTime)
        }
    }
    
    /// デコーダーをクリーンアップ
    func teardown() {
        destroySession()
        vpsData = nil
        spsData = nil
        ppsData = nil
        isHEVC = false
    }
    
    /// ★ セッションのみ破棄（パラメータは保持）
    private func destroySession() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
            Logger.video("★ デコードセッション破棄", sampling: .always)
        }
        formatDescription = nil
        isSessionReady = false
        waitingForKeyFrame = true  // ★ セッション破棄時はキーフレーム待機に戻る
    }
    
    /// ★ コーデック切替時のフルリセット（Apple VideoToolbox公式ベストプラクティス）
    /// H.264↔HEVCの切替はセッション再作成が必須
    private func switchCodec(toHEVC: Bool) {
        Logger.video("★★★ コーデック切替実行: \(isHEVC ? "HEVC" : "H.264") → \(toHEVC ? "HEVC" : "H.264")", sampling: .always)
        destroySession()
        vpsData = nil
        spsData = nil
        ppsData = nil
        isHEVC = toHEVC
        decodeErrorCount = 0
        decodeSkipCount = 0
        Logger.video("★★★ コーデック切替完了: 新モード=\(toHEVC ? "HEVC" : "H.264") — パラメータセット待機中", sampling: .always)
    }
    
    /// ★ SPS NALヘッダーからコーデックを判定
    /// - H.264 SPS: NAL type = 7 (forbidden_bit=0, nal_ref_idc=3, nal_unit_type=7 → 0x67 or 0x27)
    /// - HEVC SPS: NAL type = 33 (forbidden_bit=0, nal_unit_type=33 → first byte: (33 << 1) = 0x42)
    private func detectCodecFromSPS(_ sps: Data) -> Bool {
        guard let firstByte = sps.first else { return isHEVC }
        
        // H.264 NAL header: 1 byte → nal_unit_type = firstByte & 0x1F
        let h264NalType = firstByte & 0x1F
        if h264NalType == 7 {
            // H.264 SPS確定
            return false
        }
        
        // HEVC NAL header: 2 bytes → nal_unit_type = (firstByte >> 1) & 0x3F
        let hevcNalType = (firstByte >> 1) & 0x3F
        if hevcNalType == 33 {
            // HEVC SPS確定
            return true
        }
        
        // 判定不能の場合は現在のモードを維持
        Logger.video("⚠️ SPS NALヘッダー判定不能: 0x\(String(format: "%02X", firstByte)) - 現在モード維持(\(isHEVC ? "HEVC" : "H.264"))", level: .warning, sampling: .always)
        return isHEVC
    }
    
    // MARK: - Private Methods
    
    private func tryCreateSession() {
        guard let sps = spsData, let pps = ppsData else { return }
        
        // HEVC の場合は VPS も必要
        if isHEVC && vpsData == nil {
            Logger.video("HEVC: VPS待機中...", sampling: .throttle(3.0))
            return
        }
        
        // ★ 既存セッションがある場合: 新しいフォーマットを受け入れられるかチェック
        if let existingSession = decompressionSession {
            // 新しいFormatDescriptionを作成して互換性を確認
            if let newFormat = createFormatDescription(sps: sps, pps: pps) {
                if VTDecompressionSessionCanAcceptFormatDescription(existingSession, formatDescription: newFormat) {
                    // 互換性あり: セッション再作成不要
                    formatDescription = newFormat
                    Logger.video("★ FormatDescription更新(セッション互換)", sampling: .always)
                    return
                } else {
                    // 非互換: セッション再作成が必要
                    Logger.video("★ FormatDescription非互換 → セッション再作成", sampling: .always)
                    destroySession()
                }
            }
        }
        
        guard decompressionSession == nil else { return }
        
        do {
            if isHEVC {
                Logger.video("★ HEVC デコードセッション作成開始 (VPS=\(vpsData!.count), SPS=\(sps.count), PPS=\(pps.count))", sampling: .always)
                try createHEVCDecompressionSession(vps: vpsData!, sps: sps, pps: pps)
            } else {
                Logger.video("★ H.264 デコードセッション作成開始 (SPS=\(sps.count), PPS=\(pps.count))", sampling: .always)
                try createH264DecompressionSession(sps: sps, pps: pps)
            }
            isSessionReady = true
            Logger.video("✅ デコードセッション作成成功 (\(isHEVC ? "HEVC" : "H.264"))", sampling: .always)
        } catch {
            Logger.video("❌ セッション作成失敗: \(error)", level: .error, sampling: .always)
            delegate?.videoDecoder(self, didFailWithError: error)
        }
    }
    
    /// ★ FormatDescriptionを作成（互換性チェック用）
    private func createFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        if isHEVC, let vps = vpsData {
            var description: CMFormatDescription?
            let status = vps.withUnsafeBytes { vpsBuffer -> OSStatus in
                sps.withUnsafeBytes { spsBuffer -> OSStatus in
                    pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                        guard let vpsBase = vpsBuffer.baseAddress,
                              let spsBase = spsBuffer.baseAddress,
                              let ppsBase = ppsBuffer.baseAddress else {
                            return kCMFormatDescriptionError_InvalidParameter
                        }
                        let pointers: [UnsafePointer<UInt8>] = [
                            vpsBase.assumingMemoryBound(to: UInt8.self),
                            spsBase.assumingMemoryBound(to: UInt8.self),
                            ppsBase.assumingMemoryBound(to: UInt8.self)
                        ]
                        let sizes: [Int] = [vps.count, sps.count, pps.count]
                        return pointers.withUnsafeBufferPointer { pBuf in
                            sizes.withUnsafeBufferPointer { sBuf in
                                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: 3,
                                    parameterSetPointers: pBuf.baseAddress!,
                                    parameterSetSizes: sBuf.baseAddress!,
                                    nalUnitHeaderLength: 4,
                                    extensions: nil,
                                    formatDescriptionOut: &description
                                )
                            }
                        }
                    }
                }
            }
            return status == noErr ? description : nil
        } else {
            var description: CMFormatDescription?
            let status = sps.withUnsafeBytes { spsBuffer -> OSStatus in
                pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                    guard let spsBase = spsBuffer.baseAddress,
                          let ppsBase = ppsBuffer.baseAddress else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }
                    let pointers: [UnsafePointer<UInt8>] = [
                        spsBase.assumingMemoryBound(to: UInt8.self),
                        ppsBase.assumingMemoryBound(to: UInt8.self)
                    ]
                    let sizes: [Int] = [sps.count, pps.count]
                    return pointers.withUnsafeBufferPointer { pBuf in
                        sizes.withUnsafeBufferPointer { sBuf in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: pBuf.baseAddress!,
                                parameterSetSizes: sBuf.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &description
                            )
                        }
                    }
                }
            }
            return status == noErr ? description : nil
        }
    }
    
    /// H.264 デコンプレッションセッション作成
    private func createH264DecompressionSession(sps: Data, pps: Data) throws {
        // print("[VideoDecoder] H.264 セッション作成中...")
        
        var description: CMFormatDescription?
        
        let status = sps.withUnsafeBytes { spsBuffer -> OSStatus in
            pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                guard let spsBaseAddress = spsBuffer.baseAddress,
                      let ppsBaseAddress = ppsBuffer.baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                
                let parameterSetPointers: [UnsafePointer<UInt8>] = [
                    spsBaseAddress.assumingMemoryBound(to: UInt8.self),
                    ppsBaseAddress.assumingMemoryBound(to: UInt8.self)
                ]
                let parameterSetSizes: [Int] = [sps.count, pps.count]
                
                return parameterSetPointers.withUnsafeBufferPointer { pointersBuffer in
                    parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersBuffer.baseAddress!,
                            parameterSetSizes: sizesBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        
        guard status == noErr, let formatDesc = description else {
            throw DecoderError.formatDescriptionCreationFailed(status)
        }
        
        try createDecompressionSessionCommon(formatDesc: formatDesc, codecName: "H.264")
    }
    
    /// HEVC デコンプレッションセッション作成
    private func createHEVCDecompressionSession(vps: Data, sps: Data, pps: Data) throws {
        // print("[VideoDecoder] HEVC セッション作成中...")
        
        var description: CMFormatDescription?
        
        let status = vps.withUnsafeBytes { vpsBuffer -> OSStatus in
            sps.withUnsafeBytes { spsBuffer -> OSStatus in
                pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                    guard let vpsBaseAddress = vpsBuffer.baseAddress,
                          let spsBaseAddress = spsBuffer.baseAddress,
                          let ppsBaseAddress = ppsBuffer.baseAddress else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }
                    
                    let parameterSetPointers: [UnsafePointer<UInt8>] = [
                        vpsBaseAddress.assumingMemoryBound(to: UInt8.self),
                        spsBaseAddress.assumingMemoryBound(to: UInt8.self),
                        ppsBaseAddress.assumingMemoryBound(to: UInt8.self)
                    ]
                    let parameterSetSizes: [Int] = [vps.count, sps.count, pps.count]
                    
                    return parameterSetPointers.withUnsafeBufferPointer { pointersBuffer in
                        parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pointersBuffer.baseAddress!,
                                parameterSetSizes: sizesBuffer.baseAddress!,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &description
                            )
                        }
                    }
                }
            }
        }
        
        guard status == noErr, let formatDesc = description else {
            throw DecoderError.formatDescriptionCreationFailed(status)
        }
        
        try createDecompressionSessionCommon(formatDesc: formatDesc, codecName: "HEVC")
    }
    
    /// 共通のデコンプレッションセッション作成
    private func createDecompressionSessionCommon(formatDesc: CMFormatDescription, codecName: String) throws {
        formatDescription = formatDesc
        
        // iOS用出力設定 (Metal Direct Rendering用にNV12を指定)
        let destinationPixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
                guard let refCon = decompressionOutputRefCon else { return }
                let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
                decoder.handleDecodedFrame(status: status, imageBuffer: imageBuffer, presentationTime: presentationTimeStamp)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationPixelBufferAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        
        guard createStatus == noErr, let decompSession = session else {
            throw DecoderError.sessionCreationFailed(createStatus)
        }
        
        decompressionSession = decompSession
        
        // ★ 最適化 3-B: RealTimeモード有効化
        // VideoToolboxにリアルタイムストリーミング用途を通知 → 内部スケジューリング最適化
        VTSessionSetProperty(decompSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
        Logger.video("✅ デコードセッション作成成功 (\(codecName)) \(dimensions.width)x\(dimensions.height) [RealTime=ON]", sampling: .always)
    }
    
    private func removeStartCode(from data: Data) -> Data {
        if data.starts(with: startCode) {
            return data.dropFirst(4)
        } else if data.starts(with: shortStartCode) {
            return data.dropFirst(3)
        }
        return data
    }
    
    private func extractNALUnits(from annexBData: Data) -> [Data] {
        var nalUnits: [Data] = []
        var offset = 0
        let bytes = [UInt8](annexBData)
        
        while offset < bytes.count {
            var startCodeLength = 0
            
            if offset + 4 <= bytes.count &&
               bytes[offset] == 0x00 && bytes[offset + 1] == 0x00 &&
               bytes[offset + 2] == 0x00 && bytes[offset + 3] == 0x01 {
                startCodeLength = 4
            } else if offset + 3 <= bytes.count &&
                      bytes[offset] == 0x00 && bytes[offset + 1] == 0x00 && bytes[offset + 2] == 0x01 {
                startCodeLength = 3
            }
            
            if startCodeLength > 0 {
                offset += startCodeLength
                
                var endOffset = offset
                while endOffset < bytes.count {
                    if endOffset + 4 <= bytes.count &&
                       bytes[endOffset] == 0x00 && bytes[endOffset + 1] == 0x00 &&
                       bytes[endOffset + 2] == 0x00 && bytes[endOffset + 3] == 0x01 {
                        break
                    } else if endOffset + 3 <= bytes.count &&
                              bytes[endOffset] == 0x00 && bytes[endOffset + 1] == 0x00 && bytes[endOffset + 2] == 0x01 {
                        break
                    }
                    endOffset += 1
                }
                
                if endOffset > offset {
                    let nalData = Data(bytes[offset..<endOffset])
                    nalUnits.append(nalData)
                }
                
                offset = endOffset
            } else {
                offset += 1
            }
        }
        
        return nalUnits
    }
    
    private func decodeNALUnit(_ nalUnit: Data, presentationTime: CMTime) {
        guard let session = decompressionSession, let formatDesc = formatDescription else { return }
        
        guard let firstByte = nalUnit.first else { return }
        
        // ═══════════════════════════════════════════
        // NAL タイプ判定（H.264 と HEVC で異なる）
        // ═══════════════════════════════════════════
        var isKeyFrame = false
        
        if isHEVC {
            // HEVC: NAL タイプは (firstByte >> 1) & 0x3F
            let nalType = (firstByte >> 1) & 0x3F
            
            // VPS=32, SPS=33, PPS=34 はスキップ
            if nalType == 32 || nalType == 33 || nalType == 34 {
                return
            }
            
            // ★ キーフレーム検出 (IDR = 19, 20, CRA = 21)
            if nalType == 19 || nalType == 20 || nalType == 21 {
                isKeyFrame = true
                if waitingForKeyFrame {
                    waitingForKeyFrame = false
                    Logger.video("★ HEVC キーフレーム受信 (NAL=\(nalType)) - デコード開始", sampling: .always)
                }
            }
        } else {
            // H.264: NAL タイプは firstByte & 0x1F
            let nalType = firstByte & 0x1F
            
            // 7 = SPS, 8 = PPS はスキップ
            if nalType == 7 || nalType == 8 {
                return
            }
            
            // ★ キーフレーム検出 (IDR = 5)
            if nalType == 5 {
                isKeyFrame = true
                if waitingForKeyFrame {
                    waitingForKeyFrame = false
                    Logger.video("★ H.264 キーフレーム受信 (NAL=5) - デコード開始", sampling: .always)
                }
            }
        }
        
        // ★ キーフレーム待機中は P フレームをスキップ
        if waitingForKeyFrame && !isKeyFrame {
            decodeSkipCount += 1
            if decodeSkipCount == 1 || decodeSkipCount % 100 == 0 {
                let nalType = isHEVC ? Int((firstByte >> 1) & 0x3F) : Int(firstByte & 0x1F)
                Logger.video("⏳ キーフレーム待機中 - Pフレームスキップ (NAL=\(nalType), skip#\(decodeSkipCount))", sampling: .throttle(3.0))
            }
            return
        }
        
        var avccData = Data()
        var length = UInt32(nalUnit.count).bigEndian
        avccData.append(Data(bytes: &length, count: 4))
        avccData.append(nalUnit)
        
        var blockBuffer: CMBlockBuffer?
        
        let _ = avccData.withUnsafeBytes { (bufferPointer: UnsafeRawBufferPointer) -> OSStatus in
            guard let baseAddress = bufferPointer.baseAddress else { return kCMBlockBufferNoErr }
            
            let status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            
            if status == noErr, let buffer = blockBuffer {
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: buffer,
                    offsetIntoDestination: 0,
                    dataLength: avccData.count
                )
            }
            
            return status
        }
        
        guard let buffer = blockBuffer else { return }
        
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccData.count
        
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleStatus == noErr, let sample = sampleBuffer else { return }
        
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        
        if decodeStatus != noErr {
            decodeErrorCount += 1
            Logger.video("❌ デコードエラー: \(decodeStatus) (累計\(decodeErrorCount)回, HEVC=\(isHEVC))", level: .error, sampling: .throttle(3.0))
        }
    }
    
    /// デコード成功カウンタ
    private var decodedFrameCount: Int = 0
    
    private func handleDecodedFrame(status: OSStatus, imageBuffer: CVImageBuffer?, presentationTime: CMTime) {
        guard status == noErr else {
            if status != -12909 {
                Logger.video("❌ デコードコールバックエラー: \(status)", level: .error, sampling: .throttle(3.0))
            }
            return
        }
        
        guard let pixelBuffer = imageBuffer else { return }
        
        decodedFrameCount += 1
        if decodedFrameCount == 1 {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            Logger.video("✅ 初回デコード成功! \(w)x\(h) (\(isHEVC ? "HEVC" : "H.264"))", sampling: .always)
        }
        
        delegate?.videoDecoder(self, didOutputPixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }
}

// MARK: - Errors

enum DecoderError: LocalizedError {
    case formatDescriptionCreationFailed(OSStatus)
    case sessionCreationFailed(OSStatus)
    case decodingFailed(OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .formatDescriptionCreationFailed(let status):
            return "フォーマット記述作成失敗: \(status)"
        case .sessionCreationFailed(let status):
            return "デコードセッション作成失敗: \(status)"
        case .decodingFailed(let status):
            return "デコード失敗: \(status)"
        }
    }
}
