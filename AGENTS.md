# DevSweep 项目规则

## iOS Simulator 测试规则

- 日常开发验证默认只能使用一个 iOS Simulator；所有 iOS 测试优先通过统一脚本 `deploy/ios-project-template/scripts/test-ios.sh`（复制到具体 iOS 项目后为 `./scripts/test-ios.sh`）执行。
- 禁止 Agent 自行创建新的 Simulator、使用 `simctl create`、同时指定多个 `-destination`、默认开启 XCTest parallel testing、使用 `-parallel-testing-enabled YES`、自动增加 parallel worker，或为了提高测试速度创建 simulator clone、修改测试脚本提高 worker 数量。
- 默认必须 `-parallel-testing-enabled NO` 且 `-maximum-parallel-testing-workers 1`；现有 Simulator 不可用时先 `xcrun simctl list devices available` 复用已有设备，不能新建。
- 只有用户明确要求并行测试时才允许临时最多使用 2 个 worker，结束后必须恢复默认单 Simulator 配置；日常开发、修 bug、功能验证都使用 1 个。
- 禁止创建 `~/bin/xcodebuild`、`/usr/local/bin/xcodebuild` 之类的全局 wrapper 或改 PATH 劫持系统 xcodebuild；限制只放在项目 Scheme、项目测试脚本和 Agent 规则三个层次。
- `~/Library/Developer/XCTestDevices/<UUID>` 是测试临时 clone，可由 DevSweep 清理；`~/Library/Developer/CoreSimulator/Devices` 是真实注册的模拟器，只能用 `xcrun simctl delete <UDID>` 管理，两者逻辑不得合并。

## 发布偏好

- 每次改动完成并验证通过后，自动提交并推送到 GitHub，并创建新的 patch 版本 GitHub Release 和 tag。
- 发布使用新的版本号（例如 `v0.1.3`），不得移动或覆盖已经推送的 tag；发布完成后在回复中附上 commit 和 Release 链接。
- 仅在测试和构建验证通过后发布；如果签名、公证或 GitHub Actions 发布链路失败，必须明确说明失败环节，不得把未验证的包当作正式 Release。

## 签名构建规则

- 禁止生成或交付 ad-hoc、临时签名包；本地只运行测试或无 App 包的编译验证。
- 需要 App 包时始终走发行流程，使用 Developer ID 签名、公证和 GitHub Actions 产物；不得使用 `DEVSWEEP_ALLOW_ADHOC=1` 或 ad-hoc 签名作为替代。
