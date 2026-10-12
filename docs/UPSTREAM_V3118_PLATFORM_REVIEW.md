# 上游 v3.1.18 各直播平台修复与增强盘点

> 基线：本地锚点 `port/upstream-aligned-20260928` → 上游 tag `85c8402d3`（v3.1.18）
> 共 437 个提交，本盘点聚焦**平台相关**改动，按"结构性变化 → 分平台修复 → 跨平台通用修复 → 本地对照与摘取建议"组织。

---

## 一、结构性变化（影响全部站点的契约重构）

v3.1.18 最核心的变化不是单个站点的修 bug，而是**全站接口契约的 room-first 收敛**。

### 1. `getRoomDetail` 参数对 → `getRoomDetailForRoom(LiveRoom)`

上游把所有站点的 `getRoomDetail({required String roomId, required String platform})` 全部替换为以 `LiveRoom` 为首参的 `getRoomDetailForRoom(LiveRoom room, {bool refresh = false})`，并删除了旧的 pair 签名与死代码 `getLiveStatus`。

- 本地现状：`lib/core/interface/live_site.dart:222` 仍是 `getRoomDetail({roomId, platform})`，48 个站点适配器全部走旧签名。
- 影响：这是**摘取上游任何平台修复的前置障碍**——上游所有站点 diff 都基于新签名，直接 cherry-pick 会编译失败。
- 策略：要么先做一次"契约对齐"批量迁移（大手术），要么摘取单站修复时手动把签名改回本地 pair 形式（逐站小手术）。

### 2. 目录分层重构

上游把站点适配器从 `lib/core/site/<platform>/` 拆成了 `lib/shared/platforms/<platform>/` + `lib/domains/live/` 两层，同时新增 `lib/domains/recorder/`、`lib/domains/live/data/stream/` 等领域层。本地仍是扁平的 `lib/core/site/` 结构。

### 3. `LiveRoom` 字段扩充

新增/强化了 `httpHeaders`、`streamFacts`（`format`/`codec`/`unresolvedChildren`）、`sourceQueryPolicies` 等播放传输声明字段，为后续"按源属性下发"和"子清单强制走中继"铺路。

---

## 二、分平台修复与增强清单

下表按平台列出 v3.1.18 中可识别的平台级改动。"本地状态"标注本地是否已覆盖。

### 斗鱼 (douyu)
| 提交 | 改动 | 本地状态 |
|---|---|---|
| ③（计划已列） | 登出状态 / 播放参数修复 | 摘取计划中 |

### 虎牙 (huya)
| 提交 | 改动 | 本地状态 |
|---|---|---|
| ④（计划已列） | 搜索与分组树补 `User-Agent`（否则 403） | 摘取计划中 |

### Steam 广播 (steambroadcast)
| 提交 | 改动 | 本地状态 |
|---|---|---|
| `321f184a9` | **CDN 按请求 IP 亲和，代理出口分片 410**：播放与上游中继对 `*.steamcontent.com` 强制直连（`playsDirectBehindProxy`） | ❌ 本地未覆盖，`PlaybackProxyPolicy` 无此规则 |
| `6c29c7047` | **mpv 网络栈读该 CDN 确定性挂死**（清单能读、分片打开后 18s 无进展，代理与直连都复现）：声明 `unresolvedChildren: true`，线路走回环清单中继（与 TwitCasting 同一机制） | ❌ 本地未覆盖 |

### 微博 (weibo)
| 提交 | 改动 | 本地状态 |
|---|---|---|
| `960bcf7e3` | **房间声明媒体播放请求头**：weibo CDN 对缺 Referer/UA 的连接不吐数据，表现为"opened but never played"。UA 用完整桌面串（裸 `Mozilla/5.0` 被部分边缘节点当异常客户端） | ❌ 本地 weibo 未声明 `httpHeaders` |

### FC2 Live
| 提交 | 改动 | 本地状态 |
|---|---|---|
| `14d965326` | **FFmpeg 中继携带 `l_ortkn` 会话 Cookie**：修复录制分片 403。`Fc2ControlSession` 新增 `sessionCookie` 字段，中继启动时追加 `-headers 'Cookie: l_ortkn=...'` | ❌ 本地 `Fc2HlsInput` 未携带会话 Cookie |

### 六间房 (sixroom)
| 提交 | 改动 | 本地状态 |
|---|---|---|
| `462f9b45c` | **弹幕服务器列表接口谎报 mime**：`getChat.php` 回 `Content-Type: text/html` 但体是 JSON，dio 的 `getJson` 返回 String，`_refreshServers` 判 `is Map` 恒为假 → 服务器列表永远空 → 弹幕永远"连接失败，正在重试"。改为按文本取、`parseChatServers(String)` 自己解码 | ❌ 本地 `six_room_danmaku.dart` 用 `getJson` + `is Map` 判断，存在同样缺陷 |

### 猫耳 FM (missevan)
| 提交 | 改动 | 本地状态 |
|---|---|---|
| `ee6bf4c9a` | **游客会话 Cookie 读取崩溃**：猫耳一次下发两个 `Set-Cookie`（`FM_SESS` 与 `FM_SESS.sig`），dio 的 `headers.value()` 在多于一个同名值时抛异常，三次重试全吃掉 → "拿不到游客会话" → 弹幕握手 403。改为遍历整组头 | ❌ 本地 `missevan_danmaku.dart` 仍用 `headers.value('set-cookie')`，存在同样缺陷 |

### 小红书 (xiaohongshu)
| 提交 | 改动 | 本地状态 |
|---|---|---|
| `6229284a8` | **分享文案整段粘贴可开直播间**：从"文字+链接+文字"里抽 URL（`extractUrls`），支持 `/o/` 前缀短链（之前只认 `/m/`），剪掉尾部句点 | ❌ 本地 `xiaohongshu_link.dart` 只认纯链接或裸房间号 |

### Bigo
| 提交 | 改动 | 本地状态 |
|---|---|---|
| `21e981da5` | 登录墙房间正确提示"需要登录"而非"重试" | 需核对 |
| 系列 | 完整浏览器头、登录态 token/cookie 持久化 | 需核对 |

### 17LIVE / AcFun / Bigo / 六间房 / 等（4.x 功能回流）
| 提交 | 改动 |
|---|---|
| `df2b67b71` | seventeenlive、acfun：摘取 4.x 的链接主机、搜索关键词与"全部分区" |
| `3e5a99b7d` | bigo、sixroom：摘取 4.x 的封面截图与搜索卡片状态 |
| `531bcae87` | liveme、showroom、fc2live：摘取 4.x 的未开播状态与观众数口径 |
| `5e26c6933` | weibo、steambroadcast：摘取 4.x 的快照状态与头像规则 |

### 其余平台
- **twitcasting**：走回环清单中继（上游已有的机制，v3.1.18 中与 Steam 统一）

---

## 二·补、弹幕/聊天引擎（17 站全部到齐）

v3.1.18 补齐了最后一批站点的弹幕/聊天引擎移植，至此 **17 个站点全部到齐**。每个引擎对应上游 M5.x 模块编号：

| # | 站点 | 提交 | 上游模块 | 备注 |
|---|---|---|---|---|
| 1 | **AcFun** | `fb8e2179b` + `2541b88ed` + `7c2d9e2ba` | M5.9 / M4.10 | 三段式：站点层访客会话与票据 → 字段级 protobuf 读写器 → 帧编解码与会话打通 |
| 2 | **TwitCasting** | `0da5eb77b` | M5.11 | 评论引擎 |
| 3 | **LOOK** | `47f7600c5` + `1fc235baf` | M5.28 | 两段式：聊天服务器地址与参数 → socket.io 0.9 引擎 |
| 4 | **Chzzk** | `d19148937` | M5.16 | 聊天引擎 |
| 5 | **Bigo** | `fabe51c1e` | M5.20 | 聊天引擎 |
| 6 | **Showroom** | `2fdc1d613` | M5.15 | 评论引擎 |
| 7 | **Picarto** | `c3a9d9bd2` | M5.10 + B-8 | 聊天引擎 |
| 8 | **Panda** | `d1590cbbc` | M5.21 | 聊天引擎 |
| 9 | **FC2** | `521812ae3` | M5.22 | 评论引擎 |
| 10 | **Steam** | `e89c0c6fb` | M5.23 | 聊天引擎 |
| 11 | **JD** | `b58eb0a17` | M5.24 | 聊天引擎 |
| 12 | **酷狗** | `2958e35a5` | M5.25 | 聊天引擎——**此提交标志全部 17 站到齐** |
| 13 | **六间房** | `4c5483159` | M5.27 | 聊天引擎 |
| 14 | **十七 Live** | `ba7c5d0bb` | M5.29 + B-14 | 聊天引擎（Ably 实时协议） |
| 15 | **MissEvan** | `25d2000be` | M5.12 + B-1/B-9 | 聊天引擎（Brotli 二进制帧） |
| 16 | **KilaKila** | `a46b2e502` | M5.13 + B-10 | 聊天引擎（Socket.IO 2 over Engine.IO 3） |
| 17 | **百度直播** | `1990e1243` | M5.26 | 轮询消息列表 |

> 用户提到的 16 个站名 + "等"，实际是 17 个站（多出百度直播）。

### 弹幕设置页

| 提交 | 改动 |
|---|---|
| `7ef95314e` | **新增弹幕设置页及相关功能** |
| `94ced49d7` | 删除小窗弹幕独立配置，合并进主弹幕设置 + 比例系数 |
| `2d2ad2039` | 弹幕 flame_barrage 缺失配置 + tap-to-hold 按住定住弹幕 |
| `7fc88e3c4` | 同步 flame_barrage 配置面到设置页 |
| `d629b8b78` | `hideDanmaku` 成为唯一显示开关，删除 `enableDanmakuDisplay`/`enablePipDanmaku` |
| `a4eeb7adb` / `873344eb5` / `2ee3ee8fd` | 小窗/画中画弹幕补"距顶部/底部"内边距、比例只做缩小、设置真正生效 |

### Twitch 事件与消息撤回

| 提交 | 改动 |
|---|---|
| `b554dd2b7` | **USERNOTICE 订阅/续费/赠送/突袭/公告进弹幕区**（上游 B-7 倾斜 3） |
| `7c8b7f599` | **CLEARMSG/CLEARCHAT 撤回**；并修好按用户撤回从不命中 |
| `22f659782` | Cookie 失效时给用户提示并改用匿名 |

### 弹幕显示层增强

| 提交 | 改动 |
|---|---|
| `43540cc10` | `LiveMessage.emotes` 与 `LiveEmote`（消息里的表情图片）数据模型 |
| `f587c26a3` / `c4699764d` | 弹幕渲染/列表渲染消息自带的表情图片 |
| `9fb1ef1da` | Bilibili 解析聊天里的付费与内联表情 |
| `a7783b525` | 弹幕海量模式 |

### 本地对照

本地当前弹幕引擎覆盖情况需逐站核对 `lib/core/site/<platform>/` 下的 `*_danmaku.dart`。从提交信息看，上游这 17 个引擎是 v3.1.18 这一轮集中补齐的，本地锚点在 v3.1.17 之前，大概率**大部分缺失**。弹幕设置页（`7ef95314e`）和 Twitch 撤回/事件（`b554dd2b7`/`7c8b7f599`）也需确认本地是否已有。

---

## 三、跨平台 / 通用修复（影响多个站点）

### 1. ⭐ 播放请求头被丢弃（7 个站，本地影响 16+ 个站）

**提交 `73aeb5931`** —— `PlaybackHeaderResolver.resolve` 的 `default` 分支原本返回空表，导致**声明了 `httpHeaders` 却不在 switch 里的站点，CDN 一个请求头都收不到**。mpv 日志就是 `http-header-fields=[]`。

- 上游受影响：looklive、jdlive、baidulive、sixroom、kugoulive、fc2live、steambroadcast
- **本地受影响（更多）**：本地 switch 覆盖的站点集合与上游不同，经核对 `httpHeaders:` 声明与 switch case，本地至少有 **16 个站**落在 default 分支被丢头：
  zhanqi、vkvideolive、taobaolive、steambroadcast、sixroom、shopeelive、rumble、nimotv、looklive、langlive、kugoulive、jdlive、goodgame、fc2live、dailymotion、baidulive
- 修复：`default: headers = roomHeaders;`（透传房间声明，因为只有站点自己知道该用哪个 id 拼 Referer）

> 这是**摘取价值最高、风险最低**的单条修复：一行改动，修复 16 个站的播放头丢失。配合 weibo 的 `httpHeaders` 声明一起摘取效果最佳。

### 2. 网络层：代理证书信任 / FC2 API 直连
- `e2fe28aab`：代理开启时信任代理证书
- `ce44ab6c7`：FC2 API 请求直连绕过应用代理，修复 FC2 Live transport 错误

### 3. media_core 报错诚实度
- staged 播放器期间只订阅错误事件，"打开就失败"的 CDN 404 不再被误报为"流卡住（position frozen at 0ms for 8s）"
- `player_handle_adapter.dart` 日志报的 `recoveryEnabled` 改为句柄上真正生效的开关

### 4. 录制器修复
- 主播下播无限重试修复
- 空分段合并修复
- FC2 录制携带会话 Cookie（见上）

---

## 四、本地对照与摘取建议

### 摘取优先级（高 → 低）

| 优先级 | 修复 | 理由 | 摘取难度 |
|---|---|---|---|
| 🔴 P0 | `73aeb5931` PlaybackHeaderResolver default 透传 roomHeaders | 一行修复 16 个站的请求头丢失，本地 bug 完全一致 | 极低（1 行） |
| 🔴 P0 | `960bcf7e3` weibo 声明 playHeaders | 修复 weibo "opened but never played"，依赖 P0 那条一起生效 | 低 |
| 🟠 P1 | `462f9b45c` sixroom 弹幕 mime 修复 | 本地同样缺陷，弹幕从未连上 | 中（需适配本地文件结构） |
| 🟠 P1 | `ee6bf4c9a` missevan Set-Cookie 多值修复 | 本地同样缺陷，游客会话拿不到 | 中 |
| 🟠 P1 | `6229284a8` xhs 分享文案解析 | 用户体验增强 | 低 |
| 🟡 P2 | `14d965326` FC2 录制携带会话 Cookie | 修复录制分片 403 | 中 |
| 🟡 P2 | `321f184a9` + `6c29c7047` Steam 代理直连 + 回环中继 | 修复 Steam 在代理环境下的播放/录制 | 中（涉及传输层） |
| 🟢 P3 | huya 搜索 UA / douyu 登出修复 | 已在摘取计划 ③④ | — |
| ⚪ P4 | 4.x 功能回流（封面、分区、观众口径） | 增强项，非修复 | 高（量大） |

### 核心阻碍

**room-first 契约重构**是摘取任何上游站点修复的前置障碍。上游 diff 全部基于 `getRoomDetailForRoom(LiveRoom)`，本地仍是 `getRoomDetail({roomId, platform})`。

- **P0 两条（header resolver + weibo）不涉及站点详情签名**，可直接摘取。
- P1/P2 的弹幕/录制修复需要核对本地对应文件，手动适配签名差异。
- 若要系统性摘取，建议先做一次契约对齐迁移。

---

## 五、核对用文件清单

- `docs/_v3118_commits.txt` —— v3.1.17→v3.1.18 全量 437 提交
- `docs/_v3118_platform_commits.txt` —— 平台相关提交（UTF-8）
- `docs/_v3118_key_fixes.diff` —— 8 个关键修复的完整 diff
- `docs/UPSTREAM_CHERRY_PICK_PLAN_2026_10_08.md` —— 摘取计划锚点