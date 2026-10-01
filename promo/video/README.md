# DevSweep 宣传动画视频

确定性逐帧渲染的 34 秒宣传动画：HTML/JS 动画引擎 → Chrome 无头 CDP 截帧 → ffmpeg 合成，
配乐由 `soundtrack.js` 纯 Node 合成（90 BPM，A 小调，34 s 立体声）。

## 规格

- 1920×1080，60 fps，34.0 s（2040 帧），H.264 + AAC，无二维码
- 六幕：钩子（磁盘又满了）→ 品牌亮相 → 深度扫描 → 一键清理 → 安全边界 → 结尾 CTA

## 使用

```bash
node render.js --sample 2,7,13,20,25,30   # 抽样关键帧到 shots/ 快速预览
node render.js                            # 全量渲染 2040 帧到 frames/（约 15 分钟）
node soundtrack.js                        # 生成 soundtrack.wav
./build.sh                                # 合成 devsweep-promo-16x9-1080p.mp4
```

依赖：本机 Chrome（`/Applications/Google Chrome.app`）、ffmpeg、Node 22+（无需 npm 依赖）。

## 结构

- `engine.html` — 动画引擎，全部动画由 `window.__seek(t)` 以时间参数确定性驱动
- `render.js` — 启动无头 Chrome，CDP 逐帧 `__seek(t)` + `Page.captureScreenshot`
- `soundtrack.js` — 合成配乐 WAV（pad/贝斯/鼓/琶音/riser/impact 全程序化生成）
- `build.sh` — ffmpeg 合成成片
- `frames/`、`shots/`、`soundtrack.wav`、`.chrome-profile/` 为生成产物，不入库
