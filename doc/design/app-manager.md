# 应用管理(AppManager)与主窗口

代码在 `app/UnifiedTools/Modules/AppManager/` 和 `app/UnifiedTools/App/MainWindow.swift`。

## 主窗口

应用现在是普通应用:有 Dock 图标和启动台图标,点开会打开主窗口;菜单栏图标也保留。

- 左边栏四页:**概览**(系统状态,见 `system-status.md`)、**操作**(各功能的快捷操作、权限状态)、**应用管理**、**设置**(权限、快捷键、开机自启、各模块设置)
- 关闭窗口不会退出,应用继续在菜单栏运行,快捷键照常可用;`⌘Q` 或菜单栏"退出"才退出
- 应用已在运行时再点 Dock 或启动台图标,会把主窗口带到前面
- **开机自启时不弹窗口**:通过 Apple Event 里的登录项标记识别,只留菜单栏图标。此识别尚未在真实重启后验证
- 菜单栏的"打开主窗口"和"设置…"、各模块的菜单项(如"应用管理…")都会打开主窗口对应的页面
- 应用图标是程序生成的占位图标(渐变方块加四宫格),想换自己的,替换 `Assets.xcassets/AppIcon.appiconset/` 里的 PNG

## 应用管理

列出 `/Applications` 和 `~/Applications` 里的所有应用(含一层子文件夹):

- 每行显示图标、名称、大小、最后使用时间、来源(App Store 或其他)
- 搜索(名称或标识)、筛选(全部、App Store、其他来源、90 天没用过)、排序(大小、最后使用、名称)
- 右侧是选中应用的详情和**残留文件**列表,每项可勾选,带大小

### 残留查找

按应用的 bundle id 去固定位置匹配,同时带上应用里嵌的登录项、扩展、XPC 服务的 id,以及应用安装的特权助手标签:

- `~/Library` 下:Application Support、Caches、Preferences(含 ByHost)、Containers、Application Scripts、Saved Application State、Logs、HTTPStorages、WebKit、Cookies、LaunchAgents
- `/Library` 下(需要管理员):Application Support、Caches、Preferences、LaunchAgents、LaunchDaemons、PrivilegedHelperTools
- 应用声明的共享组(Group Containers)和 iCloud 容器(从代码签名的 entitlements 读出)
- 按应用名猜的:`Application Support/名称`、`Caches/名称`、`Logs/名称`,以及主目录下的隐藏目录 `~/.名称`、`~/.config/名称`、`~/.cache/名称`

**误伤保护**:
- 匹配规则是"完全相等或以 `标识.` 开头",并且会排除属于另一个已安装应用的更长标识。比如装了 `com.foo.Bar` 和 `com.foo.Bar.Pro`,删前者时不会碰后者的文件
- 默认只勾选"按标识匹配"的项。按名称猜的、隐藏目录、iCloud 数据、与其他应用共用的共享组,默认不勾选并给出黄色提示(隐藏目录常是模型、镜像这类用户数据)

### 移除

点"移到废纸篓…"并确认后:

1. 先退出这个应用及它的辅助进程(先请求退出,约 4 秒还没退出就强制)
2. 用户目录里的文件用系统的废纸篓接口移走
3. 需要管理员权限的(`/Applications` 里属于 root 的应用本体、`/Library` 下的文件)一次性批量处理:弹出系统自己的管理员密码框,**密码由你输入,应用看不到**;LaunchDaemons 里的会先停掉再移;移完把所有权交还给你,以后清倒废纸篓不再要密码
4. 可选:同时清除它的隐私授权记录(`tccutil reset All`),默认开启
5. 弹出结果:移走了几项、哪些没处理成功以及原因

**全部是移进废纸篓,不会彻底删除。**

不能在这里移除的:本应用自己,以及苹果自带且不是 App Store 来源的应用(如 Safari)。这些行带锁图标。

### 已知限制

- `~/Library/Containers` 和 `~/Library/Group Containers` 受 macOS 保护,没有"完全磁盘访问权限"时移动会失败,结果里会列出并提示手动删除
- 只认固定位置。厂商/产品两级目录(如 `Application Support/Google/Chrome`)、用 pkg 安装留下的收据、其他自定义位置找不到
- 大小是 `du` 的分配大小,不含找不到的残留
- 最后使用时间来自 Spotlight,没有记录的显示"没有使用记录"
- 系统自带位置(`/System/Applications`)的应用不列出

## 手动测试清单

- [ ] 点启动台或 Applications 里的 UnifiedTools:出现主窗口,有 Dock 图标
- [ ] 关闭窗口后菜单栏图标和快捷键仍可用;再点 Dock 图标窗口回来
- [ ] 操作页的快捷操作能触发截图、剪贴板、清洁模式等
- [ ] 应用管理页能列出应用,大小随后逐个出现;搜索、筛选、排序正常
- [ ] 选中一个小应用:残留列表合理,默认勾选的是标识匹配项
- [ ] 选中 Pages/Numbers/Keynote:共享组提示"与…共用",默认不勾选
- [ ] Safari 或 UnifiedTools 自己显示带锁,不能移除
- [ ] 移除一个不再用的非 App Store 应用:弹出管理员密码框,完成后应用和残留都进了废纸篓
- [ ] 取消密码框:结果里列出没处理的项,应用没丢
- [ ] 重启电脑后自动启动:只有菜单栏图标,不弹主窗口
