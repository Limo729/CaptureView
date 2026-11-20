import SwiftUI
import UIKit

// MARK: - 屏幕方向锁定

enum OrientationLock: String, CaseIterable, Identifiable {
    case landscape
    case portrait
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape: return "锁定横屏"
        case .portrait: return "锁定竖屏"
        case .auto: return "跟随重力"
        }
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .landscape: return .landscape
        case .portrait: return .portrait
        case .auto: return .all
        }
    }

    static var stored: OrientationLock {
        let raw = UserDefaults.standard.string(forKey: "orientationLock") ?? ""
        return OrientationLock(rawValue: raw) ?? .landscape
    }
}

/// 切换方向：先改持久化，再请求界面几何更新，最后让根控制器重算支持的方向
func applyOrientationLock(_ lock: OrientationLock) {
    UserDefaults.standard.set(lock.rawValue, forKey: "orientationLock")
    guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: lock.mask))
    scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
}

// MARK: - 应用入口

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.stored.mask
    }
}

@main
struct CaptureViewApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
