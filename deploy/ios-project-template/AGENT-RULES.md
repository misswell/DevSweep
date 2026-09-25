# iOS 项目 Agent 规则（复制进 AGENTS.md / CLAUDE.md）

把下面的整段内容原样合并进每个 iOS 项目的 `AGENTS.md`；如果项目使用
Claude Code，把同样内容也放进 `CLAUDE.md`。

---

## iOS Simulator 测试规则

日常开发验证默认只能使用一个 iOS Simulator。

所有 iOS 测试必须优先通过：

```
./scripts/test-ios.sh
```

执行。

禁止 Agent：

- 自行创建新的 Simulator
- 使用 `simctl create`
- 同时指定多个 `-destination`
- 默认开启 XCTest parallel testing
- 使用 `-parallel-testing-enabled YES`
- 自动增加 parallel worker
- 为了提高测试速度自行创建 simulator clone
- 修改测试脚本把 worker 数量提高

默认必须：

```
-parallel-testing-enabled NO
-maximum-parallel-testing-workers 1
```

如果现有测试 Simulator 不可用：

先列出已有：

```
xcrun simctl list devices available
```

复用已有设备。不能自行创建新设备。

只有用户明确要求并行测试时，才允许临时最多使用 2 个 worker。
并行测试结束后必须恢复默认单 Simulator 配置。

日常开发、修 bug、功能验证都使用 1 个。

---

## 补充说明（给维护者，不要复制进项目规则）

- Apple 官方支持通过 `-parallel-testing-enabled` 覆盖 Scheme 的并行设置，
  `-parallel-testing-worker-count` / `-maximum-parallel-testing-workers`
  控制 runner 数量。并行开启时 Xcode 会为每个 runner 克隆模拟器，这正是
  `~/Library/Developer/XCTestDevices` 快速增长的主要原因。
- 三层约束缺一不可：
  1. **Scheme**：`scripts/ensure-scheme-serial.sh` 把共享 Scheme 的
     `parallelizable` 改为 `NO`（绕过脚本的人也被拦住）；
  2. **CLI**：`scripts/test-ios.sh` 固定 `-parallel-testing-enabled NO`
     和 `-maximum-parallel-testing-workers 1`，并拒绝参数覆盖；
  3. **Agent 规则**：上面的规则文本写进 `AGENTS.md` / `CLAUDE.md`。
- 禁止创建 `~/bin/xcodebuild`、`/usr/local/bin/xcodebuild` 之类的全局
  wrapper 或改 PATH 去劫持系统 `xcodebuild`——那会影响 Xcode、Fastlane、
  CI 和其他项目的 Archive/Release。限制只放在 Scheme、测试脚本和 Agent
  规则三个层次。
- 真实注册的模拟器在 `~/Library/Developer/CoreSimulator/Devices`，必须用
  `xcrun simctl delete <UDID>` 管理；`~/Library/Developer/XCTestDevices`
  下的 UUID 目录才是测试临时 clone，可由 DevSweep 清理。两者不能混用。
