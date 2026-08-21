# DevSweep

DevSweep 是一个原生 SwiftUI macOS 开发者缓存清理工具，面向 Xcode、Rust/Tauri、Node、SwiftPM、Cargo、Gradle、Maven、Python、Go、Flutter、VS Code、Cursor 等开发环境。

当前版本：0.1.11

## 当前功能

- 按 Xcode、CoreSimulator、XCTest、Docker、项目生成物、包管理器、语言工具链、AI/ML、JVM、IDE 分类展示占用，并按空间从大到小排列。
- 扫描常见开发者缓存白名单，不扫描照片、文档、邮件或整个磁盘；目录占用使用 macOS `du` 校准，避免只读到目录元数据而漏报大缓存。
- 默认发现 `~/Code`、`~/Projects`、`~/Developer`、`~/Work`、`~/src` 和 `~/workspace`，也支持添加多个项目根目录并持久化保存。
- 深度扫描项目目录，查找 `target`、`node_modules`、`.build`、`Pods`、`build`、`dist`、`.next`、`.turbo`、`.dart_tool`、Python 缓存、测试产物等生成物。
- 识别 Xcode `ModuleCache`、`SourcePackages`、Preview、源码控制缓存，以及按 UUID 拆分的 XCTest 克隆设备和 CoreSimulator 设备。
- 读取 npm、Cargo、Go、pip、uv、Poetry、Gradle 等自定义环境变量和 npm 配置，尽量覆盖不在默认路径的缓存。
- 覆盖 Docker 官方 CLI 可回收的未使用镜像、已停止容器、未使用卷和 Build Cache，并显示 Docker Desktop 虚拟磁盘占用；虚拟磁盘只读，Docker CLI 清理需单独确认且不能从废纸篓恢复。
- 覆盖 Deno、Corepack、Playwright、Puppeteer、rustup、Conda、Bazel、Android SDK、NuGet、mise、asdf、ccache/sccache、Hugging Face、PyTorch、Whisper、Keras、TensorFlow Hub、Ollama、LM Studio 及 JetBrains/Android Studio 日志等常见开发工具数据；同时识别各工具的自定义缓存环境变量。
- 识别 CoreSimulator 设备，通过 `xcrun simctl delete` 删除，避免直接破坏设备注册。
- 对 Xcode Archives、iOS DeviceSupport、SourcePackages、XCTest 克隆设备、项目生成物标记为“建议确认”或“手动处理”。
- 扫描过程中显示当前路径、已检查数量、跳过数量和权限异常；扫描完成后可查看实际扫描范围和诊断详情。
- 默认只勾选低风险缓存；清理前二次确认。
- 普通目录优先移入 macOS 废纸篓，便于恢复。
- 支持从 GitHub Releases 检查在线更新；只接受带 SHA-256 digest、Developer ID 签名并通过 Gatekeeper 校验的安装包，由独立更新程序原子替换、重启和失败回滚。

## 构建

要求 macOS 13+、Swift 5.9+：

```bash
DEVSWEEP_ALLOW_ADHOC=1 ./scripts/build_app.sh
open ./DevSweep.app
```

上面是仅供本地调试的 ad-hoc 构建，默认按当前机器架构构建；需要 Universal 调试包时使用：

```bash
DEVSWEEP_ALLOW_ADHOC=1 DEVSWEEP_ARCHS="arm64 x86_64" ./scripts/build_app.sh
```

正式发布需要 Developer ID 签名和 Apple 公证。请在发布电脑上配置 Developer ID 证书及其私钥，并使用已验证的 `DEVSWEEP_NOTARY_PROFILE`：

```bash
export DEVSWEEP_DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'
export DEVSWEEP_DEVELOPER_TEAM_ID='TEAMID'
export DEVSWEEP_NOTARY_PROFILE='your-notary-profile'
DEVSWEEP_ARCHS='arm64 x86_64' ./scripts/distribute_app.sh
```

`scripts/build_app.sh` 默认拒绝没有 Developer ID 的构建，避免误把 ad-hoc 包上传到 Release。只有本地开发时才显式使用 `DEVSWEEP_ALLOW_ADHOC=1`；这个包不能发布或用于在线更新。发布前必须确认 `codesign` 显示 `Developer ID Application`、`spctl` 通过且 `xcrun stapler validate` 成功。在线更新要求 Release 资产使用 `DevSweep-<version>-macos.zip` 文件名，并保留 GitHub 自动生成的 SHA-256 digest。包含在线更新功能的首个版本之前，旧安装需要手动安装一次。

正式 Release 使用 `.github/workflows/release.yml` 在 GitHub Actions 上完成，不依赖发布电脑的钥匙串。该 workflow 复用现有项目的仓库 Secrets：`APPLE_CERTIFICATE_P12`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_ID`、`APPLE_APP_SPECIFIC_PASSWORD`、`APPLE_DEVELOPER_ID` 和 `APPLE_TEAM_ID`。推送符合版本格式的 tag 后，Actions 会自动测试、签名、公证、装订票据、校验并创建 Release。

也可以直接在 Xcode 中打开 `Package.swift`。

## 设计依据

本项目的路径白名单和交互策略参考了公开项目：

- [k-angama/macOS-dev-cache-cleaner](https://github.com/k-angama/macOS-dev-cache-cleaner)：SwiftUI 分类扫描、白名单路径、工作区生成物和安全访问思路。
- [MacPaw/cleanmymac-cli](https://github.com/MacPaw/cleanmymac-cli)：分析/预览/交互确认、按年龄和风险处理项目生成物的思路。
- [jemishavasoya/dev-cleaner](https://github.com/jemishavasoya/dev-cleaner)：开发工具缓存覆盖范围。
- [riponcm/Jharu](https://github.com/riponcm/Jharu)：Docker、AI/ML 模型、Playwright/Puppeteer、Conda 等开发者数据覆盖，以及按安全等级解释清理后果。
- [georgekhananaev/spark-clean](https://github.com/georgekhananaev/spark-clean)：Docker/Ollama 使用官方 CLI、命令型清理不可恢复的安全提示和 review-first 流程。

代码仅借鉴公开项目描述和使用策略，没有复制其源代码。

## 安全边界

DevSweep 不会直接删除 Docker 虚拟磁盘、用户源码、Git 仓库、照片或文档。Docker 镜像、容器、卷和 Build Cache 通过官方 CLI 清理，不能移入废纸篓，必须由用户逐项确认；只允许当前 Docker CLI 指向本机 Unix socket 或 localhost，拒绝远程 context；Docker.raw 只展示占用。删除项目生成物和模拟器设备会让下次构建/运行重新生成数据，可能需要重新下载依赖。运行测试、模拟器或 Docker 构建时，请先停止相关进程再处理对应资源。
