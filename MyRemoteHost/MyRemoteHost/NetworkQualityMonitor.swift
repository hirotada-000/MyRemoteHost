//
//  NetworkQualityMonitor.swift
//  MyRemoteHost
//
//  ネットワーク品質をモニタリングし、適応型品質制御を行うクラス
//  Phase 1: 適応型品質制御の実装
//

import Foundation
import Combine

/// ネットワーク品質レベル
enum NetworkQualityLevel: String, CaseIterable {
    case excellent = "Excellent"  // RTT < 20ms
    case good = "Good"            // RTT 20-50ms
    case moderate = "Moderate"    // RTT 50-100ms
    case poor = "Poor"            // RTT > 100ms
    
    /// 推奨ビットレート (Mbps)
    var recommendedBitrateMbps: Int {
        switch self {
        case .excellent: return 30
        case .good: return 20
        case .moderate: return 10
        case .poor: return 5
        }
    }
    
    /// 推奨FPS
    var recommendedFPS: Int {
        switch self {
        case .excellent: return 60
        case .good: return 60
        case .moderate: return 30
        case .poor: return 30
        }
    }
    
    /// 推奨解像度スケール (1.0 = フル解像度)
    var recommendedResolutionScale: Double {
        switch self {
        case .excellent: return 1.0
        case .good: return 1.0
        case .moderate: return 0.75
        case .poor: return 0.5
        }
    }
}

/// ネットワーク品質測定結果
struct NetworkQualityMetrics {
    var rtt: TimeInterval = 0.016           // Round Trip Time (秒)
    var packetLossRate: Double = 0.0         // パケットロス率 (0.0-1.0)
    var jitter: TimeInterval = 0.0           // ジッター (秒)
    var bandwidth: Double = 0.0              // 推定帯域 (Mbps)
    
    /// 品質レベルを判定
    var qualityLevel: NetworkQualityLevel {
        if rtt < 0.020 && packetLossRate < 0.01 {
            return .excellent
        } else if rtt < 0.050 && packetLossRate < 0.03 {
            return .good
        } else if rtt < 0.100 && packetLossRate < 0.05 {
            return .moderate
        } else {
            return .poor
        }
    }
}

/// ネットワーク品質変化デリゲート
protocol NetworkQualityMonitorDelegate: AnyObject {
    func networkQualityMonitor(_ monitor: NetworkQualityMonitor, didChangeQuality quality: NetworkQualityLevel)
    func networkQualityMonitor(_ monitor: NetworkQualityMonitor, didUpdateMetrics metrics: NetworkQualityMetrics)
}

/// ネットワーク品質モニタークラス
class NetworkQualityMonitor: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var currentMetrics = NetworkQualityMetrics()
    @Published private(set) var qualityLevel: NetworkQualityLevel = .good
    @Published private(set) var isMonitoring = false
    
    // MARK: - Properties
    
    weak var delegate: NetworkQualityMonitorDelegate?
    
    /// RTT履歴（平均計算用）
    private var rttHistory: [TimeInterval] = []
    private let rttHistorySize = 10
    
    /// Pingシーケンス番号
    private var pingSequence: UInt32 = 0
    
    /// 送信済みPingのタイムスタンプ
    private var pendingPings: [UInt32: Date] = [:]
    
    /// 受信カウント（パケットロス計算用）
    private var sentCount: Int = 0
    private var receivedCount: Int = 0
    
    /// モニタリングタイマー
    private var monitoringTimer: Timer?
    
    /// 品質変化のしきい値（頻繁な変動を防ぐ）
    private var lastQualityLevel: NetworkQualityLevel = .good
    private var qualityChangeCounter = 0
    private let qualityChangeThreshold = 3  // 3回連続で同じ判定なら変更
    
    // MARK: - Phase 4: Network Simulation
    
    enum DebugNetworkCondition {
        case normal
        case highLatency   // RTT = 200ms
        case packetLoss    // Loss = 10%
        case congestion    // Bandwidth = 3Mbps
        case excellent     // RTT = 5ms, Loss = 0%
    }
    
    /// デバッグ用シミュレーションモード（nilなら通常動作）
    @Published var debugSimulation: DebugNetworkCondition? = nil
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Public Methods
    
    /// モニタリング開始
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        // 1秒ごとに品質を評価
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.evaluateQuality()
        }
        
        print("[NetworkQualityMonitor] モニタリング開始")
    }
    
    /// モニタリング停止
    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        isMonitoring = false
        
        // リセット
        rttHistory.removeAll()
        pendingPings.removeAll()
        sentCount = 0
        receivedCount = 0
        
        print("[NetworkQualityMonitor] モニタリング停止")
    }
    
    /// Pingパケットを生成（送信時に呼び出す）
    func generatePingPacket() -> Data {
        let sequence = pingSequence
        pingSequence += 1
        
        pendingPings[sequence] = Date()
        sentCount += 1
        
        // Pingパケット: [0xEE] [4バイト: シーケンス番号]
        var packet = Data([0xEE])
        var seq = sequence.bigEndian
        packet.append(Data(bytes: &seq, count: 4))
        
        return packet
    }
    
    /// Pong応答を処理（受信時に呼び出す）
    func processPongPacket(_ data: Data) {
        guard data.count >= 5, data[0] == 0xEF else { return }
        
        let sequence = data.subdata(in: 1..<5).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        
        guard let sentTime = pendingPings.removeValue(forKey: sequence) else { return }
        
        let rtt = Date().timeIntervalSince(sentTime)
        receivedCount += 1
        
        // RTT履歴に追加
        rttHistory.append(rtt)
        if rttHistory.count > rttHistorySize {
            rttHistory.removeFirst()
        }
        
        // 平均RTTを計算
        let averageRTT = rttHistory.reduce(0, +) / Double(rttHistory.count)
        
        // ジッターを計算（標準偏差）
        let jitter: TimeInterval
        if rttHistory.count > 1 {
            let variance = rttHistory.map { pow($0 - averageRTT, 2) }.reduce(0, +) / Double(rttHistory.count - 1)
            jitter = sqrt(variance)
        } else {
            jitter = 0
        }
        
        // パケットロス率を計算
        let packetLossRate = sentCount > 0 ? Double(sentCount - receivedCount) / Double(sentCount) : 0.0
        
        // メトリクス更新
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentMetrics.rtt = averageRTT
            self.currentMetrics.packetLossRate = packetLossRate
            self.currentMetrics.jitter = jitter
            
            self.delegate?.networkQualityMonitor(self, didUpdateMetrics: self.currentMetrics)
        }
    }
    
    /// 外部からRTTを直接更新（既存のハートビートを利用する場合）
    func updateRTT(_ rtt: TimeInterval) {
        rttHistory.append(rtt)
        if rttHistory.count > rttHistorySize {
            rttHistory.removeFirst()
        }
        
        let averageRTT = rttHistory.reduce(0, +) / Double(rttHistory.count)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentMetrics.rtt = averageRTT
        }
    }
    
    // MARK: - Private Methods
    
    private func evaluateQuality() {
        // ★ Phase 4: シミュレーションオーバーライド
        if let simulation = debugSimulation {
            applySimulation(simulation)
            return // 通常の評価をスキップ
        }
        
        let newLevel = currentMetrics.qualityLevel
        
        // 頻繁な変動を防ぐため、連続で同じ判定が出た場合のみ変更
        if newLevel == lastQualityLevel {
            qualityChangeCounter = 0
        } else {
            qualityChangeCounter += 1
            if qualityChangeCounter >= qualityChangeThreshold {
                lastQualityLevel = newLevel
                qualityChangeCounter = 0
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.qualityLevel = newLevel
                    self.delegate?.networkQualityMonitor(self, didChangeQuality: newLevel)
                    
                    print("[NetworkQualityMonitor] 品質レベル変更: \(newLevel.rawValue) (RTT: \(String(format: "%.1f", self.currentMetrics.rtt * 1000))ms)")
                }
            }
        }
    }
    
    /// シミュレーション値を適用
    private func applySimulation(_ condition: DebugNetworkCondition) {
        var simulatedMetrics = currentMetrics
        var simulatedLevel: NetworkQualityLevel = .good
        
        switch condition {
        case .normal:
            return // 何もしない（またはシミュレーション解除）
        case .highLatency:
            simulatedMetrics.rtt = 0.200 // 200ms
            simulatedLevel = .poor
        case .packetLoss:
            simulatedMetrics.packetLossRate = 0.10 // 10%
            simulatedLevel = .poor
        case .congestion:
            simulatedMetrics.bandwidth = 3.0 // 3Mbps
            simulatedLevel = .moderate // RTT次第だが簡易的に
        case .excellent:
            simulatedMetrics.rtt = 0.005 // 5ms
            simulatedLevel = .excellent
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentMetrics = simulatedMetrics
            self.qualityLevel = simulatedLevel
            self.delegate?.networkQualityMonitor(self, didUpdateMetrics: simulatedMetrics)
            self.delegate?.networkQualityMonitor(self, didChangeQuality: simulatedLevel)
            
            print("[NetworkQualityMonitor] 🧪 Simulation: \(condition) -> \(simulatedLevel.rawValue)")
        }
    }
    
    /// 古いPingをクリーンアップ（タイムアウト処理）
    func cleanupStalePings() {
        let timeout: TimeInterval = 5.0
        let now = Date()
        
        for (sequence, sentTime) in pendingPings {
            if now.timeIntervalSince(sentTime) > timeout {
                pendingPings.removeValue(forKey: sequence)
                // タイムアウト = ロスとしてカウント
            }
        }
    }
}
