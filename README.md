# 个人资料库

[![CI](https://github.com/longyinpro-design/personal-library/actions/workflows/ci.yml/badge.svg)](https://github.com/longyinpro-design/personal-library/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/longyinpro-design/personal-library?display_name=tag)](https://github.com/longyinpro-design/personal-library/releases)

原生 macOS 个人资料管理 App，使用 SwiftUI、SQLite 和系统预览服务。资料保存在本机，无账户或云服务；MarkdownUI 随 App 编译打包，无需另外安装阅读工具。

## 下载

从 [Releases](https://github.com/longyinpro-design/personal-library/releases) 下载最新的 `PersonalLibrary-*-macos-arm64.dmg` 和对应的 `.sha256` 校验文件，两者放在同一目录后执行：

```sh
shasum -a 256 -c PersonalLibrary-*.dmg.sha256
```

打开 DMG，将「个人资料库.app」拖入 Applications。当前提供 Apple 芯片（arm64）构建，需要 macOS 14 或更高版本。

构建使用 ad-hoc 签名，未经过 Apple 公证。首次启动如提示「无法验证开发者」，请右键点击 App 选择「打开」，或执行 `xattr -dr com.apple.quarantine "/Applications/个人资料库.app"`。

## 功能

- 多选导入或拖入文件，保存独立副本，保留源文件。
- 搜索标题和可提取正文，支持中文子串、多关键词、大小写及重音不敏感匹配；三字及以上查询使用 SQLite FTS5 trigram 索引，短词回退子串匹配。
- 正文在打开资料时按需读取，列表与搜索只携带标题、摘要和元数据，不再把全库正文载入内存。
- 按文档、笔记、随笔、图片和其他格式筛选，查看正文与系统文件预览。
- 列表可按更新时间、创建时间、名称（自然排序）或大小升降序排列；筛选支持创建日期区间、大小区间，以及「有正文 / 有配图 / 有外部链接」三个内容条件。排序与筛选只重排内存里已有的快照，不重新读取正文，并在本次运行期间随切换目录保持。
- 新建、编辑笔记与随笔；显式保存，并可导出 Markdown。
- Markdown 文件、笔记与随笔支持格式化阅读：标题、列表、任务清单、引用、表格、代码块、网页和本地文档链接；可切换查看原文，代码可横向滚动与复制。
- Markdown 可显示本地 PNG/JPEG 等位图和自包含 SVG，支持相对路径、`../`、绝对路径及本机 `file://` 地址；新导入会将引用图片复制进资料库，笔记可通过「图片目录…」指定来源并保存配图。
- 收藏资料、创建逻辑目录、将资料归入目录、查看最近 200 条整理记录。
- 列表支持多选，可批量收藏、整理归类或删除；删除先移到回收站（保留 30 天，`⌘Z` 撤销或从回收站恢复），彻底删除才会移除资料库内的副本与不再被引用的配图，原始文件始终保留在原位置。
- 长文档可在文内查找，逐个跳到命中位置并高亮；Markdown 提供按层级缩进的目录，点击标题跳转。
- 记住每份资料的阅读位置，切回或重新选中时回到上次停留的章节或段落。
- 快捷键：`⌘N` 新建笔记，`⇧⌘N` 写随笔，`⌘O` 导入，`⌘F` 搜索，`⌘⌥F` 在文中查找，编辑器中 `⌘S` 保存；`⌘[` 返回、`⌘]` 前进。

搜索范围是左侧当前分类；选择「全部资料」搜索整个资料库。「最近添加」显示最近导入或创建的 50 项。逻辑目录不会改变源文件目录。重复导入同一份文件会先按内容 SHA-256 比对并提示（已有的副本数量），可以选择仍然导入或跳过；同名但内容不同的文件不会被误判为重复。导入在后台复制文件并提取正文，可继续切换目录、搜索和选择资料。收藏与归类会就地更新列表，不重新读取全库。

搜索入口位于顶部工具栏，`⌘F` 聚焦搜索；在「整理记录」输入搜索词会转到「全部资料」。资料列表支持方向键选择；按住 `⌘` 或 `⇧` 点击可多选，列表底部会出现批量操作栏，右键菜单与 `⌫` 同样作用于所选资料。列表获得焦点后，回车与双击执行相同主操作：笔记/随笔进入编辑器，文档交给系统默认应用打开。

Markdown 阅读不改变保存的正文。网页链接可在浏览器打开；相对路径、绝对路径及本机 `file://` 链接优先打开资料库内已导入的对应副本，未导入的普通文件使用只读预览。块图片和行内图片均从本地读取，不自动下载网络图片；缺失、无法读取或不支持的图片会显示提示或占位图标。原始 HTML 和 Mermaid 不作为网页执行。独立成段的 AMI `/imgstart:文件名:imgend/` 标记可读取当前目录及向上三层内的 `images/` 配图，代码示例中的标记保持原样。

Markdown 支持 `#标题`、`文件.md#标题`、中文标题和重复标题（后续同名标题使用 `-1`、`-2` 后缀）。标题中的标点按 GitHub 风格移除，空白转为 `-`；同时接受手册原有的标题拼写。列表或引用块内的标题定位到包含它的章节。AMI 手册的 `index.html#doc-…` 入口会按原目录和语言定位到对应 Markdown；不会用同名文件猜测目标。链接目标已在当前搜索结果中时保留目录、查询和类型筛选；否则进入目标所属目录，未归类目标进入待整理。返回/前进按钮恢复先前资料、搜索词和筛选范围。

导入时保存来源文件的完整路径身份，已导入文档之间的链接在原目录移动或整库搬迁后继续可用。多个副本使用同一来源路径时会提示版本歧义；缺失文件、缺失标题和不支持的链接类型会明确报错。未导入文件需仍在原位置；要跳到其中的 Markdown 标题，先导入该文件。

Markdown 中的 `文件路径:行号` 和 `文件路径:行号:列号` 可打开只读文本预览，滚动到目标行并选中相应文本；相对路径、绝对路径、本机 `file://` 及 `README:12` 这类无扩展名路径均支持。行号与列号从 1 开始，列按 Unicode 字符计数。已导入目标优先读取库内副本，未导入目标读取当前本地文件。每次预览最多 8 MiB，支持 UTF-8 和带 BOM 的 UTF-16；文件缺失、超限、非文本及位置越界会明确提示。文件名中需保留字面冒号时可写为 `%3A`。

导入 Markdown 时会扫描完整原文件的图片引用，将本地配图复制到资料库；相同内容的图片共享副本，原文与原图保留。阅读优先使用已保存副本，原目录移动后仍可显示。已有文档可点击「保存配图」补齐尚未归档的引用。

笔记保存时复制新增引用，并保留已有图片副本。相对路径以原文目录为起点，尚未指定目录的笔记可点击「图片目录…」选择；重新选择目录会尝试更新已有配图，失败时保留已存副本并提示。

## 运行

编译目标为 macOS 14+，使用 Swift Package Manager 构建。首次构建会获取锁定版本的 MarkdownUI 2.4.1 及其传递依赖，版本记录在 `Package.resolved`，许可见 [third-party-notices.md](docs/third-party-notices.md)。

```sh
./script/build_and_run.sh           # 构建并打开 App
./script/build_and_run.sh --build   # 只构建 .app
./script/build_and_run.sh --test    # Swift Testing 自动验证
./script/build_and_run.sh --verify  # 构建、启动并检查进程
```

默认使用项目内的 `.build` 构建，App 输出到 `.build/app/个人资料库.app`。如本机安装了 `agent-storage`，脚本会自动把构建缓存和测试临时数据路由到外置卷；可用 `PERSONAL_LIBRARY_USE_AGENT_STORAGE=0` 强制使用默认路径。

在部分 Command Line Tools 组合下，脚本会加载已安装 Xcode 的 SwiftUI 宏插件；若插件不存在会明确失败。

本地脚本产出的是 ad-hoc 签名的开发构建，不会安装到 Applications。嵌套沙箱环境（如部分 CI 或 agent 容器）若禁止 SwiftPM 自身的沙箱，可用 `PERSONAL_LIBRARY_SWIFTPM_SANDBOX=0` 关闭它。

## 发布

推送 `v*` 标签会触发 Release 工作流：构建 `.app`、打包 DMG、生成 SHA-256，创建附带这两个文件的 GitHub Release，并在结束前重新下载附件复核校验和。

```sh
git tag -a v0.1.0 -m "个人资料库 v0.1.0"
git push origin v0.1.0
```

标签使用 annotated tag，版本号取自标签名去掉前缀 `v`，并写入 `.app` 的 `CFBundleShortVersionString`。如需对已有标签重新构建并覆盖发布，在 Actions 中手动运行 Release 工作流并填入标签名：

```sh
gh workflow run release.yml -f tag=v0.1.0
```

也可以本地打包（不发布）：

```sh
./script/package_dmg.sh 0.1.0
```

产物位于 `dist/`，版本号也可通过 `PERSONAL_LIBRARY_VERSION` 指定。

## 数据与备份

默认资料库在 `~/Library/Application Support/PersonalLibrary/`：

```text
PersonalLibrary/
  library.sqlite       # 笔记正文、文件元数据、提取正文、目录、收藏、记录
  library.sqlite-wal   # 运行中的 SQLite WAL（若存在）
  library.sqlite-shm   # 运行中的共享状态（若存在）
  Files/               # 导入文件的托管副本
  Attachments/         # 按内容保存的 Markdown 图片副本，引用关系在数据库中
```

备份由 App 自己做：每天首次打开资料库时用 SQLite 的 `VACUUM INTO` 写一份 `Backups/library-<日期>-<时间>.sqlite`，保留最近 7 份。设置页提供「立即备份」「打开备份目录」「从备份恢复…」。恢复会先校验备份（`PRAGMA integrity_check`、表结构、版本），再把文件暂存起来，下次启动时替换数据库，当前库另存为 `library-before-restore.sqlite`；选错或中途取消都不会改动正在使用的资料库。

备份只包含数据库（笔记、正文、目录、活动记录与搜索索引，以及标题里的配图引用）。`Files/` 里的导入副本和 `Attachments/` 里的图片不在备份内——需要连同文件一起迁移时，退出 App 后复制整个 `PersonalLibrary` 文件夹。设置页可以打开存储目录，笔记也可以单独导出为 Markdown。

已归档的 Markdown 配图包含在完整资料库备份中，不再需要原目录。引用映射使用库内相对路径，整库搬迁后按新的资料库位置读取。

「打开文件」与单独导出 Markdown 保留原始正文和引用，不打包配图；这两个入口尚不提供可独立搬迁的文档包。

测试可用 `--library-path /absolute/path` 启动独立资料库，或设置 `PERSONAL_LIBRARY_HOME`；默认库不自动导入演示内容。

## 格式与边界

| 类型 | 第一版行为 |
| --- | --- |
| PDF | 提取文字层；加密或扫描件显示具体提示 |
| DOCX / DOC / RTF / ODT | 使用系统 `textutil` 提取；15 秒超时后保留文件并提示 |
| TXT / Markdown / 常见代码与配置文件 | 支持 UTF-8 和带 BOM 的 UTF-16 |
| 图片 | 按文件名搜索，使用系统预览；无 OCR |
| 其他格式 | 保留文件，按文件名搜索，预览能力由 macOS 决定 |

每个文件最大 200 MB；正文最多提取 200 万字符，达到上限会显示提示，文件副本保留完整。正文是导入时的快照；原文件或托管副本在外部修改后不会自动更新搜索内容。搜索由 SQLite FTS5 索引加速，三字以下查询回退到子串扫描；正文按需读取。首次打开旧版资料库时会建立一次搜索索引，通常只需数秒。

长正文按段落分块、Markdown 按章节惰性排版，切换资料时只排版可见部分；正文分块内的文本选择以块为单位，需要整段复制时可打开原文件。搜索命中后的详情仍显示命中摘录。收藏、归类只更新对应记录，不重新载入全部正文。

在文中查找（`⌘⌥F`）显示命中序号与命中行摘录，回车或按钮跳到下一个，`Esc` 关闭。纯文本按段落块定位并高亮命中词；Markdown 由渲染视图排版，命中按章节定位，摘录说明命中所在的正文。查找只覆盖当前打开的资料，不改变保存的正文。

Markdown 的「目录」按钮列出全部标题并按层级缩进，点击即跳到对应章节；列表或引用块内的标题定位到包含它的章节。阅读位置按章节（Markdown）或段落块（纯文本）记忆：切换资料、返回前进或重新选中时回到上次停留的位置，跳转链接与搜索命中优先。位置只在本次运行期间保留，退出 App 后重新从头开始。

Markdown 配图后台解码，展示缩略图最长边 2,048 像素；每个配图副本最大 32 MiB，SVG 显示最大 2 MiB，原图尺寸最多 1 亿像素。SVG 必须自包含，外部资源、脚本、动画、DTD/实体等内容不加载。动画位图按首帧显示；尚未实现图片放大查看或配图打包导出。

标签支持批量打标、按标签筛选与 `tag:名称` 搜索；删除标签不删资料。检索栏左侧可排序与筛选。暂未实现 OCR、云同步、AI 分类、后台目录监听、目录层级。删除操作先移到回收站，30 天后自动清理，期间不修改原始文件。

## 代码结构

- `Sources/LibraryCore`：数据模型、SQLite、文本提取、串行 repository actor。
- `Sources/PersonalLibrary`：App 生命周期、界面状态、三栏视图、编辑器与预览。
- `Tests/`：LibraryCore 与 App 层自动化测试。
- `script/build_and_run.sh`：构建、打包、启动入口；可选外置存储路由。
- `script/package_dmg.sh`：生成 DMG 与 SHA-256 校验文件。
- `script/search-benchmark.py`：合成 1 万份资料测两字中文查询的耗时，可复现搜索性能。
- `.github/workflows/ci.yml`：push 与 PR 的构建、测试工作流。
- `.github/workflows/release.yml`：`v*` 标签构建 DMG 并发布 Release。
- `docs/third-party-notices.md`：第三方依赖与素材许可。

## 设计参考

实现前查阅了 [TagSpaces](https://github.com/tagspaces/tagspaces)、[Joplin 架构](https://joplinapp.org/help/dev/spec/architecture/)及 [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx)。TagSpaces 的文件管理模型最接近参考图；Joplin 的笔记模型和[中文搜索边界](https://joplinapp.org/help/apps/search/)有参考价值；Paperless-ngx 的服务部署形态比本版桌面需求更重。仅借鉴产品模型，没有复制这些项目的代码。

## 许可证

本项目以 [MIT](LICENSE) 许可发布。第三方依赖与素材的许可见 [docs/third-party-notices.md](docs/third-party-notices.md)。
