import SwiftUI

struct ControlSheet: View {
    @ObservedObject var capture: CaptureController
    @ObservedObject var viewport: Viewport

    @Binding var mode: DisplayMode
    @Binding var rotation: Double
    @Binding var showGuides: Bool
    @Binding var tab: Int

    @AppStorage("orientationLock") private var orientationLockRaw = OrientationLock.landscape.rawValue
    @AppStorage("allowGestures") private var allowGestures = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("输入").tag(0)
                    Text("画面").tag(1)
                    Text("性能").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                content
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case 0:
            inputTab
        case 1:
            displayTab
        default:
            perfTab
        }
    }

    // MARK: - 输入

    private var inputTab: some View {
        List {
            Section("设备") {
                LabeledContent("当前设备", value: capture.deviceName)
                LabeledContent("支持的格式", value: "\(capture.formats.count) 种")
            }

            Section("格式") {
                if capture.formats.isEmpty {
                    Text("没有检测到采集卡。拔插一次，或换成带供电的 USB-C 扩展坞。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(capture.formats) { f in
                        Button {
                            capture.select(formatID: f.id, fps: nil)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.title)
                                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                                    Text(f.subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if capture.selectedFormatID == f.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if capture.maxFPS > 1 {
                Section("帧率 · 该格式上限 \(Int(capture.maxFPS)) fps") {
                    HStack(spacing: 12) {
                        Text("\(Int(capture.selectedFPS)) fps")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .frame(width: 76, alignment: .leading)
                        Slider(value: fpsBinding, in: 1...max(capture.maxFPS, 2), step: 1)
                    }
                    quickFPSGrid
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var fpsBinding: Binding<Double> {
        Binding(get: { capture.selectedFPS }, set: { capture.setFPS($0) })
    }

    private var quickFPS: [Double] {
        let base: [Double] = [24, 25, 30, 48, 50, 60, 72, 90, 100, 120, 144, 165]
        var list = base.filter { $0 <= capture.maxFPS + 0.5 }
        if !list.contains(where: { abs($0 - capture.maxFPS) < 0.5 }) {
            list.append(capture.maxFPS)
        }
        return list
    }

    private var quickFPSGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                  spacing: 6) {
            ForEach(quickFPS, id: \.self) { value in
                Button {
                    capture.setFPS(value)
                } label: {
                    Text("\(Int(value))")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(abs(capture.selectedFPS - value) < 0.5 ? Color.accentColor : Color.gray)
            }
        }
    }

    // MARK: - 画面

    private var displayTab: some View {
        List {
            Section("屏幕方向") {
                Picker("屏幕方向", selection: $orientationLockRaw) {
                    ForEach(OrientationLock.allCases) { o in
                        Text(o.title).tag(o.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: orientationLockRaw) { _, newValue in
                    applyOrientationLock(OrientationLock(rawValue: newValue) ?? .landscape)
                }
                Toggle("允许双指缩放与平移", isOn: $allowGestures)
            } footer: {
                Text("默认锁定横屏。关掉手势开关后，双指缩放和平移都不响应，画面不会被误触带动。")
            }

            Section("显示方式") {
                Picker("显示方式", selection: $mode) {
                    ForEach(DisplayMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("旋转") {
                Picker("旋转", selection: $rotation) {
                    Text("0°").tag(0.0)
                    Text("90°").tag(90.0)
                    Text("180°").tag(180.0)
                    Text("270°").tag(270.0)
                }
                .pickerStyle(.segmented)
            }

            Section("辅助") {
                Toggle("中心与三分对齐线", isOn: $showGuides)
                Button("重置缩放与平移") {
                    viewport.reset()
                }
            }

            Section {
                Button("按屏幕原分辨率铺满（横屏 2388 × 1668）") {
                    mode = .stretch
                    rotation = 0
                    viewport.reset()
                }
            } footer: {
                Text("iPad Pro 11 的物理分辨率就是 2388×1668。选“拉伸铺满”，画面被非等比拉到屏幕比例，四边无黑边，代价是轻微几何变形。")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 性能

    private var perfTab: some View {
        List {
            Section("当前状态") {
                LabeledContent("采集格式", value: capture.currentText)
                LabeledContent("设备", value: capture.deviceName)
                LabeledContent("屏幕刷新", value: "\(capture.displayHz) Hz")
                LabeledContent("格式上限", value: "\(Int(capture.maxFPS)) fps")
                LabeledContent("设定帧率", value: "\(Int(capture.selectedFPS)) fps")
            }

            Section {
                Text("“屏幕刷新”显示 60Hz，说明 ProMotion 没被 App 拿到，跟采集卡无关；显示 120Hz 才说明高刷生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("如果采集格式写着 120fps、屏幕却只有 60Hz，那就是渲染链路的问题，而不是卡的问题。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }
}
