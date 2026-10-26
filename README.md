# 迷你截图浮窗（练手）

`Shift-Command-4` → 收进剪贴板并撤桌面原文件 → **右下角浮窗**（Layer 1）。

系统缩略图已关：`defaults write com.apple.screencapture show-thumbnail -bool false`  
恢复：`defaults write com.apple.screencapture show-thumbnail -bool true`

## 用法

```bash
/Users/joy/mini-screenshot-overlay/MiniScreenshotOverlay &
```

### Layer 1 — 右下角浮窗
- 上：**剪裁** / **画笔**（都打开同一紧凑编辑窗）
- 中：缩略图
- 下：**复制** / **存桌面** / **飞书** / **微信**
- 无关掉按钮；约 6 秒无操作自动关（只留剪贴板）
- 复制/超时 = 只留剪贴板；存桌面 = 写 `截屏浮窗 ….png`

### Layer 2 — 紧凑编辑窗（不占满屏）
- 工具栏一行：剪裁 | 红框 | 箭头 | 文字 | … | 取消 | 保存
- 点中工具有浅蓝高亮选中态
- 从浮窗点「剪裁」→ 剪裁工具选中；点「画笔」→ 红框选中
- **取消**：丢弃，回到浮窗（原图）
- **保存**：应用标注/裁剪，回到浮窗（新图可继续分享）

## 停止

```bash
pkill -f MiniScreenshotOverlay
```
