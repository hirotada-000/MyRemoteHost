//
//  DeviceSensor.swift
//  MyRemoteHost iphone
//
//  クライアントデバイス（iPhone）のハードウェア状態を監視するクラス
//  Phase 1: Sensing Layer
//

import UIKit
import Foundation

/// デバイス状態メトリクス (Client)
struct ClientDeviceMetrics: Sendable {
    /// バッテリー残量 (0.0 - 1.0)
    var batteryLevel: Float = 1.0
    
    /// 充電中・フル充電状態かどうか
    var isCharging: Bool = false
    
    /// サーマルステート (0: Nominal, 1: Fair, 2: Serious, 3: Critical)
    var thermalState: Int = 0
    
    /// 低電力モード有効か
    var isLowPowerModeEnabled: Bool = false
}

protocol DeviceSensorDelegate: AnyObject {
    func deviceSensor(_ sensor: DeviceSensor, didUpdateMetrics metrics: ClientDeviceMetrics)
}

class DeviceSensor {
    
    // MARK: - Properties
    
    weak var delegate: DeviceSensorDelegate?
    
    private(set) var currentMetrics = ClientDeviceMetrics()
    
    private var timer: Timer?
    private let monitoringInterval: TimeInterval
    
    // MARK: - Initialization
    
    init(interval: TimeInterval = 2.0) { // iPhoneは頻度少なめでOK
        self.monitoringInterval = interval
        setupInitialMetrics()
    }
    
    private func setupInitialMetrics() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateMetrics()
    }
    
    // MARK: - Public Methods
    
    func startMonitoring() {
        guard timer == nil else { return }
        
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        // 即時更新
        updateMetrics()
        
        // タイマー開始
        timer = Timer.scheduledTimer(withTimeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
        
        // 通知監視（低電力モード変更など）
        NotificationCenter.default.addObserver(self, selector: #selector(powerStateChanged), name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        
        print("[DeviceSensor] クライアントモニタリング開始")
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        NotificationCenter.default.removeObserver(self)
        print("[DeviceSensor] クライアントモニタリング停止")
    }
    
    // MARK: - Private Methods
    
    @objc private func powerStateChanged() {
        updateMetrics()
    }
    
    private func updateMetrics() {
        let device = UIDevice.current
        
        // バッテリー
        let level = device.batteryLevel
        let state = device.batteryState
        let isCharging = (state == .charging || state == .full)
        
        // サーマル
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        
        // 低電力モード
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        
        let newMetrics = ClientDeviceMetrics(
            batteryLevel: level,
            isCharging: isCharging,
            thermalState: thermal,
            isLowPowerModeEnabled: lowPower
        )
        
        currentMetrics = newMetrics
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.deviceSensor(self, didUpdateMetrics: newMetrics)
        }
    }
}
