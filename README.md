# UnifiedTools

把几个常用的 Mac 小工具合并成一个应用:菜单栏常驻,同时有一个带 Dock 图标的主窗口。个人自用项目,开源分享,不上架 App Store。

macOS 14 及以上,Apple 芯片上开发和使用,Swift + SwiftUI + AppKit。

## 功能

| 功能 | 说明 |
|---|---|
| 截图 | 区域截图;复制、保存、贴图(置顶悬浮)、文字识别(中英文);矩形、箭头、画笔、马赛克、文字标注 |
| 剪贴板历史 | 记录文本、文件路径、图片;搜索、方向键选择、回车粘贴;应用黑名单、暂停、清空 |
| 清洁模式 | 一键黑屏、锁定键盘,清洁屏幕和键盘时用;长按鼠标 3 秒或超时自动退出 |
| Finder 右键菜单 | 复制路径;新建 txt、Markdown、Excel、Word 文件 |
| 系统状态 | 概览页:CPU、内存、存储、温度、网络、GPU、电池 |
| 应用管理 | 列出已安装应用,查找残留文件,移到废纸篓 |
| 快捷键 | 所有全局快捷键可自定义,并提示与系统快捷键的冲突 |

默认快捷键:截图 `⌃⌥A`,剪贴板历史 `⌘⇧V`,黑屏并锁定键盘 `⌃⌥⌘K`。

## 构建

需要 Xcode 和一个 Apple ID(免费的 Personal Team 就够,不需要付费开发者账号)。

1. 用 Xcode 打开 `app/UnifiedTools.xcodeproj`
2. 在两个 target(`UnifiedTools`、`NewFileExtension`)的 Signing & Capabilities 里,把 Team 换成你自己的。**Bundle Identifier 也要换成你自己的**,否则会和作者的冲突
3. 编译运行

固定的签名身份很重要:系统按签名记住屏幕录制、辅助功能、输入监控的授权,每次用不同的临时签名(ad-hoc)重新编译都会让授权失效。证书一直被判无效时,先检查系统时钟是否准确,详见 [doc/setup/signing.md](doc/setup/signing.md)。

## 权限

应用需要你在系统设置里手动授予(设置窗口里有引导):

- **屏幕录制**:截图
- **辅助功能**:剪贴板历史模拟粘贴
- **输入监控**:清洁模式拦截键盘

Finder 右键菜单是 Finder 扩展,需要在 系统设置 → 通用 → 登录项与扩展 → Finder 扩展 里手动勾选。

## 说明

- 应用关闭了沙盒(事件拦截和模拟粘贴需要),因此不能上架 App Store
- Finder 扩展带沙盒,并使用了"可写任意路径"的临时例外 entitlement,同样不能上架
- 温度读数使用了 IOKit 里未公开的符号,系统升级后可能失效,失效时只是不显示温度
- 应用管理只把文件移到废纸篓,不会彻底删除;需要管理员权限的部分会弹出系统自己的密码框
- 这是个人项目,按自己的需要实现,没有做过大范围的兼容性测试

## 目录

```
app/    Xcode 工程和源码
doc/    设计、规范和环境配置文档(从 doc/index.md 看起)
```

根目录只放文件夹,加上仓库必需的 `.gitignore`、`LICENSE`、`README.md`。规则见 [doc/conventions/directory-rules.md](doc/conventions/directory-rules.md)。

## 许可证

[MIT](LICENSE)
