import AVFoundation
import SwiftUI

// MARK: - 显示方式

enum DisplayMode: String, CaseIterable, Identifiable {
    case aspect = "等比"
    case stretch = "拉伸铺满"
    case crop = "裁切铺满"

    var id: String { rawValue }

    var gravity: AVLayerVideoGravity {
        switch self {
        case .aspect: return .resizeAspect
        case .stretch: return .resize      // 非等比拉伸，正好把 2388×1668 填满
        case .crop: return .resizeAspectFill
        }
    }
}

// MARK: - 一个采集格式

struct FormatDescriptor: Identifiable, Hashable {
    let id: Int          // device.formats 的下标
    let width: Int
    let height: Int
    let codec: String
    let minFPS: Double
    let maxFPS: Double

    var title: String { "\(width)×\(height)" }
    var subtitle: String { "\(codec) · \(Int(minFPS))–\(Int(maxFPS))fps" }
    var pixels: Int { width * height }
}

// MARK: - 画面视口（缩放/平移/重置）

final class Viewport: ObservableObject {
    @Published var zoom: CGFloat = 1
    @Published var pan: CGSize = .zero
    @Published var resetToken: Int = 0

    func reset() {
        zoom = 1
        pan = .zero
        resetToken &+= 1
    }
}
