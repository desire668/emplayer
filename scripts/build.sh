#!/usr/bin/env bash
#
# EMPlayer 构建脚本
# 用法：
#   ./scripts/build.sh setup        # 安装 xcodegen + 生成项目
#   ./scripts/build.sh sim          # 构建模拟器版本
#   ./scripts/build.sh device       # 构建 iOS 设备版本（需要签名）
#   ./scripts/build.sh clean        # 清理
#
set -euo pipefail

APP_NAME="EMPlayer"
PROJECT_FILE="${APP_NAME}.xcodeproj"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

info() { echo "👉 $*"; }
ok()   { echo "✅ $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

command -v xcodebuild >/dev/null || fail "请安装 Xcode 并在命令行中可用"

cmd_setup() {
  info "安装 / 更新 XcodeGen"
  if ! command -v xcodegen >/dev/null; then
    if command -v brew >/dev/null; then
      brew install xcodegen
    else
      echo "请先安装 Homebrew: https://brew.sh"
      exit 1
    fi
  fi
  xcodegen --version

  info "生成 Xcode 项目：project.yml -> ${PROJECT_FILE}"
  xcodegen generate --spec project.yml
  ok "Xcode 项目生成完成：${PROJECT_FILE}"
}

cmd_sim() {
  [ -d "${PROJECT_FILE}" ] || cmd_setup
  info "构建 iOS 模拟器（Debug）"
  xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${APP_NAME}" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    -derivedDataPath DerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build
  ok "构建成功，输出位于：DerivedData/Build/Products/Debug-iphonesimulator/"
}

cmd_device() {
  [ -d "${PROJECT_FILE}" ] || cmd_setup
  info "构建 iOS 设备（Release，无签名）"
  mkdir -p Build
  xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "Build/${APP_NAME}.xcarchive" \
    -derivedDataPath DerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    archive
  ok "归档成功：Build/${APP_NAME}.xcarchive"
  info "提示：如需 IPA，请使用签名的 xcconfig 后运行 xcodebuild -exportArchive"
}

cmd_clean() {
  info "清理构建产物"
  rm -rf "${PROJECT_FILE}" DerivedData Build
  rm -f Package.resolved
  ok "已清理"
}

usage() {
  echo "用法: $0 {setup|sim|device|clean}" >&2
  exit 1
}

case "${1:-}" in
  setup)  cmd_setup ;;
  sim)    cmd_sim ;;
  device) cmd_device ;;
  clean)  cmd_clean ;;
  *)      usage ;;
esac
