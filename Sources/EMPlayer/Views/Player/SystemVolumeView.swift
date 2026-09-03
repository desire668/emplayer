import SwiftUI
import MediaPlayer

/// 系统音量滑块（MPVolumeView 桥接）
///
/// MPVolumeView 是 Apple 公开 API 中唯一能调整「系统音量」的控件：
/// - 拖动滑块等同于按机身音量键，会走系统音频路由（扬声器/蓝牙/AirPlay）；
/// - 自动响应机身音量键与控制中心的变化；
/// - 不使用任何私有 API。
struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false          // 不显示 AirPlay 路由按钮（播放器已有自己的路由）
        view.showsVolumeSlider = true
        view.tintColor = .white
        view.setVolumeSliderStyling()
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.setVolumeSliderStyling()
    }
}

private extension MPVolumeView {
    /// 统一滑块配色（白色滑块 + indigo 已播放轨道）
    func setVolumeSliderStyling() {
        subviews.compactMap { $0 as? UISlider }.forEach { slider in
            slider.minimumTrackTintColor = UIColor.systemIndigo
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
            slider.thumbTintColor = UIColor.white
            slider.minimumValueImage = UIImage(systemName: "speaker.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
            slider.maximumValueImage = UIImage(systemName: "speaker.wave.3.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        }
    }
}
