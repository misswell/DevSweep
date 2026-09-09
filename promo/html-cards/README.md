# DevSweep HTML 功能说明卡

三张竖版宣传图由 HTML + CSS 直接排版，再用固定画布渲染为 PNG。中文负责主要叙事，英文用于产品信息层级和功能标签。

画布尺寸：`1080 × 1350 px`

## 卡片

- `scan`：先扫描，再决定。展示空间地图与扫描结果。
- `coverage`：全栈工具链，一次看清。展示工具链覆盖范围。
- `safety`：清理，也要有边界。展示扫描、审阅、回收流程。

## 本地预览

```bash
python3 -m http.server 4174 --directory promo/html-cards
```

打开以下地址切换卡片：

- `http://127.0.0.1:4174/cards.html?card=scan`
- `http://127.0.0.1:4174/cards.html?card=coverage`
- `http://127.0.0.1:4174/cards.html?card=safety`

## 重新导出

在仓库根目录执行：

```bash
promo/html-cards/render.sh
```

PNG 会输出到 `promo/html-cards/exports/`。
