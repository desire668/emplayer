import UIKit

/// 播放器方向控制：
/// 播放时允许横竖屏切换，并主动转到横屏；
/// 退出播放后其余页面锁定竖屏。
/// （通过 AppDelegate 的 supportedInterfaceOrientationsFor + requestGeometryUpdate 实现）
final class OrientationManager {
    static let shared = OrientationManager()

    /// AppDelegate 读取此状态决定 App 支持的方向
    var isPlayerActive = false

    /// 进入播放器：允许横屏并主动旋转到横屏
    func lockLandscape() {
        isPlayerActive = true
        requestOrientation(.allButUpsideDown, preferred: .landscapeRight)
    }

    /// 退出播放器：锁回竖屏
    func lockPortrait() {
        isPlayerActive = false
        requestOrientation(.portrait, preferred: .portrait)
    }

    private func requestOrientation(_ supported: UIInterfaceOrientationMask, preferred: UIInterfaceOrientationMask) {
        DispatchQueue.main.async {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: preferred)) { error in
                    print("[Orientation] request error: \(error.localizedDescription)")
                }
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

/// SwiftUI App 生命周期下接入方向控制
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.shared.isPlayerActive ? .allButUpsideDown : .portrait
    }
}
