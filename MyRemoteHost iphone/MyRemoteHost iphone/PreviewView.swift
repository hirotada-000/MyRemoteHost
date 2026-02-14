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
        

    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
        displayLayer.frame = bounds
    }
    
    /// CMSampleBuffer を表示キューに追加
    func enqueue(_ sampleBuffer: CMSampleBuffer) {

        
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        
        displayLayer.enqueue(sampleBuffer)
    }
    

    
    /// 表示をクリア
    func flush() {
        displayLayer.flushAndRemoveImage()
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
    
    func makeUIView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        return view
    }
    
    func updateUIView(_ uiView: SampleBufferDisplayView, context: Context) {
        
        if let buffer = currentSampleBuffer {
            uiView.enqueue(buffer)
        }
    }
}

// MARK: - Coordinator for Direct Access

/// 外部から直接アクセス可能なプレビュービュー
class PreviewViewCoordinator: ObservableObject {
    private(set) var displayView: SampleBufferDisplayView?
    
    /// Metal Rendering を使用するかどうか
    @Published var useMetalRendering: Bool = true
    
    /// Metal Renderer
    private var metalRenderer: ProMotionSyncRenderer?
    private var metalLayer: CAMetalLayer?
    

    
    /// 現在のFPS（Metal Rendering時のみ有効）
    var currentFPS: Double {
        metalRenderer?.currentFPS ?? 0
    }
    
    func setDisplayView(_ view: SampleBufferDisplayView) {
        self.displayView = view
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
        
        // SampleBuffer Display View（フォールバック用）
        sampleBufferView = SampleBufferDisplayView(frame: bounds)
        // sampleBufferView.isHidden = true  // ← これが不要になるが、Metal優先なら隠すべき？
        // いや、MetalLayerの下にあれば問題ないが、MetalLayerがframebufferOnlyで透過しないなら隠れていたほうが描画負荷的に良いかも。
        // 元々 showVideoMode で isHidden=true にしていた。
        // MetalLayerがある場合は sampleBufferView は隠すべき。
        // ここでは一旦そのままにし、Coordinatorで制御するか、あるいはMetalLayerが前面にあれば見えない。
        sampleBufferView.isHidden = true 
        addSubview(sampleBufferView)
    }
    

    
    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer?.frame = bounds
        sampleBufferView.frame = bounds
        onLayoutSubviews?(bounds.size)
    }
}
