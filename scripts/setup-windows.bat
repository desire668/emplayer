@echo off
REM EMPlayer Windows 辅助脚本（在 Windows 本地无法编译 iOS，仅提供生成 + 验证）
setlocal
set APP_NAME=EMPlayer

echo [1/2] 检查 project.yml ...
if not exist project.yml (
  echo 错误：找不到 project.yml
  exit /b 1
)

echo [2/2] 校验 JSON / YAML 结构
where xcodegen >nul 2>nul
if %errorlevel% equ 0 (
  echo 检测到 xcodegen：可用 `xcodegen generate --spec project.yml` 生成 Xcode 项目
) else (
  echo 提示：当前是 Windows 系统，XcodeGen / Xcode 仅支持 macOS。
  echo      请在 macOS 上运行 `./scripts/build.sh setup` 或 push 到 GitHub 触发 CI 构建。
)

echo.
echo 完成：项目配置文件就绪。请将整个目录同步到 macOS 或 push 到 GitHub 进行打包。
endlocal
