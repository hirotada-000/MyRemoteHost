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
    
    // MARK: - ログ頻度制御
    
    /// パラメータセットログ済みフラグ
    private var hasLoggedParameterSets = false
    
    /// デコードエラーカウンター
    private var decodeErrorCount = 0
    
    /// 最後のデコードエラーログ時刻
    private var lastDecodeErrorLogTime: Date?
    
    // MARK: - Public Methods
    
    /// VPS を設定（HEVCのみ）
    func setVPS(_ data: Data) {
        let newVPS = removeStartCode(from: data)
        
        // ★ パラメータが変更された場合はセッションを破棄して再作成
        if vpsData != nil && vpsData != newVPS {
            // print("[VideoDecoder] ★ VPS変更検出 - セッション再作成")
            destroySession()
        }
        
        vpsData = newVPS
        isHEVC = true  // VPSが送られてきたらHEVC
        if !hasLoggedParameterSets {
            // print("[VideoDecoder] HEVC VPS設定: \(vpsData?.count ?? 0)バイト")
        }
        tryCreateSession()
    }
    
    /// SPS を設定
    func setSPS(_ data: Data) {
        let newSPS = removeStartCode(from: data)
        
        // ★ パラメータが変更された場合はセッションを破棄して再作成
        if spsData != nil && spsData != newSPS {
            // print("[VideoDecoder] ★ SPS変更検出 - セッション再作成")
            destroySession()
        }
        
        spsData = newSPS
        if !hasLoggedParameterSets {
            // print("[VideoDecoder] SPS設定: \(spsData?.count ?? 0)バイト")
        }
        tryCreateSession()
    }
    
    /// PPS を設定
    func setPPS(_ data: Data) {
        let newPPS = removeStartCode(from: data)
        
        // ★ パラメータが変更された場合はセッションを破棄して再作成
        if ppsData != nil && ppsData != newPPS {
            // print("[VideoDecoder] ★ PPS変更検出 - セッション再作成")
            destroySession()
        }
        
        ppsData = newPPS
        if !hasLoggedParameterSets {
            // print("[VideoDecoder] PPS設定: \(ppsData?.count ?? 0)バイト")
            hasLoggedParameterSets = true
        }
        tryCreateSession()
    }
    
    /// Annex B 形式のデータをデコード
    func decode(annexBData: Data, presentationTime: CMTime) {
        guard isSessionReady, decompressionSession != nil else {
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
            // print("[VideoDecoder] セッション破棄")
        }
        formatDescription = nil
        isSessionReady = false
        waitingForKeyFrame = true  // ★ セッション破棄時はキーフレーム待機に戻る
    }
    
    // MARK: - Private Methods
    
    private func tryCreateSession() {
        guard let sps = spsData, let pps = ppsData else { return }
        guard decompressionSession == nil else { return }
        
        // HEVC の場合は VPS も必要
        if isHEVC && vpsData == nil {
            // print("[VideoDecoder] HEVC: VPS待機中...")
            return
        }
        
        do {
            if isHEVC {
                try createHEVCDecompressionSession(vps: vpsData!, sps: sps, pps: pps)
            } else {
                try createH264DecompressionSession(sps: sps, pps: pps)
            }
            isSessionReady = true
        } catch {
            // print("[VideoDecoder] セッション作成失敗: \(error)")
            delegate?.videoDecoder(self, didFailWithError: error)
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
        
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
        // print("[VideoDecoder] \(codecName) セッション作成完了: \(dimensions.width)x\(dimensions.height)")
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
                    // print("[VideoDecoder] ★ HEVC キーフレーム受信 - デコード開始")
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
                    // print("[VideoDecoder] ★ H.264 キーフレーム受信 - デコード開始")
                }
            }
        }
        
        // ★ キーフレーム待機中は P フレームをスキップ
        if waitingForKeyFrame && !isKeyFrame {
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
            let now = Date()
            if lastDecodeErrorLogTime == nil || now.timeIntervalSince(lastDecodeErrorLogTime!) > 5.0 {
                // print("[VideoDecoder] デコードエラー: \(decodeStatus) (累計\(decodeErrorCount)回)")
                lastDecodeErrorLogTime = now
            }
        }
    }
    
    private func handleDecodedFrame(status: OSStatus, imageBuffer: CVImageBuffer?, presentationTime: CMTime) {
        guard status == noErr else {
            if status != -12909 {
                // print("[VideoDecoder] デコードコールバックエラー: \(status)")
            }
            return
        }
        
        guard let pixelBuffer = imageBuffer else { return }
        
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
