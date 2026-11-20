import SwiftUI
import UIKit

struct ContentView: View {

    @StateObject private var capture = CaptureController()
    @StateObject private var viewport = Viewport()

    @State private var mode: DisplayMode = .stretch
    @State private var rotation: Double = 0
    @State private var showGuides = false
    @State private var showChrome = true
    @State private var showPanel = false
    @State private var sheetTab = 0

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PreviewCanvas(session: capture.session,
                          mode: mode,
                          rotation: rotation,
                          viewport: viewport)
                .ignoresSafeArea()

            if showGuides {
                GuideOverlay()
                    .allowsHitTesting(false)
            }

            chrome
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                showChrome.toggle()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showPanel) {
            ControlSheet(capture: capture,
                         viewport: viewport,
                         mode: $mode,
                         rotation: $rotation,
                         showGuides: $showGuides,
                         tab: $sheetTab)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            capture.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
                capture.start()
            }
        }
    }

    // MARK: - 界面元素

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack {
                statusCapsule
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                toolButton("slider.horizontal.3", "输入") {
                    sheetTab = 0
                    showPanel = true
                }
                toolButton("rectangle.on.rectangle", "画面") {
                    sheetTab = 1
                    showPanel = true
                }
                toolButton("speedometer", "性能") {
                    sheetTab = 2
                    showPanel = true
                }
                toolButton("arrow.counterclockwise", "复位") {
                    viewport.reset()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .opacity(showChrome ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: showChrome)
    }

    private var statusCapsule: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(capture.formats.isEmpty ? Color.orange : Color.green)
                .frame(width: 7, height: 7)

            Text(capture.currentText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)

            Text("屏幕 \(capture.displayHz)Hz")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func toolButton(_ icon: String, _ title: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: 62, height: 52)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
