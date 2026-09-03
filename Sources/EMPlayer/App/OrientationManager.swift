import UIKit
import Combine

/// 播放器方向控制（iOS 16+ 原生方案）：
///
/// - 通过 AppDelegate 的 `application(_:supportedInterfaceOrientationsFor:)`
///   决定 App 当前允许的方向：播放页内放开横竖屏，其余页面锁定竖屏；
/// - 通过 `UIWindowScene.requestGeometryUpdate(.iOS(interfaceOrientations:))`
///   主动请求旋转，并调用 `setNeedsUpdateOfSupportedInterfaceOrientations()`
///   让系统重新评估支持的方向。
///
/// 注意：
/// - 不使用已废弃的 `UIDevice.setValue(_:forKey:"orientation")` 强制旋转；
/// - 按钮图标/布局不依赖「上一次点击结果」，而以 GeometryReader 反馈的
///   真实窗口方向为准（见 PlayerHostView）。
final class OrientationManager: ObservableObject {
    static let shared = OrientationManager()

    /// AppDelegate 读取：播放页内允许自由旋转，其余页面锁竖屏
    private(set) var isPlayerActive = false

    /// 进入播放器：放开方向限制并主动转到横屏（全屏）
    func enterPlayer() {
        isPlayerActive = true
        request(preferred: .landscape)
    }

    /// 退出播放器：锁回竖屏
    func exitPlayer() {
        isPlayerActive = false
        request(preferred: .portrait)
    }

    /// 播放页内：请求横屏（= 进入全屏）
    func requestLandscape() {
        isPlayerActive = true
        request(preferred: .landscape)
    }

    /// 播放页内：请求竖屏（= 退出全屏，窗口化半屏）
    func requestPortrait() {
        isPlayerActive = true
        request(preferred: .portrait)
    }

    private func request(preferred mask: UIInterfaceOrientationMask) {
        DispatchQueue.main.async {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                // iOS 16+ 原生几何更新 API；错误回调仅记录，不中断流程
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    print("[Orientation] requestGeometryUpdate error: \(error.localizedDescription)")
                }
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

/// SwiftUI App 生命周期下的方向控制桥接
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // 播放页：竖屏 + 左右横屏（不支持倒立）；其余页面：仅竖屏
        OrientationManager.shared.isPlayerActive ? .allButUpsideDown : .portrait
    }
}
