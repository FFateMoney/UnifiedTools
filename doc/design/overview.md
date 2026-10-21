# 总体方案

## 目标

把本机分散的几个 Mac 小工具合并成一个菜单栏应用,权限只授一次,只占一个菜单栏图标和一个登录项。仅本机自用,不上架 App Store,不对外分发。

## 来源与范围

| 模块 | 对应的原应用 | 范围 |
|---|---|---|
| Capture | iShot | 截图、贴图、OCR;标注、录屏、长截图后续再做 |
| Clipboard | iCopy | 剪贴板历史、搜索、快捷键呼出并粘贴 |
| CleanMode | State | 只做黑屏和键盘失效,State 的其他监控功能不做 |

不纳入:FlyKey、Mos、NewFile、我的壁纸、Highlights。原应用都是闭源商业软件,只对照功能自己实现,不复制其代码或资源。

## 技术选型

- 语言和界面:Swift,菜单栏与设置页用 SwiftUI,全屏遮罩、截图覆盖层、浮动面板用 AppKit
- 最低系统:macOS 14(使用 `SCScreenshotManager`)
- 形态:普通应用(有 Dock 图标和主窗口),同时保留菜单栏图标
- 关闭沙盒:事件拦截和模拟粘贴需要辅助功能权限
- 开机自启:`SMAppService.mainApp`
- 存储:设置用 UserDefaults,剪贴板历史用 SQLite

## 代码结构(app/ 下)

```
App/            入口、菜单栏、设置窗口、开机自启
Core/
  Module        模块协议:id、菜单项、快捷键、设置页、start/stop
  PermissionCenter  统一检测并引导屏幕录制、辅助功能、输入监控
  HotkeyCenter      集中注册全局快捷键并检测冲突
  Settings
Modules/
  Capture/
  Clipboard/
  CleanMode/
```

每个模块实现同一个 `Module` 协议,可在设置里单独开关。

## 模块设计

### Capture

- 每块屏幕盖一个透明窗口做区域选择,显示尺寸和放大镜
- 用 `SCScreenshotManager.captureImage` 抓取选区
- 输出:复制、保存到文件夹、贴图(置顶 `NSPanel`)
- OCR:Vision 的 `VNRecognizeTextRequest`,支持中英文

### Clipboard

- 每 0.5 秒检查 `NSPasteboard.changeCount`,有变化就记录文本、图片、文件路径
- SQLite 存储,内容去重,可设条数上限,图片只存缩略图和路径
- 前台应用在黑名单中则不记录;带 `org.nspasteboard.ConcealedType` 标记的内容跳过
- 快捷键呼出浮动面板,支持搜索与方向键选择;粘贴时先写回剪贴板,再用 `CGEvent` 模拟 Cmd+V

### CleanMode

- 黑屏:每块屏幕一个全黑无边框窗口,层级 `CGShieldingWindowLevel`,隐藏光标;进入时用 `IOPMAssertion` 防止显示器休眠,退出时释放
- 键盘失效:`CGEventTap` 拦截 `keyDown`、`keyUp`、`flagsChanged` 和系统功能键(类型 14),回调返回 nil;可选同时屏蔽鼠标和触控板
- 退出:键盘被屏蔽,所以用长按鼠标左键 3 秒,加超时自动退出(默认 2 分钟,可调)
- 三种入口:仅黑屏、仅锁键盘、两者同时

## 已知风险

1. 反复重新签名会使屏幕录制、辅助功能、输入监控授权失效,须使用固定签名身份(见 `doc/setup/signing.md`)
2. 事件拦截拦不住电源键和 Touch ID 键;输入密码时系统开启安全输入,拦截会失效
3. `CGEventTap` 超时会被系统禁用,回调中必须收到禁用通知后立即重新启用
4. 合并后须退出或卸载原 iShot、iCopy、State,否则全局快捷键冲突

## 里程碑

| 阶段 | 内容 | 验证方式 |
|---|---|---|
| M1 | 工程骨架、菜单栏、`Module` 协议、`PermissionCenter`、开机自启、固定签名 | 菜单栏出现图标,权限只引导一次 |
| M2 | CleanMode | 一键黑屏加锁键盘,能可靠退出 |
| M3 | Clipboard | 复制内容进入历史,快捷键呼出并粘贴 |
| M4 | Capture 基础版 | 快捷键截图并贴到桌面 |
| M5 | Capture 进阶 | 标注、录屏、长截图、取色,按需再做 |

## 范围变更与现状(2026-10-21)

- M1 到 M4、M5 的标注部分已完成;新增了原方案没有的"新建文件"(Finder 右键新建 txt、md、xlsx、docx),见 `new-file.md`;快捷键可自定义,见 `hotkeys.md`
- 取色器、录屏、长截图、翻译:确认不需要,**不再实现**
- 新增**概览页**:系统状态(CPU、内存、存储、温度、网络、GPU、电池),取代原 State 的监控显示,见 `system-status.md`;原来的快捷操作移到了**操作**页
- 剪贴板额外支持了图片(原方案默认不记录)
- 新增 **应用管理**(列出已安装应用、查残留、移到废纸篓),以及一个带 Dock 图标的**主窗口**,见 `app-manager.md`;应用不再是纯菜单栏应用
- 原来的 iShot、iCopy、State、NewFile 已卸载,见 `setup/legacy-tools.md`
