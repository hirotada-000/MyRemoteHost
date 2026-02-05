//
//  MetalRenderer.swift
//  MyRemoteHost iphone
//
//  Metal Direct Rendering - AVSampleBufferDisplayLayerを超える超低遅延描画
//  CVPixelBuffer → MTLTexture への Zero-Copy 変換と 120Hz ProMotion 同期
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import QuartzCore

/// Metal Direct Renderer - Zero-Copy YUV描画
class MetalDirectRenderer {
    
    // MARK: - Metal Objects
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var pipelineState: MTLRenderPipelineState?
    
    // MARK: - Configuration
    
    /// 最新フレームのみ保持（古いフレームは破棄）
    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()
    
    /// 描画先のビューサイズ (Aspect Fit計算用)
    var drawableSize: CGSize = .zero
    
    /// ユニフォームバッファ（スケーリング用）
    struct Uniforms {
        var scaleX: Float
        var scaleY: Float
    }
    
    // MARK: - Initialization
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue
        
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else { return nil }
        self.textureCache = textureCache
        
        setupYUVPipeline()
    }
    
    // MARK: - Pipeline Setup
    
    private func setupYUVPipeline() {
        // YUV (BT.709 Video Range) -> RGB 変換シェーダー + Aspect Fit
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };
        
        struct Uniforms {
            float scaleX;
            float scaleY;
        };
        
        vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                                      constant Uniforms &uniforms [[buffer(0)]]) {
            float2 positions[6] = {
                float2(-1, -1), float2(1, -1), float2(-1, 1),
                float2(-1, 1), float2(1, -1), float2(1, 1)
            };
            float2 texCoords[6] = {
                float2(0, 1), float2(1, 1), float2(0, 0),
                float2(0, 0), float2(1, 1), float2(1, 0)
            };
            
            VertexOut out;
            // アスペクト比維持のためのスケーリング
            out.position = float4(positions[vertexID].x * uniforms.scaleX,
                                  positions[vertexID].y * uniforms.scaleY,
                                  0, 1);
            out.texCoord = texCoords[vertexID];
            return out;
        }
        
        // ★ Bicubic Sampling Function (Catmull-Rom Spline)
        // 4x4 近傍ピクセルを使用して滑らかに補間する
        float sampleBicubic(texture2d<float> tex, sampler s, float2 texCoord) {
            float2 texSize = float2(tex.get_width(), tex.get_height());
            float2 invTexSize = 1.0 / texSize;
            
            float2 pixel = texCoord * texSize - 0.5;
            float2 f = fract(pixel);
            float2 i = floor(pixel);
            
            // Catmull-Rom 係数計算
            float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
            float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
            float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
            float2 w3 = f * f * (-0.5 + 0.5 * f);
            
            // 重み付け
            float2 g0 = w0 + w1;
            float2 g1 = w2 + w3;
            float2 h0 = (w1 / g0) - 0.5 + i;
            float2 h1 = (w3 / g1) + 1.5 + i;
            
            // テクスチャ座標オフセット
            float2 texCoord0 = (h0 + 0.5) * invTexSize;
            float2 texCoord1 = (h1 + 0.5) * invTexSize;
            
            // 4回サンプリングで近似 (Linear filtering hardware exploitation)
            float tex00 = tex.sample(s, float2(texCoord0.x, texCoord0.y)).r;
            float tex10 = tex.sample(s, float2(texCoord1.x, texCoord0.y)).r;
            float tex01 = tex.sample(s, float2(texCoord0.x, texCoord1.y)).r;
            float tex11 = tex.sample(s, float2(texCoord1.x, texCoord1.y)).r;
            
            // Y軸方向の補間
            float val0 = mix(tex00, tex10, g1.x / (g0.x + g1.x));
            float val1 = mix(tex01, tex11, g1.x / (g0.x + g1.x));
            
            // X軸方向の補間
            return mix(val0, val1, g1.y / (g0.y + g1.y));
        }

        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> textureY [[texture(0)]],
                                       texture2d<float> textureCbCr [[texture(1)]],
                                       constant Uniforms &uniforms [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            
            // ★ Bicubic Sampling で Yチャンネルを取得 (高画質縮小)
            float y = sampleBicubic(textureY, s, in.texCoord);
            
            // CbCrは解像度が低いのでLinear維持
            float2 cbcr = textureCbCr.sample(s, in.texCoord).rg;
            
            // BT.709 Video Range to RGB
            float3 yuv = float3(y, cbcr.x, cbcr.y);
            float3 offset3 = float3(0.062745, 0.50196, 0.50196);
            float3 yuv_shifted = yuv - offset3;
            
            float3 rgb;
            rgb.r = 1.16438 * yuv_shifted.x + 1.79274 * yuv_shifted.z;
            rgb.g = 1.16438 * yuv_shifted.x - 0.21325 * yuv_shifted.y - 0.53291 * yuv_shifted.z;
            rgb.b = 1.16438 * yuv_shifted.x + 2.11240 * yuv_shifted.y;
            
            // ★ シンプル化: シャープネスフィルターを削除
            // ガタガタに見える原因となるエッジ強調を行わず、素直に出力
            
            return float4(saturate(rgb), 1.0);
        }
        """
        
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let vertexFunction = library.makeFunction(name: "vertexShader")
            let fragmentFunction = library.makeFunction(name: "fragmentShader")
            
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[MetalRenderer] ❌ パイプライン作成失敗: \(error)")
        }
    }
    
    // MARK: - Public Methods
    
    func submitFrame(_ pixelBuffer: CVPixelBuffer) {
        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()
    }
    
    func render(to drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        bufferLock.lock()
        guard let pixelBuffer = latestPixelBuffer else {
            bufferLock.unlock()
            return
        }
        // latestPixelBuffer = nil // ここでnilにするとチラつく可能性があるため、ProMotionSyncRenderer側で制御するか、あるいは維持する
        // 今回は「落ちる」対策より「品質」優先のため、nilセットは描画終了後に行いたいが、
        // ゼロコピーなので保持コストは低い。ただしスレッドセーフにするためロック内でコピーして、ロック外で使う。
        // ここでは前回同様「即解放」ポリシーを守るが、チラツキがあれば改善する。
        latestPixelBuffer = nil
        bufferLock.unlock()
        
        guard let (yTexture, cbcrTexture) = createYUVTextures(from: pixelBuffer) else { return }
        guard let pipelineState = pipelineState else { return }
        
        // ★ Aspect Fit 計算
        var uniforms = Uniforms(scaleX: 1.0, scaleY: 1.0)
        
        if drawableSize.width > 0 && drawableSize.height > 0 {
            let textureWidth = CGFloat(yTexture.width)
            let textureHeight = CGFloat(yTexture.height)
            
            let viewAspect = drawableSize.width / drawableSize.height
            let textureAspect = textureWidth / textureHeight
            
            if textureAspect > viewAspect {
                // 画像が横長 -> 上下に黒帯 (Scale Y を小さく)
                uniforms.scaleY = Float(viewAspect / textureAspect)
            } else {
                // 画像が縦長 -> 左右に黒帯 (Scale X を小さく)
                uniforms.scaleX = Float(textureAspect / viewAspect)
            }
        }
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(cbcrTexture, index: 1)
        // Uniformsを渡す
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
    }
    
    // MARK: - Private Methods
    
    /// NV12 ピクセルバッファから Y と CbCr の2枚のテクスチャを作成
    private func createYUVTextures(from pixelBuffer: CVPixelBuffer) -> (MTLTexture, MTLTexture)? {
        guard let textureCache = textureCache else { return nil }
        
        // NV12 判定
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
              pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            // print("[MetalRenderer] ⚠️ YUVじゃない: \(pixelFormat)")
            return nil
        }
        
        // 1. Y Plane (Index 0, .r8Unorm)
        var yCvTexture: CVMetalTexture?
        let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            yWidth,
            yHeight,
            0,
            &yCvTexture
        )
        
        guard yStatus == kCVReturnSuccess, let yTex = yCvTexture, let yMetalTex = CVMetalTextureGetTexture(yTex) else {
            return nil
        }
        
        // 2. CbCr Plane (Index 1, .rg8Unorm)
        var cbcrCvTexture: CVMetalTexture?
        let cbcrWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let cbcrHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        
        let cbcrStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            cbcrWidth,
            cbcrHeight,
            1,
            &cbcrCvTexture
        )
        
        guard cbcrStatus == kCVReturnSuccess, let cbcrTex = cbcrCvTexture, let cbcrMetalTex = CVMetalTextureGetTexture(cbcrTex) else {
            return nil
        }
        
        return (yMetalTex, cbcrMetalTex)
    }
    
    func flush() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        bufferLock.lock()
        latestPixelBuffer = nil
        bufferLock.unlock()
    }
}

// MARK: - ProMotion Sync Renderer

/// 120Hz ProMotion 同期レンダラー
class ProMotionSyncRenderer {
    
    private let metalRenderer: MetalDirectRenderer
    private var displayLink: CADisplayLink?
    private weak var metalLayer: CAMetalLayer?
    private let commandQueue: MTLCommandQueue
    
    /// フレームカウント（デバッグ用）
    private(set) var frameCount: Int = 0
    private var lastFPSTime: CFTimeInterval = 0
    private(set) var currentFPS: Double = 0
    
    init?(metalLayer: CAMetalLayer) {
        guard let renderer = MetalDirectRenderer() else { return nil }
        self.metalRenderer = renderer
        self.metalLayer = metalLayer
        
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        
        // Metal Layer 設定
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Note: displaySyncEnabled は macOS のみで利用可能（iOSでは自動VSync）
        
        // ★ トリプルバッファリング無効化（遅延削減）
        metalLayer.maximumDrawableCount = 2
        
        print("[ProMotionSync] ✅ 初期化完了")
    }
    
    /// 120Hz ProMotion 同期開始
    func start() {
        guard displayLink == nil else { return }
        
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        
        // ★ 120Hz 設定 (iPhone 13 Pro以降)
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: 120
            )
        }
        
        displayLink?.add(to: .main, forMode: .common)
        lastFPSTime = CACurrentMediaTime()
        print("[ProMotionSync] ✅ 120Hz同期開始")
    }
    
    /// 停止
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        print("[ProMotionSync] 停止")
    }
    
    /// フレーム送信（最新フレームで上書き）
    func submitFrame(_ pixelBuffer: CVPixelBuffer) {
        metalRenderer.submitFrame(pixelBuffer)
    }
    
    /// フラッシュ
    func flush() {
        metalRenderer.flush()
        frameCount = 0
    }
    
    /// ビューのサイズを更新（Aspect Fit用）
    func updateDrawableSize(_ size: CGSize) {
        metalRenderer.drawableSize = size
    }
    
    // MARK: - Display Link Callback
    
    @objc private func tick() {
        guard let metalLayer = metalLayer,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        metalRenderer.render(to: drawable, commandBuffer: commandBuffer)
        commandBuffer.commit()
        
        // FPS計測
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFPSTime
        if elapsed >= 1.0 {
            currentFPS = Double(frameCount) / elapsed
            frameCount = 0
            lastFPSTime = now
        }
    }
}
