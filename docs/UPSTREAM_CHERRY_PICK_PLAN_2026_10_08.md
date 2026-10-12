# 上游摘取计划（锚定 v3.1.18，不迁移 media_core）

> 生成日期：2026-10-08
> 上游基线：正式 release `v3.1.18`（tag `85c8402d3`），media_core pin `5b04714`
> 本地锚点：`port/upstream-aligned-20260928`
> 前提：不影响现有正常功能、不引入新 bug、不迁移 media_core、不引入 Firebase、Windows + 单 mpv。
> 结论：下列各项**均不依赖 media_core**，可在现有架构独立摘取；本地所需的第三方依赖均已存在，无需新增依赖。

## 已舍弃项（经评估价值过低）

- **各站开播时间补齐**：本地 `LiveRoom.startTime`（int 秒级）已覆盖 B站/抖音/斗鱼/虎牙 4 个主流平台，且关注页已有完整显示与排序 UI；上游覆盖 11 站但**没有任何 UI**。剩余增量只是补全冷门海外站，价值低，舍弃。
- **受限直播原因（付费/私密/密码/封禁等）**：上游新增 `LiveRestriction` 枚举 + 逐站检测，但唯一消费点是进不去时的一句提示，房间列表不显示；逐站检测易误判（把能播的房误标为付费/私密），自建站无上游参考。投入产出比低，舍弃。

---

## 录制问题澄清（重点）

**结论：这不是"上游重构导致差异巨大"，而是上游修了两个老 bug，而这两个 bug 在本地代码里同样存在。** 差异大的观感来自本地录制器本身是重度自研超集（HLS spool/prefetch、FLV relay、lease 租约、分段时钟 segment clock、attempt 前缀分段、graceful stop 等，见 `lib/recorder/` 与 `docs/RECORDER_*` 审计文档），文件比上游多得多；但出问题的这两处策略逻辑，本地和上游修前是同一套写法——属于共同祖先遗留、上游后来修复、本地尚未跟进。因此只需移植"修复逻辑"，不需要移植上游的文件结构。

### Bug A：主播下播后无限快速重试

- **本地位置**：`lib/recorder/services/recorder_continuation_policy.dart:81`
  ```dart
  static bool shouldEnterPollingAfterRetryLimit({..., required bool unexpectedEof}) {
    if (unexpectedEof) return false;   // ← EOF 永不进离线轮询
    return retryCount >= maximumRetries.clamp(1, 100);
  }
  ```
- **调用链**：`recorder_controller.dart:1202 _scheduleReconnect` 中，EOF 走 `fast: true`，`task.retryCount` 虽持续累加（:1204），但因上面恒返回 false，**永远停在 2~15 秒的快速重试循环**（`reconnectDelay` 对 EOF 固定 base=2/max=15），每次重新 resolve 到已 404 的签名 URL，并不断产生 0 字节分段，永不转入 `waitingLive` 慢速离线轮询。
- **触发场景**：主播下播 → 服务端关流产生 unexpected EOF（EOF 本身不能证明是下播还是网络抖动，所以原作者对它豁免了上限——这是设计初衷，但缺少"长期 EOF 应判定下播"的出口）。
- **上游修法（commit `2b9ffc7a`）**：EOF 快速重试也设上限（`2 * maxRetries`），用尽后转入离线轮询（任务保留，等主播再开播，不再敲打 CDN）。
- **本地修复要点**：给 EOF 路径一个独立的、有限的快速重试预算（建议沿用 `2 * maximumRetries`），超过后同样进入 `_schedulePoll` 的离线轮询。改 `shouldEnterPollingAfterRetryLimit` 的判断即可，`retryCount` 已在累加，无需改计数结构。

### Bug B：合并遇到 0 字节分段直接整体失败

- **本地位置**：`lib/recorder/services/video_processor_service.dart:169-171`

  ```dart
  for (final segment in segments) {
    if (await segment.length() <= 0) throw const FormatException('Recording clock empty segment');
  }
  ```

  抛出后在 :178-182 被捕获 → `_emitFailed(recorder_segment_clock_failed)`，**整个合并失败**（即使已有很多有效分段）。
- **与上游差异（关键，不能照抄）**：本地比上游多了一层 **RecordingSegmentClock 分段时钟/journal 校验**（记录每段时长与时间戳，零 inpoint 契约）。上游的简单做法是"直接过滤掉 0 字节段，全空才报错"；本地若简单删段，会导致时钟 journal 的段数/时长对不上，仍可能校验失败。
- **本地修复要点**：过滤 0 字节/已消失分段时，**必须与时钟计算保持一致**——先剔除无效段，再用"仅有效段"重建/读取 segment clock 与 concat 清单；只要至少有一个有效段就正常合并；全部为空才明确报错（新增 i18n，如 `recorder_no_valid_segments`），而不是抛"段时钟校验失败"。需要先读懂 `RecordingSegmentClock.read/toConcatManifest` 的段索引与时长模型，避免破坏时钟严格性（这是本地刻意的硬化，见 :166-168 注释）。

### 录制项的风险与验证

- **难度 3/5，风险中高**。文件是自研超集，**不能 cherry-pick，只能移植逻辑**。
- 关键是区分"真下播 EOF"与"网络抖动 EOF"：快速重试预算要足够覆盖短暂抖动（2×上限通常足够），避免把暂时断流误判为下播而过早进入慢速轮询。
- 必须用真实"主播下播"场景端到端验证：①下播后停止刷 CDN、任务进入等待；②重新开播能自动续录；③重试期间产生的空段不影响最终合并出可播放视频。

---

## 摘取清单（按执行顺序）

### 第一梯队：低风险快赢

#### ③ 斗鱼登出清除整段会话 —— 难度 0.5/5

- 现状：登出按钮 `lib/modules/account/douyu/douyu_cookie_controller.dart:96` 只清 `douyuCookie`，残留 `douyuLtp0`（长期续期密钥）、`douyuDid`、`douyuCookieSavedAt`，且会随"含敏感数据"备份导出。仅"清除全部 cookie"才清这 4 项。
- 做法：参照上游 `bbb23e521`，在 `cookie_settings_controller.dart` 加 `clearDouyuSession()`（一次清 4 字段），`clearAllCookies()` 复用，登出按钮改调它。注意本地多一个 `taobaoCookie`，勿误删。
- 风险：纯凭据卫生，不影响在用会话，几乎零风险。

#### ④ 虎牙搜索/分组补 UA —— 难度 0.5/5

- 现状：`lib/core/site/huya/huya_site.dart` 的 `getSubCategores`(:174)、`searchRooms`(:944)、`searchAnchors`(:996) 三处请求未带 UA，接口回 403 "Not allowed"。
- 做法：三处补 `headers: {'User-Agent': kUserAgent}`（用文件内既有常量，与上游同一字符串）。参照上游 `ac69fc2c1`。
- 风险：加请求头不会让现有请求变差；实测虎牙搜索与分区树。

#### ⑨ 弹幕海量模式 + 字间距 —— 难度 1/5

- 现状：本地 flame_barrage 是**本地 fork**（`plugins/flame_barrage`），已支持 `letterSpacing`（barrage_config/engine/mixed_layout 等 4 文件），字间距近乎白送；只缺海量模式。
- 做法：
  - 海量模式：弹幕设置 controller 加 `danmakuMassMode`（存储键可沿用上游 `danmakuRealtimeMode`，默认 false）+ `effectiveMaxVisibleCount`（开→1000，否则读现有 `danmakuMaxVisibleCount`），主画面弹幕渲染处改读该 getter，设置页加开关。
  - 字间距：controller 加 `danmakuLetterSpacing`（-2~8，默认 0），设置页加滑杆并透传给 barrage config。
- 约束：只动主画面弹幕；**完整保留本地约 14 项小窗/PiP 独立弹幕配置**（上游已删，本地保留）。默认关闭海量模式。

### 第二梯队：小而独立

#### ⑦ Windows SMTC 系统媒体控制 —— 难度 2/5（需真机实测）

- 现状：基础设施已就位——`pubspec.yaml` 已有 `audio_service 0.18.18` + `audio_service_win 0.0.3`；已有 `lib/player/core/live_audio_handler.dart`（BaseAudioHandler，play/pause/stop 齐备）与 `live_audio_service.dart`（`start()` 已构造 MediaItem），`player_manager.dart:342` 进房已调用。
- 未生效原因：`live_audio_service.dart` 的 `start()` 开头 `if (!isMobile && !isMacOS) return;`，`bind()` 的 handler 初始化也限 mobile/macOS，Windows 直接返回，从不初始化/推送。
- 做法：对 Windows 放开这两处平台门控；确认 Windows 下 handler 的 play/pause/stop 正确路由到播放器命令；进房推 MediaItem、状态变化同步 `playing`。Android 通知/音频焦点逻辑继续用平台判断隔离。
- 风险：确认 audio_service_win **不改变关窗退出/后台保活行为**（本地有独立 background playback 策略）。需真机验证：多媒体键、任务栏音量面板卡片、切房标题更新。

#### ⑥ 设备同步回退"设备端实时审批" —— 难度 2.5/5（安全敏感）

- 现状：本地 `lib/modules/backup/remote_receiver/` 为强制 6 位配对码（`pairingCodesMatch` + `x-purelive-pairing` 头）。官方 v3.1.18 **有意删除配对码**（协议注释 "gone on purpose"），改为接收端弹窗审批，否则官方端不再发码会被本地 403 拒绝，形成协议孤岛。
- 新机制：任何 export/import 请求到达 → 接收端弹 AlertDialog（动作 + 来源 IP）→ 人点同意才执行，否则 403 "Rejected on the device"；回调未挂载/异常/超时一律拒绝（fail-closed）；旧二维码 `code` 参数忽略，新旧码都能扫；分段勾选 sections 保留。
- 做法（映射到旧目录，参照 release `lib/features/remote_receiver/`）：
  1. `remote_sync_protocol.dart`：QR 只编 host:port；解析兼容并忽略旧 `code`。
  2. `remote_sync_service.dart`：删服务端 `pairingCodesMatch`，改为 `Future<bool> Function(String action, String remoteIp)? confirmRequest`；`_handleSettings` 对 GET/POST 先 `await confirm(...)`，false→403；**回调为 null 必须返回 false**。
  3. `remote_sync_page.dart`：挂 `confirmRequest`，弹审批框。
  4. 完整保留本地独有 `remote_sync_data_merger` / `remote_sync_preview_page` / `remote_sync_json_tree`（与鉴权正交）。
- 风险（最高优先级）：安全路径必须 fail-closed。双向测：同意能同步、拒绝/超时 403、旧码二维码可扫。

### 第三梯队：敏感模块

#### ⑤ 录制：下播无限重试 + 空分段 —— 见上文"录制问题澄清"专节，难度 3/5。

### 第四梯队：最大块，建议拆子步骤

#### ⑩ 播放器内核设置（精简版） —— 难度 3.5/5

- 现状：本地已有 vo/ao/hwdec 选择器、`customPlayerOutput`、`enableCodec`、RTX VSR 开关；`lib/player/adapters/media_kit_adapter.dart` 有成熟 `native.setProperty` 接缝（:75-124 开流时设置；:572 已验证可运行时切 hwdec）。缺：`videoSync/interpolation/scale/deinterlace/hwdecCodecs`、一键预设、Anime4K、选项中文释义、部分项运行时生效。
- 参考：上游 `mpv_option_labels.dart`（词表/释义）、`player_preset.dart`（预设配方）、`core/player/super_resolution.dart` + `assets/shaders/Anime4K_*.glsl`（Kazumi 同款）。
- 拆 4 个子提交：
  1. 五个 mpv 选项字段 + 释义 UI。对直播真正有用：`scale`（放大锐化）、`hwdec-codecs`（限制哪些编码硬解，排障）；`video-sync/interpolation`（补帧，电影向）与 `deinterlace`（隔行信号，直播无用）放高级折叠区或不做。
  2. 弱网 / 低延迟两个直播预设（只取 balanced + 这两个，跳过 Android compat 与弱机 lowEnd；RTX 已有独立开关）。弱网 `cache-secs 120 / demuxer-readahead-secs 30 / reconnect*`；低延迟 `cache no / readahead 1 / 前向丢帧`。在本地 `lib/player/utils/live_buffer_policy.dart` 上扩展。
  3. Anime4K：拷入 GLSL 着色器资源，开关设置 mpv `glsl-shaders`（按上游挂载顺序），关闭清空；默认关、标注吃 GPU。
  4. 运行时生效（可选最后做）：scale/glsl-shaders 可实时 set；**vo/ao 保持"下次开流生效"**更稳。保守起见 1-3 步可全部走开流时应用。
- 风险：错误选项可能黑屏/无声，每项提供 auto 恢复档兜底；Anime4K 需在 `pubspec.yaml` 登记 shader 资源（仅加 assets 声明、不加依赖，由用户本人改并 `pub get`）。与取流/relay 无关，改动集中在设置 controller + 设置页 + adapter setProperty。
- 补充：做设置界面 UI 相关改动时，不需要像上游一样每个设置项都做独立的页面，对于MPV高级设置中的各项可以做成弹窗式的选项

### 暂缓项

#### ⑧ 壁纸/动态壁纸 —— 难度 4/5，价值最低，暂缓

- `domains/wallpaper/` 23 个 dart 文件（数据源/仓库/图库多页/itab 在线 API/媒体存储/预设）+ `background_controller` + 根层 `app_background.dart`，还要改 `main.dart` 根 widget（Navigator 后垫背景、页面透明化），并带"壁纸与直播流不共用解码器"的交接逻辑。
- 唯一侵入根 widget/主题层的功能，透明处理不当影响全局观感；在线壁纸引入新网络 API。纯装饰性，与前 8 项无依赖。将来如要做，作为独立 additive 模块 + 总开关默认关闭，单独安排验证。

---

## 执行顺序与统一收尾

```
第1批  ③斗鱼登出 → ④虎牙UA → ⑨弹幕海量/字间距
第2批  ⑦SMTC放开 → ⑥同步回退审批
第3批  ⑤录制重试/空分段（敏感，单独提交，真机端到端验证）
第4批  ⑩播放内核设置（4 个子提交）
暂缓   ⑧壁纸
已舍弃 ①开播时间补齐、②受限直播原因
```

每项收尾：`flutter analyze` 无问题 → 按各节风险清单真机/实功能验证 → 单独提交（信息标注对应上游 commit hash）→ 全部完成后打新对齐 tag + 备份分支。

需用户介入：⑩ Anime4K 需本人在 pubspec 加 shader 资源声明并 `pub get`；⑤⑥⑦⑩ 不做构建验证，由用户在真机完成验证。全程不执行 build/run，不自动改 pubspec。

## 上游提交对照

| 项                 | 上游 commit                                                                                          |
| ------------------ | ---------------------------------------------------------------------------------------------------- |
| ③ 斗鱼登出        | `bbb23e521`                                                                                        |
| ④ 虎牙 UA         | `ac69fc2c1`                                                                                        |
| ⑤ 录制重试/空分段 | `2b9ffc7a`                                                                                         |
| ⑥ 同步审批化      | v3.1.18`lib/features/remote_receiver/`（配对码 "gone on purpose"）                                 |
| ⑦ SMTC            | v3.1.18`player_kernel_service.dart`（MediaSessionBootstrap）                                       |
| ⑨ 弹幕海量/字间距 | v3.1.18`danmaku_settings_controller.dart`（键 `danmakuRealtimeMode` / `danmakuLetterSpacing`） |
| ⑩ 播放设置        | v3.1.18`mpv_option_labels.dart` / `player_preset.dart` / `super_resolution.dart`               |
| ⑧ 壁纸            | v3.1.18`lib/domains/wallpaper/`                                                                    |
