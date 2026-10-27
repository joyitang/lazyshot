# lazyshot

ADHD救星 macOS截图小工具
A tiny screenshot overlay for Mac.

<!-- 公开前换成实拍：浮窗一张、编辑窗一张 -->

## 干嘛用

默认系统截屏快捷键 `⇧⌘4`，截图后快速便捷操作


## 功能

- 系统截图后右下角浮窗
- 浮窗：复制 / 存桌面 / 飞书 / 微信
- 快捷编辑：剪裁、红框、箭头、文字、撤销操作
- 连截叠放（最多5张）
- 复制整摞；存盘 / 超时整摞落桌面（文件名 `lazyshot_月日时分`）

## 系统要求

- macOS 13 及以上

## 安装

1. 下载 `lazyshot.app`，或本地跑 `./build.sh`
2. 放到「应用程序」或随便哪个文件夹都行
3. 第一次若被系统拦住：在访达里对图标 **右键 → 打开**
4. 看菜单栏有没有 lazyshot 图标

```bash
git clone https://github.com/joytang123/lazyshot
cd lazyshot
./build.sh
open ./lazyshot.app
```

退出：菜单栏点退出，或：

```bash
pkill -f 'lazyshot.app/Contents/MacOS/lazyshot'
```

## 权限

lazyshot 不自己截屏，只盯桌面上的系统截图文件，所以一般不需要「屏幕录制」。

需要能读桌面新截图、写出 `lazyshot_*.png`。浮窗不出来或存不了盘时，去「隐私与安全性」里查一下文件 / 桌面访问。

可选：关掉系统截图缩略图，避免跟浮窗叠在一起：

```bash
defaults write com.apple.screencapture show-thumbnail -bool false
```

改完可能要重新登录，或重启一下相关系统进程。

## 快捷键

| 做什么 | 怎么按 |
| --- | --- |
| 区域截图 | `⇧⌘4`（系统自带） |
| 编辑里撤销 | `⌘Z` |
| 退出 | 菜单栏 → 退出 |

## 已知限制

- 点「飞书 / 微信」只会放**顶图**进剪贴板并尽量打开 App，不会帮你粘进聊天；本机得装着对应软件。
- 「复制」整摞时，有的软件只吃一张；聊天软件表现也不一样。
- 只认桌面上以 `截屏` / `Screenshot` / `Screen Shot` 开头的 png/jpg；自己存的 `lazyshot_*` 不会再弹窗。
- 没做代码签名 / 公证时，Gatekeeper 可能拦第一次打开。
- 预编译包暂时只有 arm64。

## License

[MIT](LICENSE)

## 仓库

- 产品名：lazyshot
- GitHub：`https://github.com/joytang123/lazyshot`
