#!/bin/bash
set -euo pipefail

# iOS 项目统一测试入口。
#
# 放置位置：<iOS 项目根目录>/scripts/test-ios.sh（从 DevSweep 仓库
# deploy/ios-project-template/scripts/test-ios.sh 复制，按需微调即可）。
#
# 设计目标：日常开发验证只使用一个 Simulator，从源头杜绝 XCTest parallel
# testing 不断创建 clone，导致 ~/Library/Developer/XCTestDevices 膨胀。
#
# 约束：
#   * workspace / project / scheme 运行时自动探测，仓库中不提交占位符；
#   * 只允许一个 -destination，优先使用 IOS_TEST_DESTINATION 环境变量；
#   * 固定 -parallel-testing-enabled NO 和 -maximum-parallel-testing-workers 1；
#   * 绝不执行 simctl create：设备只从 `xcrun simctl list devices available`
#     里复用；没有任何可用设备时直接失败并列出设备。
#
# 用法：
#   ./scripts/test-ios.sh
#   IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' ./scripts/test-ios.sh
#   IOS_TEST_SCHEME=MyScheme ./scripts/test-ios.sh -only-testing:MyAppTests

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# 1) workspace / project 自动探测
XCODE_ARG=()
WORKSPACE="$(ls -d ./*.xcworkspace 2>/dev/null | head -1 || true)"
PROJECT="$(ls -d ./*.xcodeproj 2>/dev/null | head -1 || true)"
if [ -n "$WORKSPACE" ]; then
    XCODE_ARG=(-workspace "$WORKSPACE")
    printf 'Workspace: %s\n' "$WORKSPACE"
elif [ -n "$PROJECT" ]; then
    XCODE_ARG=(-project "$PROJECT")
    printf 'Project: %s\n' "$PROJECT"
else
    fail "未找到 .xcworkspace / .xcodeproj；请把本脚本放在 iOS 项目根目录的 scripts/ 下"
fi

# 2) scheme 自动探测（可用 IOS_TEST_SCHEME 覆盖）
SCHEME="${IOS_TEST_SCHEME:-}"
if [ -z "$SCHEME" ]; then
    SCHEME="$(/usr/bin/xcodebuild -list "${XCODE_ARG[@]}" 2>/dev/null \
        | sed -n '/Schemes:/,$p' \
        | tail -n +2 \
        | sed -e '/^[[:space:]]*$/,$d' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | head -1 || true)"
fi
if [ -z "$SCHEME" ]; then
    /usr/bin/xcodebuild -list "${XCODE_ARG[@]}" >&2 || true
    fail "未能探测到 scheme；请用 IOS_TEST_SCHEME=<真实 Scheme> 重新运行"
fi
printf 'Scheme: %s\n' "$SCHEME"

# 3) destination：固定单个 Simulator；只复用已有设备，绝不创建
DESTINATION="${IOS_TEST_DESTINATION:-}"
if [ -z "$DESTINATION" ]; then
    DEVICE_NAME="$(/usr/bin/xcrun simctl list devices available \
        | sed -n 's/^[[:space:]]*\(iPhone[^()]*\) ([^)]*) ([^)]*)[[:space:]]*$/\1/p' \
        | head -1 \
        | sed -e 's/[[:space:]]*$//' || true)"
    if [ -z "$DEVICE_NAME" ]; then
        /usr/bin/xcrun simctl list devices available >&2
        fail "没有可用的 iPhone Simulator；请复用已有设备或安装模拟器运行时，禁止 simctl create 新建设备"
    fi
    DESTINATION="platform=iOS Simulator,name=${DEVICE_NAME},OS=latest"
fi
printf 'Destination: %s（单个 Simulator）\n' "$DESTINATION"

# 4) 保护参数：默认路径禁止被额外参数改回并行或多 destination
for arg in "$@"; do
    case "$arg" in
        *parallel-testing-enabled*|*-parallel-testing-worker-count*|*-maximum-parallel-testing-workers*)
            fail "禁止通过参数覆盖并行配置（$arg）。确需并行测试时，必须获得用户明确同意后手动执行 xcodebuild（最多 2 个 worker），结束后恢复单 Simulator 默认"
            ;;
        -destination)
            fail "禁止追加第二个 -destination；本脚本固定使用单一 Simulator"
            ;;
    esac
done

# 5) 测试：单 destination + 并行关闭（CLI 这一层的双保险；另一层在 Scheme 内关闭）
printf '\n开始测试（单 Simulator、XCTest 并行已关闭）...\n\n'
exec /usr/bin/xcodebuild test \
    "${XCODE_ARG[@]}" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    "$@"
