//
//  ScreenCaptureManager.swift
//  MyRemoteHost
//
//  画面キャプチャを管理するクラス
//  ScreenCaptureKit を使用して低遅延で画面を取得する
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Combine
import CoreGraphics
import os

/// キャプチャされたフレームを受け取るデリゲート
protocol ScreenCaptureDelegate: AnyObject {
    /// フレームをキャプチャ（Zero-Copy: IOSurface-backed CVPixelBuffer）
    nonisolated func screenCapture(_ manager: ScreenCaptureManager, didCaptureFrame sampleBuffer: CMSampleBuffer)
    /// 差分フレームをキャプチャ（Dirty Rects付き）
    nonisolated func screenCapture(_ manager: ScreenCaptureManager, didCaptureFrame sampleBuffer: CMSampleBuffer, dirtyRects: [CGRect])
    /// エラー発生
    nonisolated func screenCapture(_ manager: ScreenCaptureManager, didFailWithError error: Error)
}

/// 画面キャプチャの状態
enum CaptureState {
    case idle
    case preparing
    case capturing
    case stopped
    case error(Error)
}

/// ScreenCaptureKit を使用した画面キャプチャマネージャー
@MainActor
class ScreenCaptureManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var availableDisplays: [SCDisplay] = []
    @Published private(set) var selectedDisplay: SCDisplay?
    @Published private(set) var frameRate: Double = 0
    @Published private(set) var capturedFrameCount: Int = 0
    
    // MARK: - Configuration
    
    /// キャプチャ解像度（幅）★ 4K対応
    var captureWidth: Int = 3840
    /// キャプチャ解像度（高さ）★ 4K対応
    var captureHeight: Int = 2160
    /// 目標フレームレート
    var targetFrameRate: Int = 60
    /// キュー深度（バッファに保持するフレーム数）- ★ Phase 2: 最小限のバッファ（ドロップ防止+低遅延）
    var queueDepth: Int = 3  // 2だとドロップリスク、3が最適バランス
    /// Dirty Rects（差分更新）を有効化
    /// ★ Phase 2: nonisolated(unsafe) — キャプチャキュー上で参照
    nonisolated(unsafe) var enableDirtyRects: Bool = true
    /// 10-bit キャプチャ（高色精度）
    var use10Bit: Bool = false  // デフォルトは8-bit、互換性のため
    
    /// ★ Retina最適化モード: 論理解像度に合わせてキャプチャ（Zoom級画質）
    /// true: Retinaディスプレイなら 0.5倍（1/4面積）でキャプチャし、整数倍スケーリングを実現
    var useRetinaScaling: Bool = true
    
    /// ★ Phase 4: 現在のディスプレイスケールファクター (2.0 = Retina)
    @Published private(set) var displayScaleFactor: CGFloat = 2.0
    
    /// ★ Phase 4: 最後にキャプチャした物理ピクセル解像度
    @Published private(set) var lastCapturedPhysicalWidth: Int = 0
    @Published private(set) var lastCapturedPhysicalHeight: Int = 0
    
    // MARK: - Delegate
    /// ★ Phase 2: nonisolated(unsafe)—キャプチャキューから直接アクセス可能
    nonisolated(unsafe) weak var delegate: ScreenCaptureDelegate?
    
    // MARK: - Private Properties
    
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameRateCalculationTimer: Timer?
    private var recentFrameTimes: [CFTimeInterval] = []
    
    /// ★ Phase 2: キャプチャキュー上で安全にカウントするためのアトミックカウンタ
    nonisolated(unsafe) private let _frameCountLock = NSLock()
    nonisolated(unsafe) private var _atomicFrameCount: Int = 0
    /// ★ Phase 2: フレーム時刻追跡（キャプチャキュー安全）
    nonisolated(unsafe) private let _frameTimesLock = NSLock()
    nonisolated(unsafe) private var _atomicFrameTimes: [CFTimeInterval] = []
    
    /// スクリーンショットカウンター（ログ頻度制御用）
    // screenshotCount は動画一本化により廃止
    
    // MARK: - Initialization
    
    override init() {
        super.init()
    }
    
    // MARK: - Public Methods
    
    /// 利用可能なディスプレイを取得
    func fetchAvailableDisplays() async throws {
        state = .preparing
        
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = content.displays
            
            // メインディスプレイを自動選択
            if let mainDisplay = availableDisplays.first {
                selectedDisplay = mainDisplay
            }
            
            state = .idle
            print("[ScreenCapture] 利用可能なディスプレイ: \(availableDisplays.count)個")
            for (index, display) in availableDisplays.enumerated() {
                print("  [\(index)] \(display.width)x\(display.height)")
            }
        } catch {
            state = .error(error)
            throw error
        }
    }
    
    // MARK: - ★ ズーム連動キャプチャ
    
    /// 現在のキャプチャ領域（nil = 全画面）
    private(set) var currentCaptureRegion: CGRect? = nil
    
    /// ログスロットリング: キャプチャ領域変更（500ms間隔）
    private var lastRegionLogTime: Date = .distantPast
    private var wasFullScreen: Bool = true
    
    /// ログスロットリング: 設定更新（前回値と比較）
    private var lastLoggedScale: Double = -1
    private var lastLoggedFPS: Int = -1
    
    /// ★ キャプチャ領域を動的に変更（ズーム連動）
    /// - Parameter normalizedRect: 正規化座標(0.0〜1.0)でのキャプチャ領域。nilで全画面復帰。
    ///
    /// iPhoneのズームに連動してMac側のキャプチャ対象領域を変更する。
    /// 出力解像度は固定のまま、狭い領域だけをキャプチャ → 実効解像度が向上。
    func updateCaptureRegion(_ normalizedRect: CGRect?) async throws {
        guard let stream = stream, let display = selectedDisplay else { return }
        
        // CaptureState確認
        if case .capturing = state {
            // OK
        } else {
            return
        }
        
        let config = SCStreamConfiguration()
        
        if let rect = normalizedRect {
            // 正規化座標 → ディスプレイ座標に変換
            let displayWidth = CGFloat(display.width)
            let displayHeight = CGFloat(display.height)
            
            let sourceX = rect.origin.x * displayWidth
            let sourceY = rect.origin.y * displayHeight
            let sourceW = rect.size.width * displayWidth
            let sourceH = rect.size.height * displayHeight
            
            // sourceRect: キャプチャ対象領域（ディスプレイ論理座標）
            config.sourceRect = CGRect(x: sourceX, y: sourceY, width: sourceW, height: sourceH)
            
            // destinationRect: 出力バッファ内の描画領域（出力サイズ全体に拡大）
            config.destinationRect = CGRect(x: 0, y: 0,
                                            width: CGFloat(config.width),
                                            height: CGFloat(config.height))
            
            currentCaptureRegion = rect
            wasFullScreen = false
            let now = Date()
            if now.timeIntervalSince(lastRegionLogTime) >= 0.5 {
                lastRegionLogTime = now
                print("[ScreenCapture] 🔍 キャプチャ領域変更: (\(String(format: "%.2f", rect.origin.x)), \(String(format: "%.2f", rect.origin.y))) \(String(format: "%.2f", rect.size.width))x\(String(format: "%.2f", rect.size.height))")
            }
        } else {
            // 全画面復帰: sourceRect/destinationRectをリセット
            config.sourceRect = .zero
            config.destinationRect = .zero
            
            currentCaptureRegion = nil
            if !wasFullScreen {
                wasFullScreen = true
                print("[ScreenCapture] 🔍 キャプチャ領域: 全画面復帰")
            }
        }
        
        // 現在の設定を維持
        let currentWidth = captureWidth
        let currentHeight = captureHeight
        let scale = min(
            Double(currentWidth) / Double(display.width),
            Double(currentHeight) / Double(display.height),
            1.0
        )
        var finalWidth = Int(Double(display.width) * scale)
        var finalHeight = Int(Double(display.height) * scale)
        finalWidth += (finalWidth % 2)
        finalHeight += (finalHeight % 2)
        
        config.width = finalWidth
        config.height = finalHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = queueDepth
        config.showsCursor = true
        
        try await stream.updateConfiguration(config)
    }
    
    /// ★ 適応型Retina: キャプチャスケールを動的に切り替え
    /// - Parameter captureScale: 1.0 = 論理解像度, 2.0 = Retina物理解像度
    /// - Parameter fps: フレームレート（nilで現在値維持）
    func updateRetinaScale(_ captureScale: CGFloat, fps: Int? = nil) async throws {
        guard let stream = stream, let display = selectedDisplay else { return }
        
        if case .capturing = state {
            // OK
        } else {
            return
        }
        
        if let newFps = fps {
            targetFrameRate = newFps
        }
        
        let config = SCStreamConfiguration()
        
        // captureScale: 1.0 = 論理解像度(display.width), 2.0 = 物理解像度(display.width * 2)
        let effectiveScale = min(captureScale, 2.0)  // 最大2x
        var finalWidth = Int(Double(display.width) * Double(effectiveScale))
        var finalHeight = Int(Double(display.height) * Double(effectiveScale))
        finalWidth += (finalWidth % 2)
        finalHeight += (finalHeight % 2)
        
        config.width = finalWidth
        config.height = finalHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = queueDepth
        config.showsCursor = true
        
        // キャプチャ領域が設定されている場合は維持
        if let region = currentCaptureRegion {
            let sourceX = Double(display.width) * Double(region.origin.x)
            let sourceY = Double(display.height) * Double(region.origin.y)
            let sourceW = Double(display.width) * Double(region.width)
            let sourceH = Double(display.height) * Double(region.height)
            config.sourceRect = CGRect(x: sourceX, y: sourceY, width: sourceW, height: sourceH)
            config.destinationRect = CGRect(x: 0, y: 0, width: finalWidth, height: finalHeight)
        }
        
        print("[ScreenCapture] ★ Retina切替: \(finalWidth)x\(finalHeight) (scale=\(effectiveScale), FPS=\(targetFrameRate))")
        
        try await stream.updateConfiguration(config)
    }
    
    /// ★ Adaptive Resolution: 解像度スケールとフレームレートを動的に変更
    /// - Parameter scale: 物理ピクセルに対するスケール（例: 0.5 = 面積1/4）
    /// - Parameter fps: 目標フレームレート（nilの場合は現在値を維持）
    func updateResolutionScale(_ scale: Double, fps: Int? = nil) async throws {
        guard let stream = stream, let display = selectedDisplay else { return }
        
        // CaptureState比較エラー回避
        if case .capturing = state {
            // OK
        } else {
            return
        }
        
        // フレームレート更新
        if let newFps = fps {
            targetFrameRate = newFps
        }
        
        if scale != lastLoggedScale || targetFrameRate != lastLoggedFPS {
            lastLoggedScale = scale
            lastLoggedFPS = targetFrameRate
            print("[ScreenCapture] 設定更新: スケール \(scale), FPS \(targetFrameRate)")
        }
        
        let config = SCStreamConfiguration()
        let width = Int(Double(display.width) * scale)
        let height = Int(Double(display.height) * scale)
        
        // 偶数に補正（エンコーダ要件）
        config.width = width + (width % 2)
        config.height = height + (height % 2)
        
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = queueDepth
        config.showsCursor = true
        
        /*
        if enableDirtyRects {
            if #available(macOS 14.0, *) {
                // コンパイラエラー回避のため一時的にコメントアウト
                // config.capturesChangedContentOnly = true
            }
        }
        */
        
        try await stream.updateConfiguration(config)
    }
    
    /// ディスプレイを選択
    func selectDisplay(_ display: SCDisplay) {
        selectedDisplay = display
        
        // ★ Phase 4: スケールファクターを取得
        if let screen = NSScreen.screens.first(where: { screen in
            // displayID でマッチング
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenNumber == display.displayID
        }) {
            displayScaleFactor = screen.backingScaleFactor
            print("[ScreenCapture] ★ スケールファクター: \(displayScaleFactor)x (Retina: \(displayScaleFactor >= 2.0))")
        }
        
        print("[ScreenCapture] ディスプレイ選択: \(display.width)x\(display.height)")
    }
    
    /// キャプチャを開始
    func startCapture() async throws {
        guard let display = selectedDisplay else {
            throw CaptureError.noDisplaySelected
        }
        
        state = .preparing
        print("[ScreenCapture] キャプチャ開始準備中...")
        
        // フィルター作成（ディスプレイ全体をキャプチャ）
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // ストリーム設定
        let configuration = SCStreamConfiguration()
        
        // 解像度設定（ディスプレイサイズに合わせてスケーリング）
        let scale: Double
        if useRetinaScaling {
            // 現在のターゲット解像度からのスケールを計算
            // ★ Retina最適化: 物理解像度（1.0x）を上限とし、強制ダウンスケーリングを撤廃
            let requestedScale = min(
                Double(captureWidth) / Double(display.width),
                Double(captureHeight) / Double(display.height)
            )
            
            // アップスケーリング防止（最大でも等倍まで）
            scale = min(requestedScale, 1.0)
            
            if scale >= 1.0 {
                print("[ScreenCapture] ★ Retina Native Capture: 物理解像度を使用")
            } else {
                print("[ScreenCapture] Scaling: \(String(format: "%.2f", scale))x")
            }
        } else {
            scale = min(
                Double(captureWidth) / Double(display.width),
                Double(captureHeight) / Double(display.height)
            )
        }
        
        // 偶数補正（エンコーダ要件）
        var finalWidth = Int(Double(display.width) * scale)
        var finalHeight = Int(Double(display.height) * scale)
        finalWidth += (finalWidth % 2)
        finalHeight += (finalHeight % 2)
            
        configuration.width = finalWidth
        configuration.height = finalHeight
        
        // フレームレート設定
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        
        // ピクセルフォーマット: NV12（YUV 4:2:0）
        // 10-bit を有効にすると色精度が向上（HEVC Main10 と組み合わせて使用）
        if use10Bit {
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            print("[ScreenCapture] ★ 10-bit キャプチャ: 有効 (P010)")
        } else {
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            print("[ScreenCapture] 8-bit キャプチャ")
        }
        
        // ★ キュー深度（バックプレッシャー時のフレームドロップ制御）- 極小化
        configuration.queueDepth = queueDepth
        
        // カーソルを表示
        configuration.showsCursor = true
        
        // ★ Dirty Rects（差分更新）を有効化 - Static 領域の再送を防止
        if enableDirtyRects {
            // macOS 14.0+ で利用可能
            if #available(macOS 14.0, *) {
                // capturesChangedContentOnly は SCStreamConfiguration のプロパティ
                // これにより SCStreamFrameInfo.dirtyRects がアタッチされる
                print("[ScreenCapture] ★ Dirty Rects: 利用可能 (フレーム情報で取得)")
            }
        }
        
        print("[ScreenCapture] 設定: \(configuration.width)x\(configuration.height) @ \(targetFrameRate)fps")
        
        do {
            // ★ Frame Sequencing (VFR) - 可変フレームレート
            // 静止画時はフレームを送らない設定も可能だが、ここでは最低1fpsを保証
            // configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            
            // ストリーム作成
            stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            
            // 出力設定
            // ★ Phase 2: MainActor排除 — キャプチャキュー上で直接フレーム処理
            streamOutput = CaptureStreamOutput { [weak self] sampleBuffer in
                // ★ MainActorを経由せず、キャプチャキュー上で直接実行
                self?.handleCapturedFrameFast(sampleBuffer)
            }
            try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.myremotehost.screencapture", qos: .userInteractive))
            
            // 開始
            try await stream?.startCapture()
            
            state = .capturing
            startFrameRateMonitoring()
            print("[ScreenCapture] キャプチャ開始成功")
            
        } catch {
            state = .error(error)
            print("[ScreenCapture] キャプチャ開始失敗: \(error)")
            throw error
        }
    }
    
    /// キャプチャを停止
    func stopCapture() async {
        print("[ScreenCapture] キャプチャ停止中...")
        
        stopFrameRateMonitoring()
        
        do {
            try await stream?.stopCapture()
        } catch {
            print("[ScreenCapture] 停止エラー: \(error)")
        }
        
        stream = nil
        streamOutput = nil
        state = .stopped
        
        print("[ScreenCapture] キャプチャ停止完了 (総フレーム数: \(capturedFrameCount))")
    }
    
    // ★ 動画一本化: captureNativeResolutionSnapshot() は廃止
    
    // MARK: - Private Methods
    
    // ★ Phase 2: MainActor排除版 — キャプチャキュー上で直接実行
    // nonisolatedで呼び出されるため、MainActorプロパティにアクセスしない
    nonisolated private func handleCapturedFrameFast(_ sampleBuffer: CMSampleBuffer) {
        // アトミックカウンタ更新
        _frameCountLock.lock()
        _atomicFrameCount += 1
        let count = _atomicFrameCount
        _frameCountLock.unlock()
        
        // フレーム時刻追跡（FPS計算用）
        let currentTime = CACurrentMediaTime()
        _frameTimesLock.lock()
        _atomicFrameTimes.append(currentTime)
        _atomicFrameTimes = _atomicFrameTimes.filter { currentTime - $0 < 1.0 }
        _frameTimesLock.unlock()
        
        // ★ Dirty Rects 抽出（キャプチャキュー上で実行）
        var dirtyRects: [CGRect] = []
        if enableDirtyRects {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let firstAttachment = attachments.first,
               let rectsArray = firstAttachment[SCStreamFrameInfo.dirtyRects.rawValue as CFString] as? [[String: CGFloat]] {
                dirtyRects = rectsArray.compactMap { dict -> CGRect? in
                    guard let x = dict["X"], let y = dict["Y"],
                          let width = dict["Width"], let height = dict["Height"] else { return nil }
                    return CGRect(x: x, y: y, width: width, height: height)
                }
                
                // 変化なし → フレームスキップ（帯域節約）
                if dirtyRects.isEmpty && count > 1 {
                    // 静止フレームは10フレームに1回だけ送信
                    if count % 10 != 0 {
                        return  // スキップ
                    }
                }
            }
        }
        
        // デリゲートに直接通知（MainActorを経由しない）
        // CaptureViewModelのデリゲートメソッドはnonisolatedなので安全
        if dirtyRects.isEmpty {
            delegate?.screenCapture(self, didCaptureFrame: sampleBuffer)
        } else {
            delegate?.screenCapture(self, didCaptureFrame: sampleBuffer, dirtyRects: dirtyRects)
        }
        
        // MainActorプロパティ更新は非同期で（表示用のみ、クリティカルパス外）
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.capturedFrameCount = count
        }
    }
    
    /// 旧バージョン（後方互換用、dirtyRectsなしパスでのみ使用）
    private func handleCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        capturedFrameCount += 1
        let currentTime = CACurrentMediaTime()
        recentFrameTimes.append(currentTime)
        recentFrameTimes = recentFrameTimes.filter { currentTime - $0 < 1.0 }
        delegate?.screenCapture(self, didCaptureFrame: sampleBuffer)
    }
    
    private func startFrameRateMonitoring() {
        frameRateCalculationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self._frameTimesLock.lock()
            let count = self._atomicFrameTimes.count
            self._frameTimesLock.unlock()
            Task { @MainActor in
                self.frameRate = Double(count)
            }
        }
    }
    
    private func stopFrameRateMonitoring() {
        frameRateCalculationTimer?.invalidate()
        frameRateCalculationTimer = nil
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            print("[ScreenCapture] ストリームエラー: \(error)")
            self.state = .error(error)
            self.delegate?.screenCapture(self, didFailWithError: error)
        }
    }
}

// MARK: - CaptureStreamOutput

/// SCStreamOutput を実装するヘルパークラス
private class CaptureStreamOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void
    
    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        
        handler(sampleBuffer)
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case noDisplaySelected
    case permissionDenied
    case configurationFailed
    
    var errorDescription: String? {
        switch self {
        case .noDisplaySelected:
            return "ディスプレイが選択されていません"
        case .permissionDenied:
            return "画面収録の権限がありません"
        case .configurationFailed:
            return "キャプチャ設定に失敗しました"
        }
    }
}
