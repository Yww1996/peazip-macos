# PeaZip · macOS 原生前端

用 SwiftUI 重写的 PeaZip 前端，驱动 PeaZip 自带的 7-Zip 引擎。装好后就是
`/Applications/PeaZip.app`，替代原来的 Lazarus/LCL 版本。

原版的问题：LCL 把每个主题图标强制标准化成 16px，在 2 倍视网膜屏上整体发糊；
界面也没有 macOS 27 的设计语言。这个版本用原生控件 + 全矢量 SF Symbols 从根上解决，
并且自带引擎，不依赖系统里装过什么压缩软件。

## 构建与安装

```bash
./package.sh     # 构建 release → 组装 build/PeaZip27.app → 签名 → 启动并验证窗口
./install.sh     # 安装到 /Applications/PeaZip.app（会在桌面备份原版，不删除）
```

两个脚本都会自己先 `swift build`，并在打包后**比对 md5**：曾经因为 bundle 里装了旧二进制，
得出一整套错误的"bundle 起不来窗口"结论，白查了很多轮。装机脚本还会自动验证：
内置引擎可执行、指向的是内置副本而非系统里的 PeaZip、归档往返自测通过。

## 目录

```
Package.swift              构建配置（macOS 15+，见下方"部署目标"）
Sources/PeaZip27/
  PeaZip27App.swift        入口、菜单、Finder 服务、无头自检入口
  AppModel.swift           状态：目录浏览、面包屑、压缩包内导航、服务处理
  ContentView.swift        界面：侧栏 + 原生 Table + 面包屑 + 工具栏
  ArchiveEngine.swift      7z 封装：打包/解压/列目录/包内浏览/安全删除
  SettingsView.swift       设置窗口 6 个标签页
  EngineUpdater.swift      引擎版本检查与自更新
assets/
  AppIcon.icns             应用图标（画布 1024，主体 824，四边留白 100）
  engine/                  内置 7-Zip 引擎源（来自 PeaZip 发布版，20MB，勿删）
  engine/PEAZIP_RELEASE    引擎取自哪个 PeaZip 发布版（更新判断只认它）
tools/
  winlist.swift            不经截图权限查窗口（诊断用）
  service_call.swift       程序化触发 Finder 服务（验证用）
  fix_handlers.swift       审计/修复压缩包类型的默认打开程序
*.sh                       各类验证脚本，见下
```

## 功能

- 原生文件浏览：面包屑、前进后退、搜索、排序、隐藏文件、多选
- **压缩包内浏览**：双击压缩包进包看内容（不再直接解压），包内可逐层进入与解压选中项
- 打包 / 解压 / 解压到新文件夹 / 格式转换 / 完整性测试 / 3 遍覆写安全删除
- Finder 右键「服务」四项：压缩为 ZIP、压缩为 7Z、解压到新文件夹、测试完整性
- 设置：默认格式、压缩级别、**排除规则**（macOS 垃圾 / 隐藏文件 / Windows 冗余 / 自定义）、
  解压后打开、覆写遍数、默认打开程序、引擎更新
- 引擎可自更新：从 PeaZip 官方发布版拉取并替换内置引擎，先验后用、失败回滚

## 验证脚本

无头入口（不依赖点界面）：

```bash
APP=/Applications/PeaZip.app/Contents/MacOS/PeaZip27
$APP --selftest                     # 引擎可用性 + 7Z/ZIP 打包→测试→列表→解压→逐字节比对
$APP --list <压缩包>                # 解析压缩包并展示根目录、下钻一层
$APP --engine-check                 # 检查引擎更新（不下载）
$APP --engine-update                # 强制走完整更新流程
```

其余脚本：`standalone_test.sh`（把原版挪走验证真正独立）、`finder_open_test.sh`、
`finder_zip_test.sh`（访达双击 → 进包）、`exclude_test.sh`（排除规则三档对照）、
`settings_test.sh`（设置是否真的改变行为）、`visible_window_test.sh`（窗口可见性）。

## 几个必须记住的坑

这些都在开发中真实踩过，改动相关代码前先看一眼：

- **部署目标 macOS 15**：`Scene.defaultLaunchBehavior(.presented)` 需要它。这条是"启动必有
  窗口"的保证 —— 配合 `applicationShouldTerminateAfterLastWindowClosed`，一旦恢复流程没交出
  窗口，app 会变成"启动即退出"。`PackageDescription 5.9` 没有 `.v15`，所以写成字符串
  `"15.0"`；不要为此把 swift-tools-version 抬到 6.0（会把语言模式切成 Swift 6）。
- **`NSPortName` 必须等于 `CFBundleName`**，否则 Finder 服务静默不出现。这就是 app 名从
  `PeaZip 27` 改成 `PeaZip` 的原因。
- **手动组装的 bundle 必须声明 `CFBundleDevelopmentRegion`**，否则 AppKit 用英文渲染标准菜单
  （关于/隐藏/退出/编辑/窗口/帮助），而自己的文案是中文，看起来很奇怪。语言由磁盘上的
  `.lproj` 决定，不要再额外声明 `CFBundleLocalizations`（会让语言列表重复）。
- **视图体里绝不做磁盘 I/O**：`~/Desktop`、`~/Documents` 被 TCC 拦会阻塞主线程，窗口永不出现。
  目录列表一律后台预扫 + `@Published`。
- **`deletingLastPathComponent()` 对目录 URL 不缩短路径**，用它拼面包屑会死循环 → 用
  `pathComponents`。
- **`7z l -slt` 的时间戳带小数秒**（`2026-09-16 12:17:56.5280097`），用 `yyyy-MM-dd HH:mm:ss`
  解析会静默返回 nil，整列日期空白。
- **包内条目不能用合成 URL 冒充真文件**：`pathExtension` 会正常解析，包内一个 `x.zip` 会被
  当成真压缩包，然后拿不存在的路径去喂 7z。
- **进包后要让在飞的目录扫描作废**，否则它晚一步返回会把包内列表覆盖成文件夹内容。
- 包装第三方引擎时**记来源发布版的 tag**（不是引擎自己的版本号 —— PeaZip `11.2.0` 里的 7-Zip 是
  `26.02`，两个数字毫无关系）。

更完整的踩坑记录见 `~/.hermes/profiles/forge/skills/software-development/macos-swiftui-app/`。

## 隐私

仓库内不含真实项目名、姓名或业务数据；示例一律用占位名。提交作者统一 `Yww
<yww1996@users.noreply.github.com>`。纯本地仓库，无远端。
