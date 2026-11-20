import SwiftUI
import UIKit

struct ContentView: View {

    @StateObject private var capture = CaptureController()
    @StateObject private var viewport = Viewport()
    @StateObject private var pencil = PencilClient()
    @StateObject private var mapper = PenMapper()

    // 设置存 UserDefaults，下次开 App 保持上次状态
    @AppStorage("displayMode") private var modeRaw = DisplayMode.stretch.rawValue
    @AppStorage("displayRotation") private var rotation: Double = 270
    @AppStorage("mirrorH") private var mirrorH = false
    @AppStorage("mirrorV") private var mirrorV = false
    @AppStorage("pencilMode") private var pencilMode = false
    @State private var showGuides = false
    @State private var showTools = true
    @State private var showPanel = false
    @State private var sheetTab = 0
    @State private var hideWork: DispatchWorkItem?

    @AppStorage("allowGestures") private var allowGestures = true
    @AppStorage("orientationLock") private var orientationLockRaw = OrientationLock.landscape.rawValue

    @Environment(\.scenePhase) private var scenePhase

    private var mode: DisplayMode {
        DisplayMode(rawValue: modeRaw) ?? .stretch
    }

    private var modeBinding: Binding<DisplayMode> {
        Binding(get: { mode }, set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                PreviewCanvas(session: capture.session,
                              mode: mode,
                              rotation: rotation,
                              mirrorH: mirrorH,
                              mirrorV: mirrorV,
                              allowGestures: allowGestures,
                              videoSize: capture.videoSize,
                              mapper: mapper,
                              viewport: viewport)
                    .ignoresSafeArea()

                if showGuides {
                    GuideOverlay()
                        .allowsHitTesting(false)
                }

                if pencilMode {
                    PencilSurface(client: pencil, mapper: mapper)
                        .ignoresSafeArea()
                }

                chrome
            }
            .overlay(alignment: .bottomLeading) {
                toggleButton
            }
            // 从屏幕最左边往右划超过 3/4 宽度，唤出按键
            // 笔模式下一律关掉，否则画到边缘会被这个手势判成取消，整笔断掉
            .gesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        guard value.startLocation.x < 80 else { return }
                        guard value.translation.width > geo.size.width * 0.75 else { return }
                        revealTools()
                    },
                including: pencilMode ? .none : .all
            )
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showPanel) {
            ControlSheet(capture: capture,
                         pencil: pencil,
                         viewport: viewport,
                         mode: modeBinding,
                         rotation: $rotation,
                         showGuides: $showGuides,
                         tab: $sheetTab)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            let lock = OrientationLock(rawValue: orientationLockRaw) ?? .landscape
            applyOrientationLock(lock)
            capture.start()
            if pencilMode { pencil.connect() }
            scheduleHide()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            pencil.disconnect()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
                capture.start()
                if pencilMode { pencil.connect() }
            }
        }
        .onChange(of: showPanel) { _, presented in
            if presented { hideWork?.cancel() } else { scheduleHide() }
        }
    }

    // MARK: - 按键自动隐藏（3 秒无操作）

    private func revealTools() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showTools = true
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            guard !showPanel else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showTools = false
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - 左下角圆形开关

    private var toggleButton: some View {
        Button {
            if showTools {
                hideWork?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) { showTools = false }
            } else {
                revealTools()
            }
        } label: {
            Image(systemName: showTools ? "chevron.down" : "square.grid.2x2")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
        .padding(.bottom, 22)
    }

    // MARK: - 顶部状态条与底部工具条

    private var chrome: some View {
        VStack(spacing: 0) {
            if showTools {
                HStack {
                    statusCapsule
                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)

            if showTools {
                HStack(spacing: 8) {
                    toolButton("slider.horizontal.3", "输入") {
                        sheetTab = 0
                        showPanel = true
                    }
                    toolButton("rectangle.on.rectangle", "画面") {
                        sheetTab = 1
                        showPanel = true
                    }
                    toolButton("pencil.tip", "笔", active: pencilMode) {
                        pencilMode.toggle()
                        if pencilMode {
                            pencil.connect()
                        } else {
                            pencil.disconnect()
                        }
                    }
                    toolButton("arrow.left.arrow.right", "左右镜像", active: mirrorH) {
                        mirrorH.toggle()
                    }
                    toolButton("arrow.up.arrow.down", "上下镜像", active: mirrorV) {
                        mirrorV.toggle()
                    }
                    toolButton("speedometer", "性能") {
                        sheetTab = 2
                        showPanel = true
                    }
                    toolButton("arrow.counterclockwise", "复位") {
                        mirrorH = false
                        mirrorV = false
                        viewport.reset()
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var statusCapsule: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(capture.formats.isEmpty ? Color.orange : Color.green)
                .frame(width: 7, height: 7)

            Text(capture.currentText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)

            Text("实际 \(Int(capture.measuredFPS.rounded()))fps")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))

            Text("屏 \(capture.displayHz)Hz")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))

            if pencilMode {
                Text(pencil.connected ? "笔 \(Int(pencil.lastPressure * 100))%" : "笔 未连")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(pencil.connected ? Color.green.opacity(0.9) : Color.orange.opacity(0.9))

                if pencil.connected {
                    Text("\(Int(pencil.sampleRate.rounded())) 点/秒")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func toolButton(_ icon: String, _ title: String,
                            active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button {
            // 每次点按键都重新计时，3 秒没新操作再收起
            scheduleHide()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(active ? Color.orange : Color.white)
            .frame(width: 66, height: 52)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(active ? Color.orange.opacity(0.85) : Color.white.opacity(0.08),
                            lineWidth: active ? 1.2 : 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 对齐辅助线

struct GuideOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Path { path in
                path.move(to: CGPoint(x: w / 2, y: 0))
                path.addLine(to: CGPoint(x: w / 2, y: h))
                path.move(to: CGPoint(x: 0, y: h / 2))
                path.addLine(to: CGPoint(x: w, y: h / 2))

                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }

                path.addRect(CGRect(x: 24, y: 24, width: w - 48, height: h - 48))
            }
            .stroke(Color.white.opacity(0.32),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
        .ignoresSafeArea()
    }
}
