//
//  InputReceiver.swift
//  MyRemoteHost
//
//  iPhoneからの入力イベントを受信してMacで再現するクラス
//  Phase 3: 入力制御
//
//  要件: Accessibility権限（System Preferences > Privacy & Security > Accessibility）
//

import Foundation
import Network
import CoreGraphics
import Carbon.HIToolbox
import AppKit

/// 入力イベント受信デリゲート
protocol InputReceiverDelegate: AnyObject {
    func inputReceiver(_ receiver: InputReceiver, didReceiveEvent type: String)
    func inputReceiver(_ receiver: InputReceiver, didFailWithError error: Error)
    func inputReceiver(_ receiver: InputReceiver, didReceiveZoomRequest isZooming: Bool, rect: CGRect, scale: CGFloat)
    func inputReceiver(_ receiver: InputReceiver, didReceiveTelemetry metrics: ClientDeviceMetrics) // ★ Phase 1
    func inputReceiver(_ receiver: InputReceiver, didReceiveRegistration listenPort: UInt16, userRecordID: String?, clientHost: String)  // ★ 登録受信
    func inputReceiver(_ receiver: InputReceiver, didUpdateScrollMetrics velocity: CGPoint, isScrolling: Bool) // ★ Phase 1: Input Physics
}

/// 入力イベント受信・シミュレーションクラス
class InputReceiver {
    
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
    
    weak var delegate: InputReceiverDelegate?
    
    /// リスニングポート（入力イベント受信用）
    let port: UInt16
    
    /// UDP リスナー
    private var listener: NWListener?
    
    /// 受信キュー
    private let receiveQueue = DispatchQueue(label: "com.myremotehost.inputreceiver", qos: .userInteractive)
    
    /// 現在のマウス位置（スムージング用）
    private var currentMousePosition: CGPoint = .zero
    
    /// ★ 停止中フラグ（ポート競合防止）
    private var isStopping = false
    
    /// ★ 開始中フラグ（重複開始防止）
    private var isStarting = false
    
    /// ★ Phase 1: Input Physics state
    private var scrollPhysics = ScrollPhysicsState()
    private let scrollIdleThreshold: TimeInterval = 0.2
    
    /// メインディスプレイのサイズ
    private var displaySize: CGSize {
        guard let mainDisplay = CGMainDisplayID() as CGDirectDisplayID? else {
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(
            width: CGFloat(CGDisplayPixelsWide(mainDisplay)),
            height: CGFloat(CGDisplayPixelsHigh(mainDisplay))
        )
    }
    
    // MARK: - Initialization
    
    init(port: UInt16 = 5002) {
        self.port = port
    }
    
    // MARK: - Public Methods
    
    /// Accessibility権限をリクエスト（システム設定を直接開く）
    func requestAccessibilityPermission() {
        // まずプロンプトを試みる
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if !trusted {
            // プロンプトが表示されない場合は、システム設定を直接開く
            print("[InputReceiver] システム設定のAccessibilityパネルを開きます")
            DispatchQueue.main.async {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        
        print("[InputReceiver] Accessibility権限チェック: \(trusted ? "許可済み" : "未許可 - システム設定で追加してください")")
    }
    
    /// 権限が付与されているか確認
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }
    
    /// リスナーを開始
    func startListening() throws {
        // ★ 重複開始・停止中はスキップ
        guard !isStarting && !isStopping && listener == nil else {
            print("[InputReceiver] ⚠️ 開始スキップ（既に開始中または停止中）")
            return
        }
        
        isStarting = true
        defer { isStarting = false }
        
        // 権限がない場合はシステム設定を開く
        if !hasAccessibilityPermission {
            print("[InputReceiver] ⚠️ Accessibility権限が必要です。システム設定を開きます。")
            requestAccessibilityPermission()
        }
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        
        listener?.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            
            switch newState {
            case .ready:
                print("[InputReceiver] ポート\(self.port)でリスニング開始（入力待機中）")
            case .failed(let error):
                print("[InputReceiver] リスナー失敗: \(error)")
                self.delegate?.inputReceiver(self, didFailWithError: error)
            case .cancelled:
                print("[InputReceiver] リスナーキャンセル")
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            print("[InputReceiver] 🔔 新規接続受信")  // ★ デバッグログ
            self?.handleConnection(connection)
        }
        
        listener?.start(queue: receiveQueue)
    }
    
    /// リスナーを停止
    func stop() {
        // ★ 停止中フラグを立てる
        isStopping = true
        
        listener?.cancel()
        listener = nil
        print("[InputReceiver] 停止")
        
        // ★ ポート解放のため少し待機
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isStopping = false
        }
    }
    
    // MARK: - Private Methods
    
    private func handleConnection(_ connection: NWConnection) {
        print("[InputReceiver] handleConnection開始")  // ★ デバッグログ
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                print("✅ [InputReceiver] 接続Ready - データ受信待機")
                self?.receiveEvents(on: connection)
            case .failed(let error):
                print("[InputReceiver] 接続失敗: \(error)")
            default:
                break
            }
        }
        connection.start(queue: receiveQueue)
    }
    
    private func receiveEvents(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] content, _, _, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[InputReceiver] 受信エラー: \(error)")
                return
            }
            
            if let data = content {
                self.processInputEvent(data, from: connection)  // ★ 接続情報を渡す
            }
            
            // 継続受信
            self.receiveEvents(on: connection)
        }
    }
    
    private func processInputEvent(_ data: Data, from connection: NWConnection? = nil) {
        guard data.count >= 9 else { return }  // 最小: Type(1) + Timestamp(8)
        
        let eventType = data[0]
        // timestamp は data[1...8] だが現在は使用しない
        let payload = data.subdata(in: 9..<data.count)
        
        guard let type = InputEventType(rawValue: eventType) else {
            print("[InputReceiver] 不明なイベントタイプ: \(eventType)")
            return
        }
        
        switch type {
        case .mouseMove:
            handleMouseMove(payload)
        case .mouseDown:
            handleMouseDown(payload)
        case .mouseUp:
            handleMouseUp(payload)
        case .mouseScroll:
            handleMouseScroll(payload)
        case .keyDown:
            handleKeyDown(payload)
        case .keyUp:
            handleKeyUp(payload)
        case .zoomRequest:
            handleZoomRequest(payload)
        case .telemetry:
            handleTelemetry(payload)
        case .registration:
            handleRegistration(payload, from: connection)  // ★ 登録処理
        }
    }
    
    // MARK: - Mouse Event Handlers
    
    private func handleMouseMove(_ payload: Data) {
        guard payload.count >= 8 else { return }
        
        // 正規化座標を取得 (0.0-1.0) — bigEndianからデコード
        let normalizedX = Float(bitPattern: UInt32(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }))
        let normalizedY = Float(bitPattern: UInt32(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }))
        
        // Mac座標に変換
        let x = CGFloat(normalizedX) * displaySize.width
        let y = CGFloat(normalizedY) * displaySize.height
        
        currentMousePosition = CGPoint(x: x, y: y)
        
        // CGEvent でマウス移動
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: currentMousePosition, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    private func handleMouseDown(_ payload: Data) {
        guard payload.count >= 1 else { return }
        
        let buttonRaw = payload[0]
        let button = MouseButton(rawValue: buttonRaw) ?? .left
        
        let eventType: CGEventType
        let cgButton: CGMouseButton
        
        switch button {
        case .left:
            eventType = .leftMouseDown
            cgButton = .left
        case .right:
            eventType = .rightMouseDown
            cgButton = .right
        case .middle:
            eventType = .otherMouseDown
            cgButton = .center
        }
        
        if let event = CGEvent(mouseEventSource: nil, mouseType: eventType,
                               mouseCursorPosition: currentMousePosition, mouseButton: cgButton) {
            event.post(tap: .cghidEventTap)
        }
        
        delegate?.inputReceiver(self, didReceiveEvent: "mouseDown(\(button))")
    }
    
    private func handleMouseUp(_ payload: Data) {
        guard payload.count >= 1 else { return }
        
        let buttonRaw = payload[0]
        let button = MouseButton(rawValue: buttonRaw) ?? .left
        
        let eventType: CGEventType
        let cgButton: CGMouseButton
        
        switch button {
        case .left:
            eventType = .leftMouseUp
            cgButton = .left
        case .right:
            eventType = .rightMouseUp
            cgButton = .right
        case .middle:
            eventType = .otherMouseUp
            cgButton = .center
        }
        
        if let event = CGEvent(mouseEventSource: nil, mouseType: eventType,
                               mouseCursorPosition: currentMousePosition, mouseButton: cgButton) {
            event.post(tap: .cghidEventTap)
        }
        
        delegate?.inputReceiver(self, didReceiveEvent: "mouseUp(\(button))")
    }
    
    private func handleMouseScroll(_ payload: Data) {
        guard payload.count >= 8 else { return }
        
        let deltaX = Float(bitPattern: UInt32(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }))
        let deltaY = Float(bitPattern: UInt32(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }))
        
        // CGEventCreateScrollWheelEventを使用
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2, 
                               wheel1: Int32(deltaY * 10), 
                               wheel2: Int32(deltaX * 10), 
                               wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
        
        // ★ Phase 1: Input Physics Calculation
        let now = Date()
        let dt = now.timeIntervalSince(scrollPhysics.lastUpdateTime)
        
        if dt > 0.001 { // ゼロ除算防止
            // 速度計算 (pixels/sec) - deltaは正規化されている可能性に注意が必要だが、InputSenderではfloatBytes(delta)を送っている
            // InputSenderでのdeltaX/YはUIPanGestureRecognizer.translation由来で、画面サイズ依存のピクセル値に近い
            // ここでは簡易的に「イベント値 / 時間」を指標とする
            let vx = Double(deltaX) / dt
            let vy = Double(deltaY) / dt
            
            scrollPhysics.velocityX = vx
            scrollPhysics.velocityY = vy
            scrollPhysics.isScrolling = true
            scrollPhysics.lastUpdateTime = now
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.inputReceiver(self, didUpdateScrollMetrics: CGPoint(x: vx, y: vy), isScrolling: true)
            }
        }
        
        // スクロール終了判定用の遅延処理（簡易）
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollIdleThreshold) { [weak self] in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.scrollPhysics.lastUpdateTime) >= self.scrollIdleThreshold {
                if self.scrollPhysics.isScrolling {
                    self.scrollPhysics.isScrolling = false
                    self.scrollPhysics.velocityX = 0
                    self.scrollPhysics.velocityY = 0
                    self.delegate?.inputReceiver(self, didUpdateScrollMetrics: .zero, isScrolling: false)
                }
            }
        }
    }
    
    // MARK: - Keyboard Event Handlers
    
    private func handleKeyDown(_ payload: Data) {
        guard payload.count >= 2 else { return }
        
        let keyCode = UInt16(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self) })
        
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) {
            event.post(tap: .cghidEventTap)
        }
        
        delegate?.inputReceiver(self, didReceiveEvent: "keyDown(\(keyCode))")
    }
    
    private func handleKeyUp(_ payload: Data) {
        guard payload.count >= 2 else { return }
        
        let keyCode = UInt16(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self) })
        
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) {
            event.post(tap: .cghidEventTap)
        }
        
        delegate?.inputReceiver(self, didReceiveEvent: "keyUp(\(keyCode))")
    }
    
    // MARK: - Zoom Request Handler
    
    /// ★ ズームリクエストを処理
    private func handleZoomRequest(_ payload: Data) {
        // フォーマット: isZooming(1) + x(4) + y(4) + width(4) + height(4) + scale(4) = 21バイト
        guard payload.count >= 21 else {
            print("[InputReceiver] ⚠️ ズームリクエスト: ペイロード不足 (\(payload.count)バイト)")
            return
        }
        
        let isZooming = payload[0] == 1
        
        // ★ bigEndianからデコード
        var rawX: UInt32 = 0, rawY: UInt32 = 0, rawW: UInt32 = 0, rawH: UInt32 = 0, rawS: UInt32 = 0
        payload.withUnsafeBytes { buffer in
            memcpy(&rawX, buffer.baseAddress!.advanced(by: 1), 4)
            memcpy(&rawY, buffer.baseAddress!.advanced(by: 5), 4)
            memcpy(&rawW, buffer.baseAddress!.advanced(by: 9), 4)
            memcpy(&rawH, buffer.baseAddress!.advanced(by: 13), 4)
            memcpy(&rawS, buffer.baseAddress!.advanced(by: 17), 4)
        }
        let x = Float(bitPattern: UInt32(bigEndian: rawX))
        let y = Float(bitPattern: UInt32(bigEndian: rawY))
        let width = Float(bitPattern: UInt32(bigEndian: rawW))
        let height = Float(bitPattern: UInt32(bigEndian: rawH))
        let scale = Float(bitPattern: UInt32(bigEndian: rawS))
        
        let rect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
        
        // デリゲートに通知
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.inputReceiver(self, didReceiveZoomRequest: isZooming, rect: rect, scale: CGFloat(scale))
        }
    }
    
    // MARK: - Registration Handler
    
    /// ★ 登録パケットを処理
    private func handleRegistration(_ payload: Data, from connection: NWConnection?) {
        // フォーマット: port(2) + userRecordID(可変)
        guard payload.count >= 2 else {
            print("[InputReceiver] ⚠️ 登録パケット: ペイロード不足 (\(payload.count)バイト)")
            return
        }
        
        // リスニングポート（2バイト、bigEndian）
        let listenPort = UInt16(bigEndian: payload.subdata(in: 0..<2).withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
        })
        
        // userRecordID（残り）
        var userRecordID: String? = nil
        if payload.count > 2 {
            userRecordID = String(data: payload.subdata(in: 2..<payload.count), encoding: .utf8)
        }
        
        // 接続元IPを取得
        var clientHost = "unknown"
        if let connection = connection, case .hostPort(let host, _) = connection.endpoint {
            clientHost = "\(host)"
        }
        
        print("[InputReceiver] 🔔 登録受信: port=\(listenPort), host=\(clientHost), userRecordID=\(userRecordID?.prefix(20) ?? "nil")...")
        
        // デリゲートに通知
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.inputReceiver(self, didReceiveRegistration: listenPort, userRecordID: userRecordID, clientHost: clientHost)
        }
    }
    
    // MARK: - Auth Result (UDP経由)
    
    /// ★ 認証結果をUDP経由でクライアントに送信
    /// TCP(port5100)経由の認証通知が届かない場合のバックアップパス
    func sendAuthResult(approved: Bool, toHost host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { newState in
            if case .ready = newState {
                // 認証結果パケット: [0xAA] [結果: 0x01=許可, 0x00=拒否]
                let packet = Data([0xAA, approved ? 0x01 : 0x00])
                connection.send(content: packet, completion: .contentProcessed { error in
                    if let error = error {
                        Logger.network("❌ UDP認証結果送信エラー: \(error)", level: .error)
                    } else {
                        Logger.network("📤 UDP認証結果送信成功 → \(host):\(port) (approved=\(approved))")
                    }
                    // 送信後に接続を閉じる
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        connection.cancel()
                    }
                })
            }
        }
        connection.start(queue: receiveQueue)
    }
    
    // MARK: - Telemetry Handler
    
    private func handleTelemetry(_ payload: Data) {
        // フォーマット: 
        // batteryLevel(4) + isCharging(1) + thermalState(1) + isLowPower(1) + fps(8) = 15 bytes
        guard payload.count >= 15 else { return }
        
        // ★ bigEndianからデコード
        let batteryLevel = Float(bitPattern: UInt32(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }))
        let isCharging = payload[4] == 1
        let thermalState = Int(payload[5])
        let isLowPower = payload[6] == 1
        let fps = Double(bitPattern: UInt64(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 7, as: UInt64.self) }))
        
        let metrics = ClientDeviceMetrics(
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            thermalState: thermalState,
            isLowPowerModeEnabled: isLowPower,
            currentFPS: fps
        )
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.inputReceiver(self, didReceiveTelemetry: metrics)
        }
    }
}
