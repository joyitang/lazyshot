# 迷你截图浮窗（练手）

`Shift-Command-4` → 收进剪贴板并撤桌面原文件 → 只弹我们的浮窗。

系统缩略图已关：`defaults write com.apple.screencapture show-thumbnail -bool false`  
恢复系统缩略图：`defaults write com.apple.screencapture show-thumbnail -bool true`

## 用法

```bash
/Users/joy/mini-screenshot-overlay/MiniScreenshotOverlay &
```

- **复制** / **约 3.5 秒没点**：只留剪贴板，不落盘
- **存桌面**：写入 `截屏浮窗 ….png`

## 停止

```bash
pkill -f MiniScreenshotOverlay
```
