//
//  ClientDeviceMetrics.swift
//  MyRemoteHost
//
//  Clientから送られてくるデバイスメトリクス定義
//

import Foundation

/// デバイス状態メトリクス (Client -> Host)
/// InputReceiverで受信した後、OmniscientEngineに渡される
struct ClientDeviceMetrics: Sendable {
    /// バッテリー残量 (0.0 - 1.0)
    var batteryLevel: Float = 1.0
    
    /// 充電中・フル充電状態かどうか
    var isCharging: Bool = false
    
    /// サーマルステート (0: Nominal, 1: Fair, 2: Serious, 3: Critical)
    var thermalState: Int = 0
    
    /// 低電力モード有効か
    var isLowPowerModeEnabled: Bool = false
    
    /// 平均FPS (過去1秒間)
    var currentFPS: Double = 0.0
}
