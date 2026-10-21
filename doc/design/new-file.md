# Finder 右键菜单(新建文件、复制路径)

在 Finder 的右键菜单里加两项:**复制路径**,以及 **新建文件**(文本、Markdown、Excel、Word)。对应原来的 NewFile 应用,并新增了复制路径。

代码分两处:

- `app/NewFileExtension/`:Finder Sync 扩展,真正干活的部分
  - `Source/FinderSync.swift`:菜单和创建逻辑
  - `Source/Templates/`:空白 `blank.docx`、`blank.xlsx`
  - `Config/Info.plist`、`Config/NewFileExtension.entitlements`:扩展的声明和权限
- `app/UnifiedTools/Modules/NewFile/NewFileModule.swift`:主应用里的模块,只显示扩展是否已开启并引导去开启

## 复制路径

在文件或文件夹上右键,选 **复制路径**,得到完整路径,例如 `/Users/jasper/example.txt`。

- 选中多个时,每行一个路径
- 在文件夹空白处右键,复制的是这个文件夹自己的路径
- 复制成功会有一声很轻的提示音
- 路径就是系统里真实的路径。macOS 的用户目录是 `/Users/`(U 大写),不是 `/user/`
- 复制的文字会同时进入剪贴板历史,可以在那里确认

## 新建文件

在 Finder 里右键,选 **新建文件**,再选类型:

| 菜单项 | 文件名 |
|---|---|
| 文本文档 (.txt) | 新建文本文档.txt |
| Markdown (.md) | 新建 Markdown.md |
| Excel 表格 (.xlsx) | 新建 Excel 表格.xlsx |
| Word 文档 (.docx) | 新建 Word 文档.docx |

- 在文件夹空白处右键:建在当前文件夹
- 在某个文件夹上右键:建在那个文件夹里
- 在某个文件上右键:建在它所在的文件夹
- 重名时自动加序号:`新建文本文档 2.txt`
- 创建后 Finder 会选中新文件,按回车就能改名

## 开启方法

扩展必须由你在系统里手动开启(应用不能替你开):

系统设置 → 通用 → 登录项与扩展 → Finder 扩展 → 勾选"UnifiedTools 右键菜单"(原来显示为"新建文件",已改名)。设置窗口里"新建文件"一栏有"打开扩展设置"按钮和状态显示。

开启后右键菜单不出现时,重启 Finder:

```bash
killall Finder
```

要停用这个功能,取消勾选即可。应用里模块的开关不影响扩展。

## 注意:不要同时开两个

原来的 NewFile 应用的扩展(`com.shrek.newfile.extension`)现在也是开启的。两个都开,右键菜单里会出现两个"新建文件"。确认我们的好用之后,在同一个设置页里把旧的取消勾选。

## 实现要点

- 扩展是 Finder Sync 类型,监视根目录 `/`,所以所有文件夹的右键菜单都会出现
- Finder Sync 扩展必须带沙盒。沙盒默认只能写自己的容器,因此给了 `com.apple.security.temporary-exception.files.absolute-path.read-write = /`,让它能在你有权限的任何文件夹里创建文件。这个 entitlement 不能上架 App Store,个人本机使用没有问题
- txt 和 md 是空文件;xlsx 和 docx 是随扩展打包的最小有效 Office Open XML 文件,直接复制出来。已用 `openpyxl` 读取 xlsx、用 `textutil` 转换 docx 验证过能被正常解析
- 扩展由应用内嵌:主应用 target 有"Embed Foundation Extensions"阶段和对扩展 target 的依赖,签名用同一个 Personal Team,所以不需要额外证书
- 扩展的 bundle id 是 `com.jasper.UnifiedTools.NewFile`。状态检测靠 `pluginkit -m -p com.apple.FinderSync -i <id>`:`+` 表示已开启,`-` 或没有标记表示未开启

## 已知限制

- 桌面、文档、下载等受保护的文件夹,第一次创建时系统可能弹出访问授权提示,需要点允许
- 只有这四种类型,模板固定。要加类型(比如 .py、.csv、.pptx),在 `FinderSync.swift` 的 `templates` 里加一行,需要二进制格式的再放一个模板文件
- 暂不支持自定义文件名和自定义模板

## 手动测试清单

- [ ] 在一个文件上右键 → 复制路径,粘贴得到 `/Users/…/文件名`
- [ ] 在文件夹上右键 → 复制路径,得到文件夹自己的路径
- [ ] 选中三个文件右键 → 复制路径,粘贴得到三行
- [ ] 在文件夹空白处右键 → 复制路径,得到当前文件夹路径
- [ ] 路径含空格、中文、括号时也能原样复制

- [ ] 设置窗口"新建文件"一栏先显示"未开启"
- [ ] 在系统设置里勾选后,点"重新检测"变成"已开启"
- [ ] 在桌面以外的普通文件夹空白处右键,出现"新建文件"和四个子项
- [ ] 四种文件都能创建,创建后被选中
- [ ] .txt 和 .md 能用文本编辑器打开;.xlsx 能用 Excel 或 WPS 打开,.docx 能用 Word 或 WPS 打开,不提示文件损坏
- [ ] 连续创建两次同类型文件,第二个带序号
- [ ] 在文件夹图标上右键创建,文件在文件夹里面
- [ ] 在文件上右键创建,文件在同一目录
- [ ] 在桌面和文档文件夹里创建(可能出现授权提示)
- [ ] 取消勾选旧 NewFile 的扩展后,右键菜单里只剩一个"新建文件"
