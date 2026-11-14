# 应用自动更新与发布

应用更新来自本仓库 Releases，与 PeaZip 上游的“引擎更新”是两个入口。
Sparkle 2.10.1 负责检查、下载、签名校验、替换与重启。默认每天自动检查，
不会静默安装；用户可在设置 → 通用关闭自动检查，也可从 PeaZip 菜单手动检查。
压缩、解压及引擎更新期间，推迟安装重启至任务完成。

## 一次性签名配置

`assets/updates/Info.plist` 仅包含公钥、HTTPS feed 地址与更新偏好。
私钥绝不能提交或上传为 Release 附件。已有版本发布后必须保留同一私钥，
否则已安装版本无法验证后续更新。

推荐使用 Sparkle 自带的钥匙串工具（首次配置一次）：

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account peazip-macos
```

如环境不能访问钥匙串，可运行 `swift tools/create-update-key.swift`。
它在 `.update-signing/ed25519.private-key` 创建一个权限为 600 的本地私钥，
输出的公钥用于 `SUPublicEDKey`。已有文件会复用，绝不覆盖。
`.update-signing/` 已加入 gitignore。请在密码管理器等安全位置备份私钥。
有钥匙串权限时可导入，之后发布不必指定文件：

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account peazip-macos \
  -f .update-signing/ed25519.private-key
```

## 每次发布

1. 修改 `package.sh` 中的显示版本及严格递增的 `CFBundleVersion`；更新
   `assets/updates/release-notes.md` 和 README 版本。
2. `swift test`，再运行 `bash tools/prepare-release.sh`。使用本地密钥时：

```sh
SPARKLE_PRIVATE_KEY_FILE="$PWD/.update-signing/ed25519.private-key" \
  bash tools/prepare-release.sh
```

脚本会打包生产 app，嵌入 Sparkle.framework（保留软链接与权限），校验签名，
运行引擎自检，产出 `build/release/PeaZip-版本.zip`、`appcast.xml`、`SHA256SUMS`。
发布用生产标识始终是 `com.yww.pea27`，不会把开发标识安装给用户。
ZIP 与 feed 都经 Ed25519 签名。脚本还会用 app 内嵌公钥独立验签，
避免误用另一把私钥发布一个用户无法安装的版本。

框架顶层链接会在签名前由 `normalize-framework-links.sh` 从
`Versions/Current/...` 改为直接指向实际版本目录（如 `Versions/B/...`），
避免 7z 的“经另一链接访问目标”保护拦截安装包中的链式链接。
发布脚本会用内置 7z 重新解压 ZIP，并再次验证助手和整个 app 的代码签名。
不要通过关闭 7z 的链接安全检查来处理此问题。

Feed 保留 `<sparkle:informationalUpdate><sparkle:belowVersion>44`：
41–43 的检查更新只提供手动下载入口，避免调用这些版本中可能已经损坏的助手。
44 及以后继续正常应用内下载安装。后续发布不要删除这个旧版恢复规则。

3. 将 ZIP、appcast.xml、SHA256SUMS 上传至同一个 GitHub Release，设为最新稳定版。
   标签必须是 `v显示版本`（例如 `v0.41`），以匹配 appcast 中的下载地址。
   可以先创建草稿进行检查，检查后再发布：

```sh
gh release create v0.41 build/release/PeaZip-0.41.zip \
  build/release/appcast.xml build/release/SHA256SUMS \
  --draft --title 'PeaZip 0.41' --notes-file assets/updates/release-notes.md
gh release edit v0.41 --draft=false --latest
```

feed 固定为 `https://github.com/Yww1996/peazip-macos/releases/latest/download/appcast.xml`。
每个后续稳定 Release 都必须携带 appcast.xml；不要只上传 ZIP。
更改任何已签名的 ZIP 或 XML 后，必须重新运行发布脚本。
首次安装 0.41 仍需手动替换，后续版本才可在 app 内更新。

## 验证与当前分发限制

测试包含任务忙碌时延迟安装、任务结束后只恢复一次，以及后续任务再次延迟。
发布脚本包含归档往返自检、包内公钥验签、feed 验签。
`HEADLESS_PACKAGE=1 bash package.sh` 可用于没有图形会话的打包环境，
不会启动 app 或结束已安装 app 的进程；普通打包仍保留窗口验证。

项目沿用 ad-hoc 代码签名，未配置 Apple Developer ID 与公证。
Ed25519 用于确认更新来自同一个发布者，不等同于 Apple 公证。
