#!/bin/bash
set -euo pipefail

# 双保险之一：把项目共享 Scheme（xcshareddata/xcschemes/*.xcscheme）中
# TestableReference 的 parallelizable="YES" 全部改为 "NO"。
#
# 只依赖 CLI 参数（-parallel-testing-enabled NO）是不够的：任何绕过
# test-ios.sh 的测试命令都会重新踩进 Scheme 的并行设置。本脚本让 Scheme
# 默认不并行，CLI 再兜底一次，任何一层被遗忘都不会批量创建 clone。
#
# Test Plan（.xctestplan）中的 parallelizable 无法用 sed 安全改写，脚本
# 只做检查并提示；请用 Xcode 或手工编辑 JSON 关闭。
#
# 用法：在 iOS 项目根目录执行 ./scripts/ensure-scheme-serial.sh

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

CHANGED=0
SCHEME_COUNT=0
while IFS= read -r scheme; do
    [ -n "$scheme" ] || continue
    SCHEME_COUNT=$((SCHEME_COUNT + 1))
    if grep -q 'parallelizable[[:space:]]*=[[:space:]]*"YES"' "$scheme"; then
        /usr/bin/sed -i '' -e 's/parallelizable[[:space:]]*=[[:space:]]*"YES"/parallelizable="NO"/g' "$scheme"
        printf '已关闭并行: %s\n' "$scheme"
        CHANGED=$((CHANGED + 1))
    fi
done < <(find . -path "*/xcshareddata/xcschemes/*.xcscheme" -not -path "*/.build/*" 2>/dev/null)

printf '共享 Scheme 共 %s 个，本次修改 %s 个。\n' "$SCHEME_COUNT" "$CHANGED"

PLAN_FOUND=0
while IFS= read -r plan; do
    [ -n "$plan" ] || continue
    PLAN_FOUND=1
    if grep -q '"parallelizable"[[:space:]]*:[[:space:]]*true' "$plan"; then
        printf '注意: Test Plan %s 仍开启 parallelizable，请在 Xcode 或 JSON 中手动关闭\n' "$plan"
    fi
done < <(find . -name "*.xctestplan" -not -path "*/.build/*" 2>/dev/null)

if [ "$PLAN_FOUND" -eq 1 ]; then
    printf '项目使用 Test Plan：请确认其中 defaultOptions.parallelization / parallelizable 已关闭。\n'
fi
