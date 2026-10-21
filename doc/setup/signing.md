# 本机签名与权限

## 结论

仅本机自用,不需要付费开发者账号,也不需要公证。

## 为什么要固定签名身份

系统按代码签名身份记住屏幕录制、辅助功能、输入监控的授权。ad-hoc 签名每次重新编译都会变,授权随之失效。因此开发期必须用固定的身份签名。

## 方案

在 Xcode 的 Settings → Accounts 登录免费 Apple ID,工程 Signing 选 "Personal Team",会得到 "Apple Development" 证书。

免费 Personal Team 的限制:证书有效期一年,到期重新生成;不能用推送通知、iCloud 等付费能力,本项目用不到。

备选:在钥匙串访问里创建自签名的"代码签名"证书,工程里指定使用。

## 环境检查记录(2026-10-21)

- Xcode 27.1、Swift 6.4 已安装
- Apple ID 已在 Xcode 登录
- `security find-identity -v -p codesigning` 仍显示 0 个有效证书
- Xcode 里已有 Personal Team(`2486J7246D`),工程已配置自动签名
- 命令行 `xcodebuild -allowProvisioningUpdates` 报错 `No "Mac Development" signing certificate ... with a private key was found`:命令行无法自行创建证书
- 处理方法:用 Xcode 打开 `app/UnifiedTools.xcodeproj`,选中 target → Signing & Capabilities,确认 Team 为 Personal Team,Xcode 会自动生成证书;之后命令行即可正常签名编译
- 无签名编译(`CODE_SIGNING_ALLOWED=NO`)已验证代码可通过编译,但无签名的应用拿不到稳定的权限授权,不能用于日常使用

## 最终结论(2026-10-21)

**证书"已过期"的真正原因是这台 Mac 的时钟比真实时间慢约 1 小时**(`sntp time.apple.com` 偏差 +3604 秒)。苹果按真实时间签发证书,本机判定其"尚未生效",系统用同一个错误码 `CSSMERR_TP_CERT_EXPIRED` 表示"过期"和"未生效"。时间改为自动同步后偏差归零,证书变为有效。

- 以后遇到证书无效,先跑 `sntp time.apple.com` 看时钟偏差,再看别的
- 当前使用 Apple Development 证书签名,指定要求为 `identifier "com.jasper.UnifiedTools" and ... certificate leaf[subject.CN] = "Apple Development: ..."`,重新编译不会变,权限授权只需做一次
- 证书有效期一年(到 2027-10-21),到期在 Xcode 的 Manage Certificates 里重新生成,并重新授权一次
- 下面的"排查经过"里关于旧 WWDR 中间证书的推断是错的,仅作记录:那个证书确实已过期并已删除,但不是问题根源

## 排查经过与现状(部分已过时)

- 钥匙串里曾有 3 个 Apple Development 证书,系统判为 `CSSMERR_TP_CERT_EXPIRED`。系统钥匙串里有一个 2023-02-07 过期的旧 WWDR 中间证书,已删除(SHA-1 `FF6797793A3CD798DC5B2ABEF56F73EDC9F83A64`);那 3 个证书也已被删除
- Xcode 的 Signing 页面曾提示 `Signing certificate ... is not valid for code signing. It may have been revoked or expired.`,与账号类型无关。Personal Team 是免费 Apple ID 的正常团队类型,不是问题所在
- 当前方案:Signing Certificate 选 "Sign to Run Locally"(ad-hoc,工程里 `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"`),命令行构建通过,签名为 `adhoc`、`TeamIdentifier=not set`
- ad-hoc 签名的风险:授权按代码哈希记忆,重新编译后屏幕录制、辅助功能、输入监控可能需要重新勾选。是否真的会重置,需要在 M2 实测后在此补充结论
- 若实测每次编译都要重新授权,再回到固定证书方案(Apple Development 或自签名)
- 实测结论(2026-10-21):ad-hoc 签名的指定要求就是代码哈希(`designated => cdhash H"..."`),重新编译后哈希改变,旧授权失效,必须在系统设置里删掉旧条目再重新添加。需要换固定证书
