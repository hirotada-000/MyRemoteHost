//
//  OmniscientHUD.swift
//  MyRemoteClient
//
//  Omniscient Quality Controllerの状態を可視化するHUD
//  SFっぽいデザインで、現在の状況と意思決定の理由を表示する
//

import SwiftUI

struct OmniscientHUD: View {
    let state: OmniscientState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Status & Decision
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OMNISCIENT ENGINE")
                        .font(.caption2)
                        .fontWeight(.black)
                        .foregroundColor(modeColor(for: state.engineMode))
                    
                    Text(state.engineMode.uppercased())
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(modeColor(for: state.engineMode).opacity(0.8))
                        .cornerRadius(4)
                }
                
                Spacer()
                
                // Decision Reason
                if !state.decisionReason.isEmpty {
                    Text(state.decisionReason)
                        .font(.caption)
                        .foregroundColor(.yellow)
                        .padding(6)
                        .background(Color.yellow.opacity(0.1))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Metrics Grid
            HStack(spacing: 20) {
                // Network
                MetricColumn(title: "NETWORK", color: .green) {
                    MetricRow(label: "BW", value: String(format: "%.1f M", state.bandwidthMbps))
                    MetricRow(label: "RTT", value: String(format: "%.0f ms", state.rtt * 1000))
                    MetricRow(label: "Loss", value: String(format: "%.1f %%", state.packetLoss * 100))
                }
                
                // Host
                MetricColumn(title: "HOST", color: .blue) {
                    MetricRow(label: "CPU", value: String(format: "%.0f %%", state.hostCPU * 100))
                    MetricRow(label: "Mem", value: String(format: "%.0f %%", state.hostMemory * 100))
                    MetricRow(label: "Thm", value: state.hostThermalState == 0 ? "OK" : "High")
                }
                
                // Client
                MetricColumn(title: "CLIENT", color: .orange) {
                    MetricRow(label: "FPS", value: String(format: "%.0f", state.clientFPS))
                    MetricRow(label: "Bat", value: String(format: "%.0f %%", state.clientBattery * 100))
                    MetricRow(label: "Thm", value: state.clientThermalState == 0 ? "OK" : "High")
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Target Controls — Row 1: Core
            HStack(spacing: 4) {
                ConfigPill(label: "Bitrate", value: "\(Int(state.targetBitrateMbps))M", color: .purple)
                ConfigPill(label: "FPS", value: "\(Int(state.targetFPS))", color: .pink)
                ConfigPill(label: "Scale", value: String(format: "%.1fx", state.captureScale), color: .mint)
                ConfigPill(label: "Qual", value: String(format: "%.0f%%", state.encoderQuality * 100), color: .gray)
            }
            
            // Target Controls — Row 2: Extended
            HStack(spacing: 4) {
                ConfigPill(label: "", value: state.codecName, color: .cyan)
                ConfigPill(label: "", value: state.profileName, color: .indigo)
                ConfigPill(label: "KF", value: "\(state.keyFrameInterval)", color: .teal)
                ConfigPill(label: "Res", value: String(format: "%.0f%%", state.resolutionScale * 100), color: .brown)
                ConfigPill(label: state.lowLatencyMode ? "LL" : "HQ", value: state.lowLatencyMode ? "ON" : "OFF", color: state.lowLatencyMode ? .green : .orange)
                ConfigPill(label: "Peak", value: String(format: "%.1f", state.peakMultiplier), color: .gray)
            }
            
            // MARK: - Pipeline Latency (Phase 1: 遅延計測基盤)
            if state.endToEndMs > 0 {
                Divider()
                    .background(Color.white.opacity(0.2))
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("PIPELINE LATENCY")
                            .font(.caption2)
                            .fontWeight(.black)
                            .foregroundColor(.cyan)
                        
                        Spacer()
                        
                        Text(String(format: "E2E: %.1fms", state.endToEndMs))
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(e2eColor(state.endToEndMs))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(e2eColor(state.endToEndMs).opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    // パイプライン棒グラフ
                    GeometryReader { geo in
                        let total = max(state.endToEndMs, 1)
                        let segments: [(String, Double, Color)] = [
                            ("Cap", state.captureToEncodeMs, .green),
                            ("Enc", state.encodeDurationMs, .blue),
                            ("Pkt", state.packetizeMs, .purple),
                            ("Net", state.networkTransitMs, .orange),
                            ("Dec", state.receiveToDecodeMs, .pink),
                            ("Rnd", state.renderMs, .cyan),
                        ]
                        
                        HStack(spacing: 1) {
                            ForEach(segments.indices, id: \.self) { i in
                                let (_, ms, color) = segments[i]
                                let fraction = ms / total
                                Rectangle()
                                    .fill(color.opacity(0.8))
                                    .frame(width: max(geo.size.width * CGFloat(fraction), 2))
                            }
                        }
                    }
                    .frame(height: 8)
                    .cornerRadius(4)
                    
                    // 各段の数値ラベル
                    HStack(spacing: 4) {
                        PipelineStagePill(label: "Cap", ms: state.captureToEncodeMs, color: .green)
                        PipelineStagePill(label: "Enc", ms: state.encodeDurationMs, color: .blue)
                        PipelineStagePill(label: "Pkt", ms: state.packetizeMs, color: .purple)
                        PipelineStagePill(label: "Net", ms: state.networkTransitMs, color: .orange)
                        PipelineStagePill(label: "Dec", ms: state.receiveToDecodeMs, color: .pink)
                        PipelineStagePill(label: "Rnd", ms: state.renderMs, color: .cyan)
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        .frame(maxWidth: 380)
    }
    
    private func modeColor(for mode: String) -> Color {
        switch mode {
        case "Balanced": return .cyan
        case "Performance": return .purple
        case "Quality": return .orange
        case "Eco": return .green
        case "Limited": return .red
        default: return .gray
        }
    }
    
    /// E2E遅延に応じた色（良好→警告→危険）
    private func e2eColor(_ ms: Double) -> Color {
        if ms < 30 { return .green }
        if ms < 80 { return .yellow }
        return .red
    }
}

struct MetricColumn<Content: View>: View {
    let title: String
    let color: Color
    let content: Content
    
    init(title: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.color = color
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(color)
            
            VStack(alignment: .leading, spacing: 2) {
                content
            }
        }
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 25, alignment: .leading)
            
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .monospacedDigit()
        }
    }
}

struct ConfigPill: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(color)
            
            Text(value)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

/// パイプライン各段の遅延ラベル
struct PipelineStagePill: View {
    let label: String
    let ms: Double
    let color: Color
    
    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(color)
            Text(String(format: "%.1f", ms))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(minWidth: 28)
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}

#Preview {
    ZStack {
        Color.black
        OmniscientHUD(state: OmniscientState())
    }
}
