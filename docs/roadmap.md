# 路线图

本文记录 v0.1.0 之后的优先级判断，依据是对同类开源项目的功能对照和本仓库现状的代码审计。每条 P0 都有可验证的验收标准，可以直接拆成 Issue。

## 定位

「个人资料库」不是通用的文档管理系统，而是**给技术人用的本机文档阅读器**：Markdown 标题锚点、`路径:行号` 源码定位、配图归档、按章节记忆阅读位置，这四项 Joplin、FSNotes、Paperless-ngx 都没有。路线图围绕这条护城河扩展，不去竞争扫描件批量归档。

因此优先级只按三件事排：**不敢用（信任）> 找不到（检索）> 进不来（捕获）**。同步和 AI 排在后面。

## 同类项目对照

| 项目 | 核心能力 | 本项目状态 |
| --- | --- | --- |
| [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) | OCR、三维元数据、匹配规则、consume 目录、校验和去重、版本历史、REST API | 全部缺失 |
| [Joplin](https://github.com/laurent22/joplin) | 多端同步与 E2EE、插件、ENEX 导入、冲突处理、层级标签 | 无同步、无插件、无标签 |
| [FSNotes](https://github.com/glushchenko/fsnotes) | 文件夹即库、iCloud/Dropbox、`[[wiki]]`、标签、AES-256、git 备份 | 库为 SQLite 私有格式 |
| [Karakeep](https://github.com/karakeep-app/karakeep) | AI 自动打标、语义检索、图片 OCR、自动化规则、MCP/CLI | 无 AI、无语义检索 |
| [TriliumNext](https://github.com/TriliumNext/Trilium) | 树 + attributes/relations、笔记历史版本、加密、同步 | 单层目录、无历史版本 |
| [SiYuan](https://github.com/siyuan-note/siyuan) | 块级引用与反链、PDF 标注 | 无反向链接、无 PDF 标注 |
| [TagSpaces](https://github.com/tagspaces/tagspaces) | 标签写进文件名或 sidecar、无数据库锁定、浏览器剪藏 | 无剪藏 |
| [docspell](https://github.com/eikek/docspell) | 自动分类器、邮件与扫描仪接入 | 无 |

## P0：信任与检索（1–2 周）

### 1. 回收站与删除撤销

删除目前是硬删除：数据库行连同托管副本、不再被引用的配图一起立即消失（[LibraryRepository.swift:170](../Sources/LibraryCore/LibraryRepository.swift#L170)），误删不可恢复。资料库类产品一次误删就足以失去信任。

- 增加 `deleted_at` 列与回收站视图，默认列表过滤已删除项。
- 回收站保留 30 天，到期由启动时的清理任务物理删除。
- `⌘Z` 撤销删除，恢复时把副本与配图引用一并还原。
- 验收：删除 10 项并撤销后，正文、配图、目录归属、收藏状态与删除前完全一致；删除后 30 天内文件仍存在于 `Files/`。

### 2. 自动备份与恢复向导

[README.md:104](../README.md#L104) 要求用户「先退出 App，再复制整个文件夹」。这是把最容易出错的操作留给用户，而 SQLite 的 WAL 让「只复制 library.sqlite」成为常见的数据损坏来源。

- 每次启动用 SQLite `backup` API 写 `Backups/library-<ISO8601>.sqlite`，保留最近 7 份，轮转删除。
- 设置页增加「立即备份」「打开备份目录」「从备份恢复」。
- 恢复前自动把当前库另存为 `library-before-restore.sqlite`。
- 验收：备份文件能在全新的 `--library-path` 下直接打开并通过完整性检查；恢复流程中止时不改动当前库。

### 3. 列表排序与多条件筛选

列表顺序固定为 `updated_at DESC`（[LibraryStore.swift:198](../Sources/PersonalLibrary/Stores/LibraryStore.swift#L198)），筛选只有类型、收藏、待整理、目录四个维度。

- 排序：更新时间、创建时间、名称、大小，各自可升降序。
- 筛选：日期区间、大小区间、有正文 / 有配图 / 有外部链接。
- 验收：切换排序与筛选只重组内存中已有快照，不重新读取全文；状态在本次运行期间保持。

### 4. 搜索相关性排序

搜索固定以 `updated_at DESC, id` 收尾（[LibraryRepository.swift:411](../Sources/LibraryCore/LibraryRepository.swift#L411)），标题命中与正文命中排在同样位置。

- 使用 FTS5 `bm25()` 排序，标题列加权高于正文列。
- 无 FTS 命中时（短词回退 `LIKE`）保留现有顺序。
- 验收：标题完全匹配的资料排在正文深层命中之前；同一查询两次执行顺序稳定。

### 5. 导入重复检测

README 说明重复导入「保留为独立副本」，但没有任何提示，用户无法判断自己是否已经导入过同一份文件。

- 导入时计算内容 SHA-256，与已有副本比对。
- 命中时提示「已在库中，共 N 个副本」，并提供「仍然导入」与「跳过」。
- 验收：同一文件二次导入会提示；不同文件但同名不会误报。

### 6. 标签系统

标签是笔记类产品最稳定的刚需（Joplin 社区投票第二的诉求是层级标签）。当前只有单层目录，一个资料只能归属一个目录。

- 新增 `tags(id, name)` 与 `item_tags(item_id, tag_id)`，多对多。
- 侧栏标签区、批量打标、`tag:名称` 搜索语法。
- 与目录并存：目录表达「放在哪」，标签表达「是什么」。
- 验收：一份资料可打多个标签；按标签筛选与 `tag:` 搜索返回一致结果；删除标签不删除资料。

### 7. 签名、公证与自动更新

这是获客上最大的漏斗，不是功能问题。当前 ad-hoc 签名、未公证、仅 arm64（[README.md:18](../README.md#L18)），用户首次打开必须右键或执行 `xattr`。

- CI 增加 Developer ID 签名、`notarytool submit --wait`、`stapler`。
- 输出 universal binary（arm64 + x86_64）。
- 接入 Sparkle appcast，以及 Homebrew Cask。
- 验收：从 Releases 下载的 DMG 在未安装过开发构建的机器上双击即可打开，不出现「无法验证开发者」。

### 8. 中文短词检索性能

只有三字及以上查询走 trigram 索引（[LibraryRepository.swift:391](../Sources/LibraryCore/LibraryRepository.swift#L391)），两字中文词回退到 `LIKE '%词%'` 全表扫描，而正文上限 200 万字符（[README.md:122](../README.md#L122)）。「合同」「发票」「周报」这类查询在真实库上会明显变慢。

- 为 CJK 增加 bigram 索引列，或建立 `tokenize='unicode61'` 的第二张 FTS 表。
- 至少在回退路径加耗时日志与词数上限。
- 验收：1 万份资料、平均 2 万字正文的合成库上，两字中文查询 P95 低于 300 ms。

## P1：捕获与检索增强（1–2 月）

| 能力 | 说明 | 现状 |
| --- | --- | --- |
| OCR | Vision `RecognizeTextRequest`（zh-Hans / en，离线），PDF 用 PDFKit 逐页渲染后识别，结果并入 FTS | 图片与扫描件只按文件名搜索 |
| Spotlight 索引 | CoreSpotlight 上报标题与摘要，`⌘Space` 直接搜到资料 | 无 |
| Share Extension / Services | 从 Safari、Finder 一键存入 | 无 |
| App Intents / 快捷指令 | 「保存到资料库」作为动作 | 无 |
| 菜单栏快速捕获 | `MenuBarExtra` + 全局热键，写一条随笔或粘贴剪贴板 | 无 |
| 收件箱目录监听 | FSEvents 监听一个文件夹，新文件自动导入 | 无 |
| 规则自动化 | 「文件名含 X → 归类 + 打标」，确定性规则优先于 AI | 无 |
| 可搬迁导出包 | `.plib`：正文 + 配图 + 元数据 JSON，可独立搬迁 | [README.md:108](../README.md#L108) 明确不提供 |
| 图片查看器 | 缩放、旋转、EXIF | [README.md:130](../README.md#L130) 已列 |
| 阅读位置持久化 | 加 `reading_position` 列，退出后仍记得 | [README.md:128](../README.md#L128) 仅本次运行 |

## P2：差异化（3–6 月）

- **本地 AI（可选、离线）**：macOS 26 的 Foundation Models 做摘要与自动标签，`NLContextualEmbedding` 做语义检索。必须有能力探测、显式开关，并在界面写明不联网。
- **同步**：先定架构。当前「SQLite 为真相 + 托管副本」注定要做记录级冲突合并；更划算的是把真相往文件系统挪（Markdown + sidecar JSON），让 iCloud / Dropbox / git 承担同步。这个决定会反过来影响导出包与 AI 索引，值得先想清楚再动手。
- **PDF 标注与高亮**、**笔记历史版本**、**反向链接**。
- **导入器**：Joplin JEX、Evernote ENEX、Apple Notes、Obsidian vault。
- **MCP server / CLI**：让外部 agent 直接检索资料库。

## 工程优化

- **全量快照**：每次变更都 `SELECT` 全表加全部配图与来源（[LibraryRepository.swift:18](../Sources/LibraryCore/LibraryRepository.swift#L18)），`reload()` 被 8 处调用（[LibraryStore.swift:633](../Sources/PersonalLibrary/Stores/LibraryStore.swift#L633)）。改为按 id 增量 upsert，列表分页或虚拟化。
- **无谓的大字符串拷贝**：搜索结果把整段 `body` 放进 `LibraryItem` 再清空（[LibraryRepository.swift:427](../Sources/LibraryCore/LibraryRepository.swift#L427)），只需 `substr(body, 1, 240)`。
- **FTS 参数**：`detail=none` + trigram 不支持短语与前缀（[Database.swift:55](../Sources/LibraryCore/Database.swift#L55)），按实际库大小评估 `detail=column` 的索引成本。
- **迁移**：`user_version` 为 if 链单条执行（[Database.swift:22](../Sources/LibraryCore/Database.swift#L22)），包进事务并抽出 schema 版本常量。
- **性能基准**：1 千 / 1 万条合成库的导入、搜索、滚动基准，CI 设阈值。
- **仓库治理**：ISSUE / PR 模板、CONTRIBUTING、SECURITY、CHANGELOG、路线图 Projects。
- **国际化**：界面文案抽到 String Catalog，补英文 README。这是 GitHub 增长的基本盘。

## 明确不做

- **自建云同步**：成本远大于收益，先做可搬迁导出。
- **富文本 / 块编辑器**：守住 Markdown 才有差异化。
- **移动端**：先把 Mac 做深。
- **SQLCipher 数据库加密**：拖慢 FTS，FileVault 已覆盖绝大多数场景，等有明确需求再评估。

## 参考

- [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) · [Joplin](https://github.com/laurent22/joplin) · [FSNotes](https://github.com/glushchenko/fsnotes)
- [TagSpaces](https://github.com/tagspaces/tagspaces) · [TriliumNext](https://github.com/TriliumNext/Trilium) · [SiYuan](https://github.com/siyuan-note/siyuan)
- [Karakeep](https://github.com/karakeep-app/karakeep) · [docspell](https://github.com/eikek/docspell) · [Zotero](https://github.com/zotero/zotero)
