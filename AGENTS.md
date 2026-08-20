# DevSweep 项目规则

## 发布偏好

- 每次改动完成并验证通过后，自动提交并推送到 GitHub，并创建新的 patch 版本 GitHub Release 和 tag。
- 发布使用新的版本号（例如 `v0.1.3`），不得移动或覆盖已经推送的 tag；发布完成后在回复中附上 commit 和 Release 链接。
- 仅在测试和构建验证通过后发布；如果签名、公证或 GitHub Actions 发布链路失败，必须明确说明失败环节，不得把未验证的包当作正式 Release。
