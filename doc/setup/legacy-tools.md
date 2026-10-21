# 已卸载的旧工具

2026-10-21 起,以下四个应用的功能由 UnifiedTools 取代并已卸载:

| 旧应用 | 取代它的模块 | 文档 |
|---|---|---|
| iShot | 截图 | `design/capture.md` |
| iCopy | 剪贴板历史 | `design/clipboard.md` |
| State(只用到清洁屏幕和键盘) | 清洁模式 | `design/clean-mode.md` |
| NewFile | 新建文件 | `design/new-file.md` |

保留未动:FlyKey、Mos。

## 做了什么

- 四个应用从 `/Applications` 移进了废纸篓(没有彻底删除)
- State 带一个以 root 运行的后台守护进程 `cn.better365.StateTool`,已停止;它的 `LaunchDaemons` 配置和 `/Library/Application Support/Better365`(只含 State 的组件)也移进了废纸篓
- 用户资料库里 10 个 `Application Scripts` 目录移进了废纸篓下的 `old-tools-leftovers-…` 文件夹

## 没清掉的

`~/Library/Containers` 和 `~/Library/Group Containers` 里这几个旧目录被 macOS 保护,命令行移不动,都是空的或约 36KB,无影响。想清掉可以在 Finder 里手动删,或给终端完全磁盘访问权限:

- Containers:`cn.better365.iCopy`、`cn.better365.iCopyHelper`、`cn.better365.iShotHelper`、`cn.better365.ishot`、`com.better365.menubar`、`com.shrek.newfile`、`com.shrek.newfile.extension`
- Group Containers:`4K6FWZU8C4.group.cn.better365`、`4K6FWZU8C4.group.com.better365.menubar`、`group.com.shrek.newfile`
- iCloud 里 iCopy 的容器 `iCloud~cn~better365~iCopy` 是空的,由系统管理,没有处理

注意:FlyKey 自己的容器是 `…FlyKey` 结尾的那些,不要删。

## 没有迁移的数据

iCopy 以前的剪贴板历史没有导入 UnifiedTools。

## 恢复办法

应用和文件还在废纸篓里,清倒之前可以直接拖回去。State 的守护进程配置恢复后还要重新加载,一般不建议。iShot、iCopy、State、NewFile 都带 App Store 收据,也可以从 App Store 重新下载。
