# Changelog

## v1.0（进行中）

正式首版。验收通过一项勾一项；整版本机验收后再问是否 commit / tag / push。

### 已完成
- [x] 编辑窗多步 ⌘Z（标注 / 剪裁可连按撤销）— `93db8c0`
- [x] 浮窗退场：往右下角滑出（贴近系统截图缩略图）— 待 commit
- [x] 箭头端点可拖— 待 commit
- [x] 浮窗叠放角标：浅灰底 + 深灰字（macOS 风，非红通知）— 待 commit

### 实现中 / 待验收
- [ ] App 图标（`AppIcon.icns` from `assets/lazyshot_final_app_1024.png`）+ 菜单栏状态项（template PNG，显示「lazyshot 运行中」/ 退出）— 实现中 / 待验收
- [ ] 打成 `.app`（`lazyshot.app`，Bundle ID `com.joytang.lazyshot`；未签名，首次需右键打开）
- [ ] 存桌面默认文件名：`lazyshot_MMddHHmm.png`（例：`lazyshot_10272304.png`；同秒冲突 `-2`/`-3`；监视器忽略 `lazyshot`/`截屏浮窗` 前缀）— 实现中 / 待验收
- [ ] 连截卡牌叠放（浮窗仍在时再截叠进同一摞，最多 5 张；微偏移 + 角标张数；**复制整摞**进剪贴板）— 实现中 / 待验收
- [ ] 超时自动关 = 整摞存桌面再滑走；一键存桌面 = 整摞落盘 — 实现中 / 待验收

---

## 更早（未单独标版本）

- 小浮窗 + 紧凑编辑窗（剪裁 / 画笔同窗）
- 复制 / 存桌面 / 飞书 / 微信
