//
//  PreviewView.swift
//  MyRemoteHost
//
//  AVSampleBufferDisplayLayer を使用した映像表示ビュー
//  デコードされた映像をリアルタイムで表示する
//

import SwiftUI
import AVFoundation
import CoreMedia
import Combine

// MARK: - NSView Wrapper

/// AVSampleBufferDisplayLayer を内包する NSView
class SampleBufferDisplayView: NSView {
    
    private var displayLayer: AVSampleBufferDisplayLayer!
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        wantsLayer = true
        
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        
        layer?.addSublayer(displayLayer)
    }
    
    override func layout() {
        super.layout()
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
struct PreviewView: NSViewRepresentable {
    typealias NSViewType = SampleBufferDisplayView
    
    @Binding var currentSampleBuffer: CMSampleBuffer?
    
    func makeNSView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        return view
    }
    
    func updateNSView(_ nsView: SampleBufferDisplayView, context: Context) {
        if let buffer = currentSampleBuffer {
            nsView.enqueue(buffer)
        }
    }
}

/// CVPixelBuffer を直接受け取るプレビュービュー
struct PixelBufferPreviewView: NSViewRepresentable {
    typealias NSViewType = SampleBufferDisplayView
    
    let pixelBuffer: CVPixelBuffer?
    let presentationTime: CMTime
    
    func makeNSView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        return view
    }
    
    func updateNSView(_ nsView: SampleBufferDisplayView, context: Context) {
        if let buffer = pixelBuffer {
            nsView.display(pixelBuffer: buffer, presentationTime: presentationTime)
        }
    }
}

// MARK: - Coordinator for Direct Access

/// 外部から直接アクセス可能なプレビュービュー
class PreviewViewCoordinator: ObservableObject {
    private(set) var displayView: SampleBufferDisplayView?
    
    func setDisplayView(_ view: SampleBufferDisplayView) {
        self.displayView = view
    }
    
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async {
            self.displayView?.enqueue(sampleBuffer)
        }
    }
    
    func display(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        DispatchQueue.main.async {
            self.displayView?.display(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        }
    }
    
    func flush() {
        DispatchQueue.main.async {
            self.displayView?.flush()
        }
    }
}

/// Coordinator を使用するプレビュービュー
struct CoordinatedPreviewView: NSViewRepresentable {
    typealias NSViewType = SampleBufferDisplayView
    
    @ObservedObject var coordinator: PreviewViewCoordinator
    
    func makeNSView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        DispatchQueue.main.async {
            coordinator.setDisplayView(view)
        }
        return view
    }
    
    func updateNSView(_ nsView: SampleBufferDisplayView, context: Context) {
        // Coordinator が直接管理するため、ここでは何もしない
    }
}
