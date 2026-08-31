# EMPlayer - Emby iOS Player

基于 KSPlayer 内核的纯 Swift Emby 播放器，支持 iOS 15+。

## 特性

- 🔐 Emby 服务器连接与认证（支持用户名密码、API Key）
- 📁 媒体库浏览（电影、剧集、音乐、图片等）
- 🎬 基于 KSPlayer 的强大播放内核
  - 支持硬件解码
  - 支持几乎所有视频格式（H.264, H.265, VP9, AV1 等）
  - 支持外挂字幕（SRT, ASS, VTT）
  - 支持音轨切换
- 🎵 后台音频播放
- 🖼️ 图片浏览
- ⬇️ 离线下载（可选）
- 📱 SwiftUI 原生界面

## 系统要求

- iOS 15.0+
- Xcode 15.0+
- Swift 5.9+

## 快速开始

### 1. 安装 XcodeGen

```bash
brew install xcodegen
```

### 2. 生成 Xcode 项目

```bash
cd emplayer
xcodegen generate
open EMPlayer.xcodeproj
```

### 3. 配置签名

在 Xcode 中选择目标 EMPlayer → Signing & Capabilities → 选择你的开发团队。

### 4. 运行

连接 iOS 设备或使用模拟器，按 ⌘R 运行。

## 项目结构

```
emplayer/
├── Sources/
│   ├── EMPlayer/              # App 入口与 SwiftUI 视图
│   │   ├── App/               # App 入口与配置
│   │   ├── Views/             # SwiftUI 界面
│   │   │   ├── Server/        # 服务器连接页面
│   │   │   ├── Library/       # 媒体库页面
│   │   │   ├── Detail/        # 详情页面
│   │   │   └── Player/        # 播放器页面
│   │   ├── Components/        # 可复用组件
│   │   ├── Info.plist
│   │   └── EMPlayer.entitlements
│   └── EMPlayerCore/          # 核心逻辑（SPM 模块）
│       ├── EmbyAPI/           # Emby API 封装
│       ├── Models/            # 数据模型
│       ├── Services/          # 业务服务
│       ├── Store/             # 状态管理
│       └── Utils/             # 工具类
├── Resources/                 # 资源文件
├── project.yml                # XcodeGen 配置
├── Package.swift              # SPM 配置
└── .github/
    └── workflows/
        └── build.yml          # GitHub Actions 打包
```

## GitHub Actions 自动打包

项目已配置 GitHub Actions，推送到 `main` 分支或打 tag `v*` 时会自动触发构建。

### 前置配置

在 GitHub 仓库 Settings → Secrets and variables → Actions 中添加以下 Secrets：

| Secret 名称 | 说明 |
|------------|------|
| `IOS_CODE_SIGN_IDENTITY` | 代码签名身份，如 `Apple Development: Your Name (TEAMID)` |
| `IOS_PROVISIONING_PROFILE_SPECIFIER` | 描述文件名称 |
| `IOS_DEVELOPMENT_TEAM` | 开发团队 ID（10 位字符）|
| `IOS_EXPORT_METHOD` | 导出方式：`development`、`ad-hoc`、`app-store`、`enterprise` |
| `MATCH_GIT_BASIC_AUTHORIZATION` |（可选）用于签名证书同步 |

### 构建产物

构建完成后可在 Actions 页面下载 IPA 文件。

## Emby 服务器配置

1. 确保 Emby Server 版本 ≥ 4.7.0
2. 在 Emby 管理面板 → 高级 → API 密钥 中创建 API Key（可选，也可用用户名密码登录）
3. 确保服务器防火墙开放 8096（HTTP）和 8920（HTTPS）端口

## 架构说明

### 播放链路

```
用户选择媒体 → EmbyAPI 获取播放信息 → KSPlayer
  → URL (直连/转码流) → KSOptions（解码配置）
  → KSVideoPlayerView（SwiftUI 播放视图）
```

### 网络层

- 纯 `URLSession` + async/await
- `EmbyClient` 单例管理所有 API 调用
- 支持自动重连与请求重试

### 状态管理

- 采用 `ObservableObject` + `@Published`
- `AppState` 管理全局状态（当前服务器、当前用户、播放状态等）

## 依赖说明

| 库 | 用途 |
|----|------|
| [KSPlayer](https://github.com/kingslay/KSPlayer) | 播放内核，基于 FFmpeg + Metal |
| [KeychainSwift](https://github.com/evgenyneu/keychain-swift) | 安全存储用户凭据 |
| [Kingfisher](https://github.com/onevcat/Kingfisher) | 图片下载与缓存 |
| [SwiftyJSON](https://github.com/SwiftyJSON/SwiftyJSON) | JSON 解析 |

## License

MIT
