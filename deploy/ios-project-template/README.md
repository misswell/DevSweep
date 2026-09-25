# iOS 项目测试模板（防止 XCTest clone 爆炸）

XCTest parallel testing 会为每个并行 runner 克隆一台模拟器，clone 全部落在
`~/Library/Developer/XCTestDevices/<UUID>`。Agent 为了"加速验证"默认开并行，
是测试设备目录动辄出现十几个 clone 的根本原因。DevSweep 只能事后清理这些
clone，真正的防线在每个 iOS 项目内部。

## 内容

| 文件 | 作用 |
| --- | --- |
| `scripts/test-ios.sh` | 统一测试入口：自动探测 workspace/project/scheme（仓库里不提交占位符），固定单个 `-destination`、`-parallel-testing-enabled NO`、`-maximum-parallel-testing-workers 1`，只复用已有 Simulator，绝不 `simctl create` |
| `scripts/ensure-scheme-serial.sh` | 把共享 Scheme 中 `TestableReference` 的 `parallelizable="YES"` 全部改为 `"NO"`，并检查 `.xctestplan` 的 parallelizable |
| `AGENT-RULES.md` | 需要合并进 iOS 项目 `AGENTS.md`（使用 Claude Code 时同时合并进 `CLAUDE.md`）的 Agent 规则原文 |

## 在 iOS 项目中启用

1. 复制两个脚本到项目根目录并加执行权限：

   ```bash
   mkdir -p scripts
   cp deploy/ios-project-template/scripts/*.sh <iOS 项目>/scripts/
   chmod +x <iOS 项目>/scripts/test-ios.sh <iOS 项目>/scripts/ensure-scheme-serial.sh
   ```

2. 关闭 Scheme 并行（双保险之一）：

   ```bash
   cd <iOS 项目> && ./scripts/ensure-scheme-serial.sh
   ```

3. 把 `AGENT-RULES.md` 中的规则段合并进项目 `AGENTS.md` / `CLAUDE.md`。

## 日常使用

```bash
# 默认：自动选择第一台可用的 iPhone Simulator（绝不创建）
./scripts/test-ios.sh

# 项目约定的主测试设备（不把 UDID 提交进 Git，用环境变量或 CI 配置）
IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' ./scripts/test-ios.sh

# 指定 scheme（自动探测失败时）
IOS_TEST_SCHEME=MyApp ./scripts/test-ios.sh
```

脚本会拒绝 `*-parallel-testing-enabled*`、`*-maximum-parallel-testing-workers*`
和第二个 `-destination` 参数。确需并行测试（用户明确要求时最多 2 个 worker），
请手动执行 `xcodebuild` 并在结束后恢复单 Simulator 默认。

## 验证不再持续增长

```bash
ls ~/Library/Developer/XCTestDevices | wc -l     # 记录基线
./scripts/test-ios.sh && ./scripts/test-ios.sh && ./scripts/test-ios.sh
ls ~/Library/Developer/XCTestDevices | wc -l     # 不应每次增加多个 clone
```

连续运行后 clone 数量只应缓慢增加（每次测试最多 1 台新 clone），不会再出现
一次测试新增 5~18 个 clone 的曲线。历史 clone 用 DevSweep 扫描清理：空闲状态
下明确 UUID 的 clone 显示「可安全清理」并默认勾选。
