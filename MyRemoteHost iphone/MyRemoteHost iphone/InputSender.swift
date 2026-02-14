//
//  InputSender.swift
//  MyRemoteHost iphone
//
//  タッチイベントをMacに送信するクラス
//  Phase 3: 入力制御
//

import Foundation
import Network

/// 入力送信デリゲート
protocol InputSenderDelegate: AnyObject {
    func inputSender(_ sender: InputSender, didChangeState connected: Bool)
    func inputSender(_ sender: InputSender, didFailWithError error: Error)
    func inputSender(_ sender: InputSender, didReceiveAuthResult approved: Bool)  // ★ UDP認証結果受信
}

/// 入力イベント送信クラス
class InputSender {
    
    // MARK: - Types
    
    /// 入力イベントタイプ
    enum InputEventType: UInt8 {
        case mouseMove = 0x10
        case mouseDown = 0x11
        case mouseUp = 0x12
        case mouseScroll = 0x13
        case keyDown = 0x20
        case keyUp = 0x21
        case zoomRequest = 0x30  // ★ ズームリクエスト（ROI送信要求）
        case telemetry = 0x40    // ★ Phase 1: クライアントテレメトリ
        case registration = 0xFE  // ★ クライアント登録
    }
    
    /// マウスボタン
    enum MouseButton: UInt8 {
        case left = 0
        case right = 1
        case middle = 2
    }
    
    // MARK: - Properties
    
    weak var delegate: InputSenderDelegate?
    
    private var connection: NWConnection?
    private let sendQueue = DispatchQueue(label: "com.myremotehost.inputsender", qos: .userInteractive)
    
    /// 接続先ホスト
    private var hostAddress: String = ""
    
    /// 接続先ポート
    private let port: UInt16 = NetworkTransportConfiguration.default.inputPort
    
    /// 接続状態
    private(set) var isConnected: Bool = false
    
    /// 前回のズーム状態（ログ頻度制御用）
    private var lastLoggedZoomState: Bool? = nil
    
    /// 送信エラーカウンター
    private var sendErrorCount = 0
    
    /// 最後の送信エラーログ時刻
    private var lastSendErrorLogTime: Date?
    
    // MARK: - Public Methods
    
    /// ★ Phase 3: 入力イベントスロットリング
    /// 最小送信間隔 (30ms = 約30fps)
    private let minEventInterval: TimeInterval = 0.03
    
    /// 前回のイベント送信時刻
    private var lastMouseMoveTime: Date?
    private var lastScrollTime: Date?
    private var lastZoomRequestTime: Date?
    
    // MARK: - Public Methods
    
    /// Macに接続
    func connect(to host: String) {
        hostAddress = host
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        connection = NWConnection(to: endpoint, using: .udp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.isConnected = true
                DispatchQueue.main.async {
                    self.delegate?.inputSender(self, didChangeState: true)
                }
                print("[InputSender] 接続完了: \(host):\(self.port)")
                // ★ UDP受信ループ開始（認証結果0xAA待ち）
                self.startReceiveLoop()
                
            case .failed(let error):
                self.isConnected = false
                DispatchQueue.main.async {
                    self.delegate?.inputSender(self, didFailWithError: error)
                }
                print("[InputSender] 接続失敗: \(error)")
                
            case .cancelled:
                self.isConnected = false
                DispatchQueue.main.async {
                    self.delegate?.inputSender(self, didChangeState: false)
                }
                
            default:
                break
            }
        }
        
        connection?.start(queue: sendQueue)
    }
    
    /// 切断
    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }
    
    // MARK: - Input Event Methods
    
    /// マウス移動を送信（正規化座標 0.0-1.0）
    func sendMouseMove(normalizedX: Float, normalizedY: Float) {
        // スロットリング: 30ms経過していない場合はスキップ
        if let lastTime = lastMouseMoveTime, Date().timeIntervalSince(lastTime) < minEventInterval {
            return
        }
        lastMouseMoveTime = Date()

        var data = Data()
        data.append(InputEventType.mouseMove.rawValue)
        data.append(timestampBytes())
        data.append(floatBytes(normalizedX))
        data.append(floatBytes(normalizedY))
        
        sendData(data)
    }
    
    /// マウスダウンを送信
    func sendMouseDown(button: MouseButton = .left) {
        var data = Data()
        data.append(InputEventType.mouseDown.rawValue)
        data.append(timestampBytes())
        data.append(button.rawValue)
        
        sendData(data)
    }
    
    /// マウスアップを送信
    func sendMouseUp(button: MouseButton = .left) {
        var data = Data()
        data.append(InputEventType.mouseUp.rawValue)
        data.append(timestampBytes())
        data.append(button.rawValue)
        
        sendData(data)
    }
    
    /// スクロールを送信
    func sendScroll(deltaX: Float, deltaY: Float) {
        // スロットリング: 30ms経過していない場合はスキップ
        if let lastTime = lastScrollTime, Date().timeIntervalSince(lastTime) < minEventInterval {
            return
        }
        lastScrollTime = Date()

        var data = Data()
        data.append(InputEventType.mouseScroll.rawValue)
        data.append(timestampBytes())
        data.append(floatBytes(deltaX))
        data.append(floatBytes(deltaY))
        
        sendData(data)
    }
    
    /// キーダウンを送信
    func sendKeyDown(keyCode: UInt16) {
        var data = Data()
        data.append(InputEventType.keyDown.rawValue)
        data.append(timestampBytes())
        data.append(uint16Bytes(keyCode))
        
        sendData(data)
    }
    
    /// キーアップを送信
    func sendKeyUp(keyCode: UInt16) {
        var data = Data()
        data.append(InputEventType.keyUp.rawValue)
        data.append(timestampBytes())
        data.append(uint16Bytes(keyCode))
        
        sendData(data)
    }
    
    /// ★ ズームリクエストを送信（ROI高解像度キャプチャ要求）
    /// - Parameters:
    ///   - isZooming: ズーム中かどうか
    ///   - visibleRect: 表示領域（正規化座標 0〜1）
    ///   - zoomScale: ズーム倍率
    func sendZoomRequest(isZooming: Bool, visibleRect: CGRect, zoomScale: CGFloat) {
        guard isConnected else {
            let now = Date()
            if lastSendErrorLogTime == nil || now.timeIntervalSince(lastSendErrorLogTime!) > 5.0 {
                print("[InputSender] ⚠️ ズームリクエスト送信失敗: 未接続")
                lastSendErrorLogTime = now
            }
            return
        }

        // 状態変化（開始/終了）は即時送信し、それ以外（継続中の座標更新）はスロットリング
        let stateChanged = (lastLoggedZoomState != isZooming)
        
        if !stateChanged {
            if let lastTime = lastZoomRequestTime, Date().timeIntervalSince(lastTime) < minEventInterval {
                return
            }
        }
        lastZoomRequestTime = Date()
        
        var data = Data()
        data.append(InputEventType.zoomRequest.rawValue)
        data.append(timestampBytes())
        data.append(isZooming ? 1 : 0)  // 1バイト: ズーム状態
        
        // 表示領域（各4バイト float）
        data.append(floatBytes(Float(visibleRect.origin.x)))
        data.append(floatBytes(Float(visibleRect.origin.y)))
        data.append(floatBytes(Float(visibleRect.size.width)))
        data.append(floatBytes(Float(visibleRect.size.height)))
        
        // ズーム倍率（4バイト float）
        data.append(floatBytes(Float(zoomScale)))
        
        // 状態変化時のみログ出力
        if stateChanged {
            print("[InputSender] 🔍 ズーム\(isZooming ? "開始" : "解除"): \(String(format: "%.1f", zoomScale))x")
            lastLoggedZoomState = isZooming
        }
        sendData(data)
    }
    
    func sendRegistration(listenPort: UInt16, userRecordID: String?) {
        guard isConnected else {
            print("[InputSender] ⚠️ 登録送信失敗: 未接続")
            return
        }
        
        var data = Data()
        data.append(InputEventType.registration.rawValue)  // 0xFE
        data.append(timestampBytes())
        
        // リスニングポート（2バイト）
        var port = listenPort.bigEndian
        data.append(Data(bytes: &port, count: 2))
        
        // userRecordID（UTF8文字列）
        if let userRecordID = userRecordID {
            data.append(Data(userRecordID.utf8))
        }
        
        print("[InputSender] 📤 登録パケット送信: \(data.count)バイト (port:\(listenPort))")
        
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[InputSender] ❌ 登録送信エラー: \(error)")
            } else {
                print("[InputSender] ✅ 登録パケット送信成功")
            }
        })
    }
    
    /// ★ Phase 1: テレメトリ送信
    func sendTelemetry(metrics: ClientDeviceMetrics, fps: Double) {
        // オフラインでもエラーログを出さない（頻繁に呼ばれるため）
        guard isConnected else { return }
        
        var data = Data()
        data.append(InputEventType.telemetry.rawValue) // 0x40
        data.append(timestampBytes()) // 8 bytes
        
        // batteryLevel (4 bytes float)
        data.append(floatBytes(metrics.batteryLevel))
        
        // isCharging (1 byte bool)
        data.append(metrics.isCharging ? 1 : 0)
        
        // thermalState (1 byte int)
        data.append(UInt8(metrics.thermalState))
        
        // isLowPowerMode (1 byte bool)
        data.append(metrics.isLowPowerModeEnabled ? 1 : 0)
        
        // fps (8 bytes double) - metricsには含まれていないため外から渡すか、metricsに含めるか
        // ClientDeviceMetrics定義を確認するとfpsは含まれていないので、別途渡すか、構造体を拡張する。
        // ここでは引数fpsを使用して送信する。
        var fpsVal = fps.bitPattern.bigEndian
        data.append(Data(bytes: &fpsVal, count: 8))
        
        // 計 1 + 8 + 4 + 1 + 1 + 1 + 8 = 24 bytes
        
        sendData(data)
    }
    
    // MARK: - Private Methods
    
    /// ★ UDP受信ループ（認証結果0xAA待ち）
    private func startReceiveLoop() {
        guard let connection = connection else { return }
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] content, _, _, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[InputSender] ⚠️ 受信エラー: \(error)")
                return
            }
            
            if let data = content, data.count >= 2, data[0] == 0xAA {
                let approved = data[1] == 0x01
                print("[InputSender] 🔑 UDP認証結果受信: \(approved ? "許可" : "拒否")")
                DispatchQueue.main.async {
                    self.delegate?.inputSender(self, didReceiveAuthResult: approved)
                }
            }
            
            // 継続受信
            self.startReceiveLoop()
        }
    }
    
    private func sendData(_ data: Data) {
        guard isConnected else { return }
        
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error, let self = self {
                self.sendErrorCount += 1
                let now = Date()
                if self.lastSendErrorLogTime == nil || now.timeIntervalSince(self.lastSendErrorLogTime!) > 5.0 {
                    print("[InputSender] 送信エラー: \(error) (累計\(self.sendErrorCount)回)")
                    self.lastSendErrorLogTime = now
                }
            }
        })
    }
    
    private func timestampBytes() -> Data {
        var timestamp = UInt64(Date().timeIntervalSince1970 * 1000).bigEndian
        return Data(bytes: &timestamp, count: 8)
    }
    
    private func floatBytes(_ value: Float) -> Data {
        var v = value.bitPattern.bigEndian
        return Data(bytes: &v, count: 4)
    }
    
    private func uint16Bytes(_ value: UInt16) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 2)
    }
}
