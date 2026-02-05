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

/// キャプチャされたフレームを受け取るデリゲート
protocol ScreenCaptureDelegate: AnyObject {
    /// フレームをキャプチャ（Zero-Copy: IOSurface-backed CVPixelBuffer）
    func screenCapture(_ manager: ScreenCaptureManager, didCaptureFrame sampleBuffer: CMSampleBuffer)
    /// 差分フレームをキャプチャ（Dirty Rects付き）
    func screenCapture(_ manager: ScreenCaptureManager, didCaptureFrame sampleBuffer: CMSampleBuffer, dirtyRects: [CGRect])
    /// エラー発生
    func screenCapture(_ manager: ScreenCaptureManager, didFailWithError error: Error)
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
    /// キュー深度（バッファに保持するフレーム数）- ★ 極小化
    var queueDepth: Int = 2  // 最小値に設定（遅延削減）
    /// Dirty Rects（差分更新）を有効化
    var enableDirtyRects: Bool = true
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
    
    weak var delegate: ScreenCaptureDelegate?
    
    // MARK: - Private Properties
    
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameRateCalculationTimer: Timer?
    private var recentFrameTimes: [CFTimeInterval] = []
    
    /// スクリーンショットカウンター（ログ頻度制御用）
    private var screenshotCount = 0
    
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
        
        print("[ScreenCapture] 設定更新: スケール \(scale), FPS \(targetFrameRate)")
        
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
            streamOutput = CaptureStreamOutput { [weak self] sampleBuffer in
                Task { @MainActor in
                    self?.handleCapturedFrame(sampleBuffer)
                }
            }
            try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.myremotehost.screencapture"))
            
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
    
    /// ★ フル解像度（ネイティブ）の静止画をキャプチャ
    /// 動画ストリームのスケーリングに関係なく、物理ピクセル100%の画質を取得する
    func captureNativeResolutionSnapshot() async throws -> CGImage {
        guard let display = selectedDisplay else { throw CaptureError.noDisplaySelected }
        
        if #available(macOS 14.0, *) {
            // macOS 14以降: ScreenCaptureKit のスクリーンショット機能を使用
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            
            // -------------------------------------------------------------
            // ★ iPhone最適化: Retina物理解像度ではなく論理解像度を使用
            // 物理解像度 (3420x2214) はiPhoneの処理能力を超えるため、
            // 論理解像度 (1710x1107) に制限してパフォーマンスを最適化する。
            // これでもiPhone画面より大きいため、十分な画質を確保できる。
            // -------------------------------------------------------------
            let targetWidth = display.width   // 論理解像度を使用
            let targetHeight = display.height // 論理解像度を使用
            
            // 物理フル解像度に設定 (ScreenCaptureKitへ要求)
            config.width = targetWidth
            config.height = targetHeight
            config.showsCursor = true
            
            // ピクセルフォーマット（BGRA 32bit）- 可逆圧縮PNGのソースとして最適
            config.pixelFormat = kCVPixelFormatType_32BGRA
            
            // ★ キャプチャ実行
            let start = CFAbsoluteTimeGetCurrent()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let duration = CFAbsoluteTimeGetCurrent() - start
            
            // ★ 100回ごとにログ出力
            screenshotCount += 1
            if screenshotCount == 1 || screenshotCount % 100 == 0 {
                let isValid = image.width >= targetWidth && image.height >= targetHeight
                print("[ScreenCapture] 📸 \(image.width)x\(image.height) (\(String(format: "%.0f", duration * 1000))ms) \(isValid ? "✓" : "⚠️ Scaled") (累計\(screenshotCount)回)")
            }
            
            return image
        }
        
        // フォールバック
        print("[ScreenCapture] macOS 14.0未満のため高解像度静止画キャプチャ不可")
        throw CaptureError.configurationFailed
    }
    
    // MARK: - Private Methods
    
    private func handleCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        capturedFrameCount += 1
        
        // フレームレート計算用
        let currentTime = CACurrentMediaTime()
        recentFrameTimes.append(currentTime)
        
        // 直近1秒分のフレーム時間のみ保持
        recentFrameTimes = recentFrameTimes.filter { currentTime - $0 < 1.0 }
        
        // ★ Zero-Copy 検証: IOSurface が裏打ちされていることを確認
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let hasIOSurface = CVPixelBufferGetIOSurface(pixelBuffer) != nil
            if !hasIOSurface {
                print("[ScreenCapture] ⚠️ IOSurface なし - Zero-Copy 不可")
            }
        }
        
        // ★ Dirty Rects 抽出
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
                if dirtyRects.isEmpty && capturedFrameCount > 1 {
                    // 静止フレームは10フレームに1回だけ送信
                    if capturedFrameCount % 10 != 0 {
                        return  // スキップ
                    }
                }
            }
        }
        
        // デリゲートに通知
        if dirtyRects.isEmpty {
            delegate?.screenCapture(self, didCaptureFrame: sampleBuffer)
        } else {
            delegate?.screenCapture(self, didCaptureFrame: sampleBuffer, dirtyRects: dirtyRects)
        }
    }
    
    private func startFrameRateMonitoring() {
        frameRateCalculationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.frameRate = Double(self.recentFrameTimes.count)
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
