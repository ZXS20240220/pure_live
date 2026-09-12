
<p align="center">
  <img src="assets/icons/icon.png" width="150" alt="Pure Live 图标"/>
</p>

<h1 align="center">纯粹直播（Pure Live）</h1>

<h4 align="center">基于 Flutter 的开源多平台直播聚合播放器 · Windows 个人改造分支</h4>

<p align="center">
  A third-party live stream aggregator built with Flutter.
</p>

> ⚠️ **本仓库是个人 fork 学习分支**，非官方发布，**仅针对 Windows 版本**，且**不提供任何 Release 构建物**。源码仅供学习交流，请勿用于商业用途或广泛宣传。

---

## 📌 项目来源与声明

### 原始项目

本项目 fork 自 **[liuchuancong/pure_live](https://github.com/liuchuancong/pure_live)**（[upstream](https://github.com/liuchuancong/pure_live)），主仓库及 Release 分支请以原作者为准。

- **原始仓库地址**：https://github.com/liuchuancong/pure_live
- **本 fork 地址**：https://github.com/ZXS20240220/pure_live
- **当前分支**：`dev_20260910`

### 分支范围

- **目标平台**：本分支所有改动均在 Windows 桌面环境下开发和测试，**iOS / Android / macOS / Linux 未验证**。代码层面使用了少量 `Platform.isWindows` 条件编译（如多实例窗口启动），其他平台编译应能通过，但功能正确性不做任何保证。
- **不提供 Release 构建物**：本仓库**不会在 GitHub Releases 或其他渠道发布任何 `.exe`、`.zip`、`.msix` 等可执行文件**。原因如下：
  1. **个人自用**：分支改造仅服务于自身使用场景，没有打包分发的需求。
  2. **缺少签名证书**：正式签名证书需要专门申请和保管，自签名构建物会触发 Windows Defender SmartScreen 警告，反而误导下载者。
  3. **保持干净**：避免引入与原项目 Release 体系混淆的构建产物。
  4. **学习定位**：发布二进制文件会模糊"学习 / 自用"的边界，违反 AGPL v3 下 fork 分支应明确标注的原则。

> 需要可执行文件的请自行参考原项目的 [本地构建说明](https://github.com/liuchuancong/pure_live#-本地构建与验证) 进行编译，或直接下载 [原项目 Releases](https://github.com/liuchuancong/pure_live/releases)。

### 使用声明

- 本分支的所有改动均**仅作为个人学习和自用目的**，不做任何形式的宣传、推荐或分发。
- 不保证本分支构建产物的稳定性和安全性，使用时请自行承担风险。
- 项目中涉及的第三方直播平台 API 可能随时变化或失效，相关改动仅用于学习研究。
- 如发现本分支存在 License 违规、安全问题或其他不当之处，请及时反馈。

### 参与说明

> 📌 **欢迎贡献维护型修复、测试和文档**！
> - 如发现 License 使用不当，请提交 Issue 或 Pull Request
> - 本仓库 Issue 聚焦可复现 Bug；新增功能和产品建议统一提交到[原项目](https://github.com/liuchuancong/pure_live/issues/new/choose)

---

## 🔧 本分支改动说明（dev_20260910）

以下是相对于原始项目（upstream）在本分支所做的改动汇总。所有改动均在本地工作区完成，commit 历史尚未提交。

### 一、移除 Firebase 用户同步模块

原始项目包含一套完整的 Firebase 邮箱/匿名登录系统，本分支出于**简化依赖、降低构建复杂度和隐私考量**，完整移除了 Firebase 相关功能：

- 删除整个 `lib/modules/auth/` 模块（12 个文件，含控制器、页面、组件、模型、工具类）
- 删除 Firebase 配置文件：
  - `android/app/google-services.json`
  - `ios/Runner/GoogleService-Info.plist`
  - `firebase.json`
  - `lib/firebase_options.dart`
- 清理 `pubspec.yaml` 中的依赖：`firebase_core`、`firebase_auth`、`cloud_firestore`
- 清理 Gradle 配置：`android/app/build.gradle.kts`、`android/settings.gradle.kts`
- 删除 Firebase Windows SDK 预取脚本 `tool/prefetch_windows_native.ps1`
- 更新 macOS / Windows 插件注册文件，移除 Firebase 插件注册
- 清理路由定义（`lib/routes/app_pages.dart`、`lib/routes/route_path.dart`）中的 auth 路由
- 更新 `backup_page.dart`：移除 Firebase 登录/云端备份卡片，保留 WebDAV 和本地备份
- 更新 `MenuButton`：从 `GetView<AuthController>` 改为普通 `StatelessWidget`
- 更新 `initial_services.dart`：移除 `AuthController` 懒加载注册

### 二、LiveRoom 模型增强

在 `lib/common/models/live_room.dart` 中新增三个字段，用于展示更丰富的主播信息：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `anchorLevel` | `String?` | 主播等级（如斗鱼/虎牙的段位等级） |
| `unionName` | `String?` | 主播所属公会名称 |
| `startTime` | `int?` | 当前直播开始时间戳（Unix epoch 秒） |

所有字段均已集成到构造函数、`fromJson`、`copyWith`、`toJson`、`LiveRoomExtension` 合并逻辑中，确保与现有序列化和数据同步机制兼容。

### 三、各站点适配与数据增强

#### 斗鱼直播（Douyu）

- **AI 看点摘要**：新增 `_fetchAiHighlight()` 接口请求斗鱼官方 AI 看点（`/wgapi/vodnc/center/ailive/getHighlightDetail`），结果填充到 `notice` 字段，在 SuperChat 面板顶部以 AI 看点卡片形式展示
- **主播等级**：从 `levelInfo` 解析 `anchorLevel`
- **公会名称**：从 `room_biz_all.clubOrgName` 解析 `unionName`
- **直播开始时间**：从 `show_time` 解析 `startTime`
- **HTML 处理**：`title` 和 `introduction` 通过 `stripHtmlAndUnescape()` 清洗，移除 HTML 标签和解码 HTML 实体
- **空值安全**：修复 `room_biz_all` 可能为 null 导致的空指针异常

#### 虎牙直播（Huya）

- **主播等级**：从 `streamDataGameLiveInfo.level` 解析 `anchorLevel`
- **直播开始时间**：从房间数据 `startTime` 解析
- **notice 字段**：从原先的 introduction 改为空字符串（与斗鱼保持一致，notice 字段预留给 AI 摘要等特殊用途）

#### Bilibili

- **直播开始时间**：从 `room_info.live_start_time` 解析 `startTime`
- **直播间介绍**：`introduction` 优先取 `news_info.content`，两者均通过 `stripHtmlAndUnescape()` 清洗

#### CC 直播 / 快手

- **notice 字段**：统一清空，避免与 introduction 重复显示

### 四、工具函数新增

`lib/core/common/utils/text_util.dart` 新增两个 HTML 处理工具函数：

- `stripHtmlAndUnescape(String input)`：清除 HTML 标签并解码 HTML 实体
  - 例：`"<p>你好&nbsp;<b>世界</b></p>"` → `"你好 世界"`
- `unescapeHtml(String input)`：只解码 HTML 实体，保留原文本结构

新增依赖 `html_unescape` 包（pubspec.yaml 未显式列出，应为已有或隐式依赖）。

### 五、斗鱼 Super Chat 去重修复

`lib/core/danmaku/douyu_danmaku.dart`：

斗鱼在实际付费 Super Chat 推送前会先发一条 `price=0` 的免费预览包，导致去重 Set 因价格不同而失效。修复方案：在 SC 解析时直接跳过 `rawPrice == 0` 的消息。

### 六、直播头部（LivePlayHeader）功能增强

`lib/modules/live_play/widgets/layout/live_play_header.dart` 新增多项 UI 和交互：

- **主播等级徽章**：`Lv.{anchorLevel}` 橙色小徽章显示在主播昵称左侧
- **公会名称标签**：`unionName` 蓝灰色小徽章显示在主播昵称右侧
- **直播时长计时器**：红色圆点 + `HH:MM:SS` / `MM:SS` 格式，每秒刷新，仅对返回 `startTime` 的平台（斗鱼、虎牙、Bilibili）显示
- **介绍 Tooltip**：鼠标悬停主播区域时显示完整介绍
- **快速操作按钮组**（新增 5 个）：
  - 🏷️ 设置房间标签（复用房间卡片标签选择对话框）
  - 🌐 打开直播间（跳转原生平台 APP/H5）
  - 🔄 切换直播间（打开 PlayOther 对话框）
  - 🔗 获取直播直链（通过 `LiveUrlTool`）
  - 🪟 新窗口打开（仅 Windows，复用 `WindowsMultiInstanceLauncher`）

### 七、键盘快捷键重构

`lib/modules/live_play/widgets/keyboard/video_keyboard.dart` —— 从 `CallbackShortcuts` 改为全局 `HardwareKeyboard` 事件处理：

> 原实现使用 `CallbackShortcuts`，但在嵌套 `Focus/FocusScope` 的复杂布局中容易被其他组件抢走键盘焦点。改为监听全局按键事件后，所有快捷键均可正常触发。

**当前支持的快捷键：**

| 按键 | 功能 |
| --- | --- |
| `Space` / 播放键 | 播放 / 暂停 |
| `↑` / `↓` | 音量增减（±0.05） |
| `R` | 刷新直播 |
| `Tab` | 切换弹幕侧栏标签（仅普通窗口模式） |
| `Q` | 切换窗口全屏（非全屏/非小窗时） |
| `Esc` | 退出全屏 / 退出窗口全屏 / 返回（原有逻辑） |

### 八、房间标签设置对话框：自动选中已有标签

`lib/modules/settings/pages/room_card_settings/room_card_controller.dart` —— `showTagSelectionDialog()` 初始化修复：

- **原实现**：`List<String>.from(room.tagIds)` — 直接取房间对象上的 `tagIds` 字段，该字段在很多场景下为空或是旧数据，导致每次打开标签设置对话框时所有复选框都是空的
- **修复后**：`tagController.getTagsForRoom(room)` — 从 `TagManagementController.roomTagsMap` 中查询该房间真实已绑定的标签 ID 列表

效果：打开「设置房间标签/分类」对话框时，该直播间之前勾选过的标签会自动显示为 ✅ 已选中状态，避免每次都要重新勾选一遍。

> 直播头部快速操作按钮组中的 🏷️「设置房间标签」按钮（`LivePlayHeader._buildQuickActions()`）正是调用这个对话框。

### 九、历史与收藏排序增强

#### 置顶标签功能

`lib/modules/tags/tag_management_controller.dart` 新增置顶识别逻辑：

- 预定义置顶关键词：`❤️`、 `❤`、 `♥`、 `♥️`、`置顶`、`特别关注`、`pin`、`vip`
- `pinTagId` getter：返回第一个匹配的用户标签 ID
- `isPinRoom(LiveRoom room)`：判断房间是否带置顶标签

#### 收藏列表排序

`lib/modules/favorite/favorite_controller.dart` —— 在线房间排序优化：

- 新增 `_compareOnlineRooms()` 方法：置顶房间永远排在最前，再按观看人数 / 标签权重排序
- 回放房间单独按观看人数排序，不混入置顶逻辑

#### 历史页面优化

`lib/modules/history/history_page.dart`：

- **仅显示正在直播的房间**（离线房间不再污染历史列表）
- **同步收藏夹最新状态**：从收藏夹中合并 liveStatus/热度等实时数据
- 改用 `showDialog` 替换 `Get.dialog` 实现清空历史确认框

### 十、PlayOther（切换直播间）面板重构

`lib/modules/live_play/dialogs/play_other.dart` —— 抽取可复用组件：

- 原 `PlayOther` 对话框拆分为：
  - `PlayOtherPanel`：可嵌入任意布局的面板组件（支持 `showHeader`、`showCloseButton`、`onSelectRoom` 回调）
  - `PlayOther`：保留为兼容包装器，内部调用 `PlayOtherPanel.buildDialog()`
- 新增功能：
  - 历史清理按钮（🗑️）在历史 Tab 顶部
  - 监听更多 EventBus 事件（`refresh_room_changed`、`history_changed`）实现实时刷新
  - 历史房间同步收藏夹 liveStatus，过滤离线房间

#### 弹幕侧栏嵌入

`lib/modules/live_play/widgets/danmaku/danmaku_tab.dart`：

- 新增第四个 Tab（切换直播间），将 `PlayOtherPanel` 直接嵌入弹幕设置侧栏，方便在观看时快速切换关注的房间

### 十一、Super Chat 面板新增 AI 看点卡片

`lib/modules/live_play/pages/super_chat_page.dart`：

- 新增 `_AiHighlightCard` 组件：解析斗鱼 AI 看点的 `summary` + `describe`，卡片式展示
- 展示位置：Super Chat 列表顶部
- 交互：点击复制全文
- 当 `notice` 为空且没有 SC 消息时，整个页面正常隐藏（保持原有逻辑）

### 十二、EventBus 事件补全

`lib/common/services/settings/history_controller.dart`：

- 在 `addRoomToHistory`、`removeRoomFromHistory`、`removeRoomFromHistoryAt`、`clearHistory` 四个方法中均发出 `history_changed` 事件，供 PlayOtherPanel 等组件监听刷新

---

## 📺 支持平台

Pure Live 聚合多个第三方直播平台，并支持自定义直播源：

- **Bilibili**
- **虎牙直播（Huya）**
- **斗鱼直播（Douyu）**
- **快手（Kuaishou）**
- **抖音（Douyin）**
- **网易 CC 直播**
- **Twitch**
- **SOOP Live**
- **YY Live**
- **自定义 M3U / M3U8 直播源**

支持按照平台、分区等条件进行筛选，也可以隐藏不关注的平台。

### 自定义直播源

支持导入：

- M3U
- M3U8
- 本地直播源
- 网络直播源

可以按照分区、平台和频道进行管理。

---

## 文档

| 文档 | 内容 |
| --- | --- |
| [文档索引](docs/README.md) | 开发、发布、依赖和功能文档入口 |
| [维护范围与问题处置策略](MAINTENANCE_POLICY.md) | 平台支持边界、Issue 分流、Bug 来源判定、上游 Issue 优先级与完成标准 |
| [上游同步审查策略](UPSTREAM_REVIEW_POLICY.md) | 三方差异、语义变更台账、冲突处置与合并门禁 |
| [构建与发布](docs/BUILD_AND_RELEASE.md) | 本机质量门禁、签名、打包和 Release 流程 |
| [Windows 数据与升级](docs/WINDOWS_DATA_AND_UPGRADE.md) | 安装目录存储、关注恢复、换盘迁移和回滚 |
| [Windows MSIX 证书说明](docs/MSIX_INSTALL.md) | 自行构建 MSIX 时的证书指纹核对与安装步骤 |
| [依赖与接口审计](docs/DEPENDENCY_AUDIT.md) | 固定工具链、升级约束和接口探测范围 |
| [平台接口与兼容性](docs/PLATFORM_COMPATIBILITY.md) | 分区、搜索、弹幕和人数指标的当前能力 |
| [高刷新率与性能验证](docs/PERFORMANCE.md) | Android 120 Hz 适配、渲染优化和真机帧统计 |
| [近期 Issue 审计](docs/ISSUE_AUDIT_2026_08_23.md) | #769、#770、#771、#773 与 Windows 高 DPI 问题映射 |
| [参与贡献](CONTRIBUTING.md) | 分支、提交、测试和 Pull Request 要求 |
| [安全策略](SECURITY.md) | 私密漏洞报告和签名材料管理 |
| [版本说明](RELEASE_NOTES.md) | 当前版本变更与历史记录 |

## ✨ 核心功能

### 🎬 多平台直播

- 聚合多个主流直播平台。
- 支持平台分区浏览。
- 支持跨平台搜索。
- 支持直播 / 未开播筛选。
- 支持综合、平台顺序、观众和粉丝等排序方式。
- 各个平台保持独立分页状态。
- 快手保留网页搜索入口。
- 离线频道按照平台接口实际返回结果展示。

### ▶️ 多播放器

Android / Android TV 支持多个播放器：

- IJKPlayer
- EXOPlayer
- MPV Player

当某个播放器出现黑屏、卡顿、硬解兼容性问题或者特定直播流无法播放时，可以在设置中切换播放器。

Windows、Linux、macOS 等桌面平台使用对应平台的播放器实现。

### 🖥️ 多画面同看

- 支持双画面、四画面和一大多小聚焦布局。
- 每格独立播放、暂停、音量、清晰度和线路，只有聚焦画面出声。
- 聚焦画面可接入平台弹幕；快速切换使用最新音频焦点，避免多个画面同时出声。
- 移动端最多同时保留 4 路解码，桌面端最多 9 路，并可让小画面自动使用低清晰度以控制占用。

### 💬 弹幕系统

提供完整的弹幕控制能力：

- 弹幕过滤
- 用户屏蔽
- 关键词屏蔽
- 弹幕描边
- 弹幕透明度
- 字号调整
- 速度调整
- 显示区域调整
- 最大弹幕数量
- 发送间隔控制
- 刷新 FPS
- 平台原始颜色
- 统一弹幕颜色
- 应用界面动态最高刷新率，弹幕渲染智能省电适配
- 弹幕点击与长按操作
- 字体粗细与观看模板联动
- 精确重复和相似文本两级过滤

弹幕系统采用房间会话隔离、平台消息 ID 去重以及过期队列淘汰机制，减少切换直播间后出现：

- 串房弹幕
- 重复弹幕
- 旧弹幕重新出现
- 几分钟前积压弹幕突然播放

### 🪟 小窗弹幕

进入：

**设置 → 视频设置 → 小窗弹幕**

或者在直播间进入：

**弹幕设置**

即可配置小窗弹幕。

支持：

- Android 系统画中画
- Windows 小窗
- 应用内悬浮窗
- 独立弹幕控制器
- 独立弹幕队列
- 独立弹幕样式
- 自动根据窗口尺寸缩放
- 最大弹幕数量
- FPS 调整
- 速度调整
- 显示区域调整
- 弹幕字号和透明度
- 弹幕点击和长按

小窗弹幕不会污染主播放器弹幕队列。

配置会保存到本地，下次进入直播间后继续生效。

"最佳观看"模板默认将弹幕限制在画面顶部约 20% 区域，以减少弹幕对画面的遮挡。

主播放器、小窗以及 Windows 桌面端统一使用 px/s 速度和逻辑帧时钟。

切换横竖屏或者应用从后台恢复时，不会根据后台停留时间产生大量弹幕补跳。

### 📺 高刷新率

Android 支持根据设备显示模式动态适配刷新率：

- 自动监听当前显示模式
- 请求当前分辨率支持的最高刷新率
- 适配 60 Hz / 90 Hz / 120 Hz 等高刷新率设备
- 优化封面图片解码
- 优化图片缓存
- 优化弹幕重绘
- 应用界面跟随设备最高刷新率；自动弹幕主画面 60 FPS、小窗 30 FPS，手动模式最高 240 FPS

---

## 🔍 搜索与直播互动

支持跨平台直播搜索，并提供独立的平台分页状态。平台选择栏可访问屏幕外项目，但首尾严格有界；"全部"搜索按平台完成顺序渐进显示，单个平台超时或失败不会挡住其他结果。

搜索结果支持：

- 综合排序
- 平台顺序
- 观众人数
- 粉丝数量
- 直播状态筛选
- YY 等九个平台原生/本机搜索，快手保留网页搜索
- Bilibili、斗鱼、虎牙、抖音、快手、网易 CC、Twitch、SOOP、YY 网页直播间识别

同时提供本地互动系统。

本地用户与互动数据可以保存：

- 昵称
- 头衔
- 弹幕输入
- 体验币
- 平台身份徽章
- 礼物目录
- 等级风格
- 画面礼物效果

这些数据默认保存在本机。

可以通过：

**设置 → 本地用户与互动**

统一启用或关闭相关功能。

---

## 👀 观看数据

Pure Live 会区分不同平台的观看数据口径：

- 热度
- 真实在线人数
- 累计观看人数

其中：

- 抖音
- 快手
- 网易 CC
- Twitch
- SOOP Live

可以显示平台明确返回的并发人数。

虎牙、Bilibili、斗鱼等平台则按照平台实际提供的热度数据进行展示。

可以通过：

**设置 → 通用 → 观看数据与排行口径**

选择排行方式，并管理支持人数统计的平台。

---

## 🎧 ASMR / 助眠模式

Android 支持 ASMR 助眠模式。

可以设置：

- 新房间自动进入纯音频
- 媒体保活
- 自定义自动停止时间
- 后台持续播放

房间内的耳机图标只控制当前房间的纯音频状态。

电视图标用于投屏。

前台手动进入音频模式时保留同一播放器的视频解码热状态，切回画面通常可直接复用当前纹理；应用进入后台后立即停用视频轨以降低解码和电量开销，回到前台再静默预热。深度恢复期间显示低开销音频卡片和明确进度，不再以黑屏或整页转圈阻塞操作。

当前各平台通常返回音视频复用直播流；关闭视频轨主要节省解码、GPU 与电量，并不等同于只下载音频。只有平台明确提供独立音频地址时，才可能同时实现网络流量显著下降和无等待画面恢复。

---

## ⏺️ 直播录制

支持直播流实时录制。

可以将直播保存到本地，在直播结束后进行回放。

选择自定义位置时，程序只写入该位置下带所有权标记的 `PureLiveRecords` 专用子目录；"清空录制文件目录"和自动容量限制均只处理该目录，不会遍历删除所选父目录中的其他文件。

支持配合：

- 直播录制
- 定时关闭
- 后台音频
- 系统媒体通知

进行长时间观看或助眠使用。

---

## ⏰ 定时关闭

支持设置倒计时自动停止播放或退出应用。

适用于：

- 睡眠
- ASMR
- 长时间观看
- 后台音频播放

---

## 💾 数据管理

支持：

- 本地配置导出
- 本地配置导入
- WebDAV 同步
- WebDAV 备份
- M3U / M3U8 导入
- 配置恢复

备份格式目前为 **v3**。

默认情况下：

- Cookie 不进入普通同步备份
- WebDAV 凭据不进入普通同步备份

旧版本备份文件仍然建议按照敏感文件进行保管。

---

## 📥 下载

前往 [原始项目 GitHub Releases](https://github.com/liuchuancong/pure_live/releases/latest) 获取官方安装包。

> ⚠️ **本分支不发布任何 Release 构建物**（原因见上方"分支范围"说明）。如需自用，请自行参考下方本地构建说明编译。

### Android

当前 Android 正式包以 `arm64-v8a` 为主，适用于当前主流 64 位 ARM 手机和平板。更新页读取版本清单中的实际 ABI 列表，只展示对应 Release 实际发布的下载链接。

Android 始终使用正式包名：

`com.mystyle.purelive`

不再生成并存 QA 包。

正式 Release 使用仓库专用持久签名，因此可以直接覆盖旧的正式版本。

缺少正式发布密钥的本机测试包使用调试签名。

发布脚本会阻止调试签名进入正式 Release。

### Windows

提供：

- Windows x64
- 便携 ZIP
- EXE 安装器

EXE 安装向导支持选择其他磁盘，并把设置、关注、历史、IPTV、录制和缓存集中保存到安装目录 `AppData`。便携 ZIP 不包含运行时数据。

自行构建 MSIX 时的证书配置见 [Windows MSIX 证书说明](docs/MSIX_INSTALL.md)。

### macOS

源码保留 Intel x64、Apple Silicon arm64 与 Universal 构建能力。

### Linux

源码保留 Linux x64 构建能力。Linux 网页搜索会交给系统浏览器，原生搜索与播放继续在应用内完成。

### iOS

源码保留 iOS arm64 设备构建能力。

---

## 🧪 本地构建与验证

项目固定使用 Flutter `3.47.0` / Dart `3.13.0`、AGP `9.3.1`、Gradle `9.5.0` 与 Java 25 构建运行时，Android 应用和插件字节码目标保持 Java/Kotlin 17。

完整质量门禁：

```powershell
PowerShell -ExecutionPolicy Bypass -File .\tool\local_ci.ps1 -Scope Full
```

安装包每次只构建本轮明确指定的一个平台与变体，例如 Android arm64 正式包：

```powershell
PowerShell -ExecutionPolicy Bypass -File .\tool\build_local_release.ps1 `
  -Target AndroidArm64 -Configuration Release -FullRegression -RequireReleaseSigning
```

## 🤝 参与开发

- **主开发者**：[@liuchuancong](https://github.com/liuchuancong)
- **协助开发者**：[@wzgrx](https://github.com/wzgrx/pure_live)
- **协助开发者**：[@RebornQ](https://github.com/RebornQ)

### 代码参考

- [dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live)
- [pure_live (Jackiu1997)](https://github.com/Jackiu1997/pure_live)

---

## 🌟 Star 趋势

如果 Pure Live 对你有帮助，欢迎给原项目一个 ⭐ Star：

## Star History

<a href="https://www.star-history.com/?repos=liuchuancong%2Fpure_live&type=date&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=liuchuancong/pure_live&type=date&theme=dark&legend=bottom-right&sealed_token=7TCHJ1imubZUrHskxy4Fj--g2rclGNfNcTikzBHUf3sq9UyOFMIc2Seh8xnBxICxbcuc33QXSM34ooqO-iEpmwbF9JdlGslt_OSSHpPQqMSWBnOYCZoyWOK7vMh0OxfC9TyY_7cFplT_pTHUNrs3RYVg3GZfjqE1ezf5E9fH7_DTDNxxvD5jUlyqDNpT" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=liuchuancong/pure_live&type=date&legend=bottom-right&sealed_token=7TCHJ1imubZUrHskxy4Fj--g2rclGNfNcTikzBHUf3sq9UyOFMIc2Seh8xnBxICxbcuc33QXSM34ooqO-iEpmwbF9JdlGslt_OSSHpPQqMSWBnOYCZoyWOK7vMh0OxfC9TyY_7cFplT_pTHUNrs3RYVg3GZfjqE1ezf5E9fH7_DTDNxxvD5jUlyqDNpT" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=liuchuancong/pure_live&type=date&legend=bottom-right&sealed_token=7TCHJ1imubZUrHskxy4Fj--g2rclGNfNcTikzBHUf3sq9UyOFMIc2Seh8xnBxICxbcuc33QXSM34ooqO-iEpmwbF9JdlGslt_OSSHpPQqMSWBnOYCZoyWOK7vMh0OxfC9TyY_7cFplT_pTHUNrs3RYVg3GZfjqE1ezf5E9fH7_DTDNxxvD5jUlyqDNpT" />
 </picture>
</a>

---

## ☕ 捐助支持

如果您觉得本项目对您有帮助，欢迎支持**原项目**开发者一杯咖啡 ☕

<p align="center">
  <img src="https://github.com/liuchuancong/pure_live/blob/master/assets/images/wechat.png" width="350" alt="WeChat Donate">
</p>

> 您的支持是原作者持续维护的动力！感谢 ❤️