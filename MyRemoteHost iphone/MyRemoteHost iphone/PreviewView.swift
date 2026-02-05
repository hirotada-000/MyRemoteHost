//
//  PreviewView.swift
//  MyRemoteClient
//
//  AVSampleBufferDisplayLayer を使用した映像表示ビュー（iOS版）
//

import SwiftUI
import AVFoundation
import CoreMedia
import Combine
import Metal

// MARK: - UIView Wrapper

/// AVSampleBufferDisplayLayer を内包する UIView
class SampleBufferDisplayView: UIView {
    
    private var displayLayer: AVSampleBufferDisplayLayer!
    
    /// ★ 静止画表示用 ImageView（最高画質JPEG用）
    private var imageView: UIImageView!
    
    /// ★ PNG表示中フラグ（動画フレームによる上書きを防止）
    private(set) var isPNGDisplaying: Bool = false
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        // 動画レイヤー
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
        
        // ★ 静止画 ImageView（動画レイヤーの上に配置）
        imageView = UIImageView(frame: bounds)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.isHidden = true // デフォルトは動画モード
        
        // ★ Pixel Perfect Rendering: データを壊さずに綺麗に縮小する設定
        // minificationFilter: .trilinear (ミップマップを使用した高品質縮小)
        imageView.layer.minificationFilter = .trilinear
        // magnificationFilter: .trilinear (拡大時も滑らかに)
        imageView.layer.magnificationFilter = .trilinear
        // contentsScale: Retinaディスプレイのピクセル密度に合わせる
        imageView.layer.contentsScale = UIScreen.main.scale
        
        addSubview(imageView)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
        imageView.frame = bounds
    }
    
    /// CMSampleBuffer を表示キューに追加
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // ★ PNG表示中は動画フレームをスキップ（PNGが上書きされるのを防止）
        if isPNGDisplaying {
            return
        }
        // ★ 動画表示時は ImageView を隠す
        if !imageView.isHidden {
            imageView.isHidden = true
            imageView.image = nil
        }
        
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        
        displayLayer.enqueue(sampleBuffer)
    }
    
    /// ★ PNG/静止画データを表示（またはクリア）
    func displayPNG(data: Data?) {
        if let data = data, let image = UIImage(data: data) {
            displayImage(image)
            isPNGDisplaying = true  // ★ PNG表示中フラグを立てる
        } else {
            // 動画モード復帰
            isPNGDisplaying = false  // ★ フラグを解除
            imageView.isHidden = true
            imageView.image = nil
        }
    }
    
    /// ★ UIImage を直接表示
    func displayImage(_ image: UIImage) {
        imageView.image = image
        imageView.isHidden = false
        isPNGDisplaying = true  // ★ PNG表示中フラグを立てる
        // 動画レイヤーをクリア（任意）
        // displayLayer.flushAndRemoveImage()
    }
    
    /// 表示をクリア
    func flush() {
        displayLayer.flushAndRemoveImage()
        imageView.image = nil
        imageView.isHidden = true
    }
    
    /// CVPixelBuffer から CMSampleBuffer を作成して表示
    func display(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard let format = formatDescription else { return }
        
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        if let buffer = sampleBuffer {
            enqueue(buffer)
        }
    }
}

// MARK: - SwiftUI View

/// SwiftUI で使用可能な映像プレビュービュー
struct PreviewView: UIViewRepresentable {
    typealias UIViewType = SampleBufferDisplayView
    
    @Binding var currentSampleBuffer: CMSampleBuffer?
    /// ★ PNG データ（静止画モード用）
    @Binding var currentPNGData: Data?
    
    func makeUIView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        return view
    }
    
    func updateUIView(_ uiView: SampleBufferDisplayView, context: Context) {
        // ★ PNG データの更新チェック
        uiView.displayPNG(data: currentPNGData)
        
        if let buffer = currentSampleBuffer {
            uiView.enqueue(buffer)
        }
    }
}

// MARK: - Coordinator for Direct Access

/// 外部から直接アクセス可能なプレビュービュー
class PreviewViewCoordinator: ObservableObject {
    private(set) var displayView: SampleBufferDisplayView?
    
    /// ★ MetalPreviewUIViewへの参照（PNG/動画モード切替用）
    private weak var metalPreviewView: MetalPreviewUIView?
    
    /// ★ Metal Direct Rendering 対応
    private var metalRenderer: ProMotionSyncRenderer?
    private weak var metalLayer: CAMetalLayer?
    
    /// Metal Rendering を使用するかどうか（デフォルト: true）
    var useMetalRendering: Bool = true
    
    /// PNG表示カウンター（ログ頻度制御用）
    private var pngDisplayCount = 0
    
    /// 現在のFPS（Metal Rendering時のみ有効）
    var currentFPS: Double {
        metalRenderer?.currentFPS ?? 0
    }
    
    func setDisplayView(_ view: SampleBufferDisplayView) {
        self.displayView = view
    }
    
    /// ★ MetalPreviewUIViewを設定
    func setMetalPreviewView(_ view: MetalPreviewUIView) {
        self.metalPreviewView = view
    }
    
    /// ★ Metal Layer を設定して ProMotion 同期開始
    func setupMetalRendering(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        self.metalRenderer = ProMotionSyncRenderer(metalLayer: metalLayer)
        metalRenderer?.start()
        print("[PreviewCoordinator] ★ Metal Rendering 開始")
    }
    
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async {
            self.displayView?.enqueue(sampleBuffer)
        }
    }
    
    func display(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        if useMetalRendering, let renderer = metalRenderer {
            // ★ Metal Direct Rendering（最短パス）
            renderer.submitFrame(pixelBuffer)
        } else {
            // フォールバック: AVSampleBufferDisplayLayer
            DispatchQueue.main.async {
                self.displayView?.display(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
        }
    }
    
    func flush() {
        metalRenderer?.flush()
        DispatchQueue.main.async {
            self.displayView?.flush()
        }
    }
    
    /// Metal Rendering を停止
    func stopMetalRendering() {
        metalRenderer?.stop()
        metalRenderer = nil
    }
    
    /// ビューサイズ更新通知
    func updateDrawableSize(_ size: CGSize) {
        metalRenderer?.updateDrawableSize(size)
    }
    
    /// ★ PNG データを表示
    func displayPNG(_ data: Data?) {
        guard let data = data else {
            // ★ 動画モード復帰 (メインスレッドで実行)
            DispatchQueue.main.async {
                self.metalPreviewView?.showVideoMode()
                self.displayView?.displayPNG(data: nil)
            }
            return
        }
        
        // ★ PNGモード表示切り替え (メインスレッドで即座に実行)
        DispatchQueue.main.async {
            self.metalPreviewView?.showPNGMode()
        }
        
        // ★ バックグラウンドでUIImage生成（メインスレッドブロック回避）
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = UIImage(data: data) else {
                print("[PreviewCoordinator] ⚠️ Failed to create image from data")
                DispatchQueue.main.async {
                    self.displayView?.displayPNG(data: nil)
                }
                return
            }
            
            // ★ メインスレッドで表示のみ実行
            DispatchQueue.main.async {
                // 解像度検証ログ（100回ごと）
                self.pngDisplayCount += 1
                if self.pngDisplayCount == 1 || self.pngDisplayCount % 100 == 0 {
                    let pixelW = image.size.width * image.scale
                    let pixelH = image.size.height * image.scale
                    print("[PreviewCoordinator] 🖼️ PNG表示: \(Int(pixelW))x\(Int(pixelH))px (累計\(self.pngDisplayCount)回)")
                }
                
                self.displayView?.displayImage(image)
            }
        }
    }
}

/// Coordinator を使用するプレビュービュー
struct CoordinatedPreviewView: UIViewRepresentable {
    typealias UIViewType = MetalPreviewUIView
    
    @ObservedObject var coordinator: PreviewViewCoordinator
    
    func makeUIView(context: Context) -> MetalPreviewUIView {
        let view = MetalPreviewUIView()
        
        // Metal Rendering セットアップ
        if coordinator.useMetalRendering, let metalLayer = view.metalLayer {
            coordinator.setupMetalRendering(metalLayer: metalLayer)
        }
        
        // フォールバック用の SampleBufferDisplayView も設定
        DispatchQueue.main.async {
            coordinator.setDisplayView(view.sampleBufferView)
            coordinator.setMetalPreviewView(view)  // ★ PNG/動画モード切替用
        }
        
        // レイアウト変更検知
        view.onLayoutSubviews = { size in
            coordinator.updateDrawableSize(size)
        }
        
        return view
    }
    
    func updateUIView(_ uiView: MetalPreviewUIView, context: Context) {
        // Coordinator が直接管理するため、ここでは何もしない
    }
}

// MARK: - Metal Preview UIView

/// Metal Layer と AVSampleBufferDisplayLayer の両方を持つビュー
class MetalPreviewUIView: UIView {
    
    /// レイアウト変更通知クロージャ
    var onLayoutSubviews: ((CGSize) -> Void)?
    
    /// Metal Layer（Metal Rendering用）
    private(set) var metalLayer: CAMetalLayer?
    
    /// SampleBuffer Display View（フォールバック用）
    private(set) var sampleBufferView: SampleBufferDisplayView!
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }
    
    private func setupLayers() {
        backgroundColor = .black
        
        // Metal Layer（最前面）
        if let device = MTLCreateSystemDefaultDevice() {
            let metal = CAMetalLayer()
            metal.device = device
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.contentsScale = UIScreen.main.scale
            layer.addSublayer(metal)
            self.metalLayer = metal
        }
        
        // SampleBuffer Display View（PNG表示用）
        sampleBufferView = SampleBufferDisplayView(frame: bounds)
        sampleBufferView.isHidden = true  // ★ 初期状態は非表示（動画モード）
        addSubview(sampleBufferView)
    }
    
    /// ★ PNGモード: Metal Layerを非表示にしてPNG表示を有効化
    func showPNGMode() {
        metalLayer?.isHidden = true
        sampleBufferView.isHidden = false
        sampleBufferView.backgroundColor = .black
    }
    
    /// ★ 動画モード: Metal Layerを表示してsampleBufferViewを非表示
    func showVideoMode() {
        metalLayer?.isHidden = false
        sampleBufferView.isHidden = true
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer?.frame = bounds
        sampleBufferView.frame = bounds
        onLayoutSubviews?(bounds.size)
    }
}
