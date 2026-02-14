//
//  DeviceSensor.swift
//  MyRemoteHost
//
//  ホストデバイス（Mac）のハードウェア状態を監視するクラス
//  Phase 1: Sensing Layer
//

import Foundation
import IOKit.ps
import Darwin

/// デバイス状態メトリクス
struct DeviceMetrics: Sendable {
    /// CPU使用率 (0.0 - 1.0)
    var cpuUsage: Double = 0.0
    
    /// メモリ使用率 (0.0 - 1.0)
    var memoryUsage: Double = 0.0
    
    /// サーマルステート (0: Nominal, 1: Fair, 2: Serious, 3: Critical)
    var thermalState: Int = 0
    
    /// バッテリー残量 (0.0 - 1.0, -1.0 if unknown)
    var batteryLevel: Double = -1.0
    
    /// 充電中かどうか
    var isCharging: Bool = false
}

protocol DeviceSensorDelegate: AnyObject {
    func deviceSensor(_ sensor: DeviceSensor, didUpdateMetrics metrics: DeviceMetrics)
}

class DeviceSensor {
    
    // MARK: - Properties
    
    weak var delegate: DeviceSensorDelegate?
    
    private(set) var currentMetrics = DeviceMetrics()
    
    private var timer: Timer?
    private let monitoringInterval: TimeInterval
    
    // CPU負荷計算用
    private var prevSystemTime: Double = 0
    private var prevUserTime: Double = 0
    private var prevIdleTime: Double = 0
    
    // MARK: - Initialization
    
    init(interval: TimeInterval = 1.0) {
        self.monitoringInterval = interval
        setupInitialMetrics()
    }
    
    private func setupInitialMetrics() {
        // 初期値を一度取得
        updateMetrics()
    }
    
    // MARK: - Public Methods
    
    func startMonitoring() {
        stopMonitoring()
        
        timer = Timer.scheduledTimer(withTimeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
        
        print("[DeviceSensor] モニタリング開始")
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        print("[DeviceSensor] モニタリング停止")
    }
    
    // MARK: - Private Methods
    
    private func updateMetrics() {
        // 1. CPU使用率
        let cpu = getCPUUsage()
        
        // 2. メモリ使用率
        let memory = getMemoryUsage()
        
        // 3. サーマルステート
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        
        // 4. バッテリー情報 (macOS固有)
        let (level, charging) = getBatteryInfo()
        
        // メトリクス更新
        let newMetrics = DeviceMetrics(
            cpuUsage: cpu,
            memoryUsage: memory,
            thermalState: thermal,
            batteryLevel: level,
            isCharging: charging
        )
        
        currentMetrics = newMetrics
        
        // デリゲート通知
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.deviceSensor(self, didUpdateMetrics: newMetrics)
        }
    }
    
    // MARK: - System Info Helpers
    
    private func getCPUUsage() -> Double {
        var cpuInfo: processor_info_array_t!
        var prevCpuInfo: processor_info_array_t!
        var numCpuInfo: mach_msg_type_number_t = 0
        var numPrevCpuInfo: mach_msg_type_number_t = 0
        var numCPUs: UInt32 = 0
        var cpuLoad: host_cpu_load_info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        
        let result = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                                     withUnsafeMutablePointer(to: &cpuLoad) {
                                        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                                            $0
                                        }
                                     }, &count)
        
        if result != KERN_SUCCESS {
            return 0.0
        }
        
        // 簡易計算: (User + System) / (User + System + Idle + Nice)
        let user = Double(cpuLoad.cpu_ticks.0)
        let system = Double(cpuLoad.cpu_ticks.1)
        let idle = Double(cpuLoad.cpu_ticks.2)
        let nice = Double(cpuLoad.cpu_ticks.3)
        
        let total = user + system + idle + nice
        
        // 前回との差分で計算が必要だが、ここでは簡易的にシステム全体の負荷として
        // (本来は前回の値を保持して差分を取るべき)
        // ここでは実装をシンプルにするため、host_cpu_load_info の累積値ではなく
        // 瞬時値を取得できるAPIがないため、差分計算ロジックを入れる
        
        let diffUser = user - prevUserTime
        let diffSystem = system - prevSystemTime
        let diffIdle = idle - prevIdleTime
        // let diffNice = nice
        
        let diffTotal = diffUser + diffSystem + diffIdle // + diffNice
        
        prevUserTime = user
        prevSystemTime = system
        prevIdleTime = idle
        
        if diffTotal > 0 {
            return (diffUser + diffSystem) / diffTotal
        } else {
            return 0.0
        }
    }
    
    private func getMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let active = Double(stats.active_count) * Double(vm_kernel_page_size)
            let wire = Double(stats.wire_count) * Double(vm_kernel_page_size)
            let compressed = Double(stats.compressor_page_count) * Double(vm_kernel_page_size)
            
            let used = active + wire + compressed
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            
            return used / total
        }
        
        return 0.0
    }
    
    private func getBatteryInfo() -> (Double, Bool) {
        // IOKit.ps (Power Sources) を使用
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                if let type = description[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType {
                    let current = description[kIOPSCurrentCapacityKey] as? Double ?? 0
                    let max = description[kIOPSMaxCapacityKey] as? Double ?? 100
                    let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
                    
                    return (current / max, isCharging)
                }
            }
        }
        
        return (-1.0, false) // バッテリーなし（デスクトップ等）
    }
}
