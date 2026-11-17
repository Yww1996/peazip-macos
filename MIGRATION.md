# Zuno 更名说明

Zuno 是原 peazip-macos 原生 macOS 前端的延续。原 GitHub 仓库直接更名为 `Yww1996/zuno`，保留提交历史、标签、问题与 Releases，不另建无关仓库。

- 应用显示名称、可执行文件、安装包与访达服务名称改为 Zuno。
- Bundle Identifier 仍为 `com.yww.pea27`，设置键、SwiftPM 内部模块与更新签名密钥保持不变。
- 引擎仍来自 PeaZip 上游发布版，来源记录与第三方许可保留。这是独立前端项目。
- GitHub 旧仓库地址由 GitHub 重定向至新地址。不要重新创建同名 `peazip-macos` 仓库，否则会破坏重定向。

## 旧版升级

0.44 及以后版本可继续通过原更新地址获取更新；0.43 及以前使用手动下载入口。
Sparkle 更新后可能保留原来的外层 `PeaZip.app` 文件名，菜单和服务显示 Zuno。需要统一文件名时，退出软件后将同一应用改名为 `Zuno.app`，或安装新包并移走同一标识的旧副本，避免注册两份相同服务。

`install.sh` 先构建并校验新包，再备份和替换同一标识的旧安装；旧安装放入 `~/Library/Application Support/Zuno/Install Backups/`。不同标识的上游 PeaZip 保持原位。此脚本需要对“应用程序”目录具有写入权限。

应用标识保持不变有助于延续设置和文件关联；系统仍可能根据签名、路径与本机策略重新要求文件访问权限。
