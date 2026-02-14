//
//  OmniscientState.swift
//  MyRemoteClient
//
//  Omniscient Auto-Pilotの全状態を集約する構造体
//  Host -> Client へ送信され、HUDで可視化される
//

import Foundation
import CoreGraphics

/// 全知全能コントローラーの状態（スナップショット）
struct OmniscientState: Codable, Sendable {
    // MARK: - Host Metrics
    var hostCPU: Float = 0.0          // 0.0 - 1.0
    var hostMemory: Float = 0.0       // 0.0 - 1.0
    var hostThermalState: Int = 0     // 0:Nominal, 1:Fair, 2:Serious, 3:Critical
    var hostBattery: Float = 1.0      // 0.0 - 1.0
    var isHostCharging: Bool = true
    
    // MARK: - Network Metrics
    var rtt: TimeInterval = 0.0       // Round Trip Time
    var packetLoss: Double = 0.0      // 0.0 - 1.0
    var bandwidthMbps: Double = 0.0   // Estimated Bandwidth
    var networkQuality: String = "Good"
    
    // MARK: - Input/Content Metrics
    var scrollVelocity: Double = 0.0
    var isScrolling: Bool = false
    var contentMotionRatio: Double = 0.0
    var isContentStatic: Bool = false
    
    // MARK: - Client Metrics (Echo back)
    var clientThermalState: Int = 0
    var clientBattery: Float = 1.0
    var clientFPS: Double = 60.0
    
    // MARK: - Decision / Control State (全パラメータ)
    var targetBitrateMbps: Double = 15.0
    var targetFPS: Double = 60.0
    var captureScale: Double = 1.0
    var encoderQuality: Float = 0.0
    var keyFrameInterval: Int = 60
    var codecName: String = "HEVC"
    var profileName: String = "High"
    var resolutionScale: Double = 1.0
    var lowLatencyMode: Bool = true
    var peakMultiplier: Double = 2.0
    var decisionReason: String = ""
    
    // MARK: - Quality Engine Internal
    var engineMode: String = "Balanced"
    
    // MARK: - Pipeline Latency Metrics (Phase 1: 遅延計測基盤)
    /// macOS側: キャプチャ取得→エンコード開始 (ms)
    var captureToEncodeMs: Double = 0.0
    /// macOS側: エンコード処理時間 (ms)
    var encodeDurationMs: Double = 0.0
    /// macOS側: パケット化+送出時間 (ms)
    var packetizeMs: Double = 0.0
    /// macOS壁時計タイムスタンプ (ms) — iPhone側でネットワーク遅延を推定
    var hostWallClockMs: Double = 0.0
    /// フレームドロップ数（macOS側）
    var hostFrameDropCount: Int = 0
    
    // MARK: - iPhone Side Pipeline Metrics (Phase 1)
    /// iPhone側: ネットワーク遊延推定 (ms)
    var networkTransitMs: Double = 0.0
    /// iPhone側: 受信→デコード完了 (ms)
    var receiveToDecodeMs: Double = 0.0
    /// iPhone側: デコード処理時間 (ms)
    var decodeDurationMs: Double = 0.0
    /// iPhone側: レンダリング時間 (ms)
    var renderMs: Double = 0.0
    /// End-to-End合計 (ms)
    var endToEndMs: Double = 0.0
}
