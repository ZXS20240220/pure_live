# 壁纸功能完整实现计划

> 生成日期：2026-10-09
> 上游基线：正式 release `v3.1.18` `lib/domains/wallpaper/`
> 实施路径：路径 C —— 仿 multiview 直接使用 media_kit 原生 API + 封装服务

## 一、功能范围（对齐上游 v3.1.18）

上游 `lib/domains/wallpaper/` 共 23 个文件，覆盖 4 种数据源：

| 数据源       | 说明                  | 优先级 |
| ------------ | --------------------- | ------ |
| 本地静态图片 | 用户选择本地图片文件  | P0     |
| 在线图片     | itab API 在线壁纸图库 | P1     |
| 预设壁纸     | 内置精选壁纸          | P1     |
| 视频壁纸     | 本地/在线视频循环播放 | P2     |

**全局显示**：壁纸作为根 Widget 背景，所有页面均可见，前景 UI 透明化。

## 二、模块结构设计

```
lib/modules/wallpaper/
├── controllers/
│   └── wallpaper_settings_controller.dart    # 设置控制器（持久化 + 业务逻辑）
├── services/
│   ├── video_wallpaper_player.dart           # 视频壁纸播放器（独立 media_kit 实例）
│   └── wallpaper_coordinator.dart            # 壁纸与直播播放器的生命周期协调
├── data/
│   ├── wallpaper_models.dart                 # 数据模型（WallpaperType, WallpaperItem 等）
│   ├── wallpaper_repository.dart             # 壁纸数据仓库（本地/在线/预设）
│   └── itab_wallpaper_api.dart               # itab 在线壁纸 API
├── widgets/
│   ├── app_background.dart                   # 根背景层（静态/视频/纯色）
│   └── wallpaper_preview.dart                # 壁纸预览组件
└── pages/
    ├── wallpaper_settings_page.dart          # 壁纸设置页
    ├── online_wallpaper_page.dart            # 在线壁纸图库页
    └── preset_wallpaper_page.dart            # 预设壁纸选择页
```

## 三、数据模型设计

### 3.1 壁纸类型枚举

```dart
enum WallpaperType {
  none,        // 无壁纸（纯色/默认背景）
  imageLocal,  // 本地图片
  imageOnline, // 在线图片
  imagePreset, // 预设图片
  videoLocal,  // 本地视频
  videoOnline, // 在线视频
}
```

### 3.2 壁纸项模型

```dart
class WallpaperItem {
  final String id;
  final WallpaperType type;
  final String url;           // 本地路径或在线 URL
  final String? thumbnail;    // 缩略图 URL（在线壁纸用）
  final String? name;         // 壁纸名称
  final Map<String, String>? headers;  // 在线资源请求头
}
```

## 四、设置控制器设计

### 4.1 `WallpaperSettingsController` 字段

```dart
class WallpaperSettingsController extends GetxController {
  final RxBool enabled = hiveBool('wallpaperEnabled', false);
  final RxString wallpaperTypeName = hiveString('wallpaperType', WallpaperType.none.name);
  final RxString wallpaperSource = hiveString('wallpaperSource', '');
  final RxInt fitIndex = hiveInt('wallpaperFitIndex', 0);
  final RxDouble maskOpacity = hiveDouble('wallpaperMaskOpacity', 0.3);
  final RxDouble blurRadius = hiveDouble('wallpaperBlurRadius', 0.0);
  final RxDouble videoVolume = hiveDouble('wallpaperVideoVolume', 0.0);
  final RxBool videoLoop = hiveBool('wallpaperVideoLoop', true);
  final RxBool pauseVideoWhenLivePlaying = hiveBool('wallpaperPauseOnLive', true);
  final RxString itabCategory = hiveString('wallpaperItabCategory', 'anime');
  final RxList<String> recentOnlineWallpapers = hiveStringList('wallpaperRecentOnline', []);
}
```

### 4.2 备份序列化（对齐 `ThemeSettingsController` 模式）

实现 `toJson` / `parseConfig` / `fromJson` / `extractConfig` / `mergeConfig`。

## 五、视频壁纸播放器（路径 C 核心）

`VideoWallpaperPlayer extends GetxService`，直接使用 `media_kit` 原生 `Player` + `VideoController`：

- **不调用** `MediaKitAdapter.applyNativeLiveProperties`（直播属性不适合壁纸）
- 设置 `loop=inf`、`cache=yes`、`hwdec=auto`、`vo=gpu`
- 默认静音，与直播播放器完全隔离（独立 mpv 实例）

## 六、根 Widget 集成（全局显示）

`AppBackground` 放在 `GetMaterialApp.builder` 的 Stack 底层，用 `IgnorePointer` 包裹不拦截点击。

## 七、与直播播放器的生命周期协调

`WallpaperCoordinator` 订阅 `PlayerManager.onPlaying` 流：

- 直播开始 → `videoPlayer.pause()`（释放解码帧，保留纹理）
- 直播结束 → `videoPlayer.resume()`

## 八、Mica 效果冲突处理

壁纸激活时 `Window.setEffect(effect: WindowEffect.disabled)`，关闭时恢复 `WindowEffect.mica`。

## 九、在线壁纸 API（itab）

使用项目现有 `dio` 实例，复用 `networkImageHeaders` 处理 CDN 防盗链。

## 十、设置页面 UI

参照 `theme_settings_page.dart` 的 `buildModernCard` + `buildTile` 模式。

## 十一、备份系统集成

参照 `panelSize` 条件式导入模式，**无需 bump `backupVersion`**：

- `exportAllSettings` 添加 `'wallpaper'`
- `_sectionKeys` 注册 wallpaper 段
- `parsers` 添加 `WallpaperSettingsController.parseConfig`
- `_importV2` / `_importV2Partial` 条件式导入

## 十二、`SettingsService` 注册

```dart
WallpaperSettingsController get wallpaper => Get.find<WallpaperSettingsController>();
Get.lazyPut(() => WallpaperSettingsController(), fenix: true);
Get.lazyPut(() => VideoWallpaperPlayer(), fenix: true);
Get.lazyPut(() => WallpaperCoordinator(), fenix: true);
```

## 十三、实施步骤（按优先级）

### 阶段 1：基础框架（P0）

1. 创建 `wallpaper_models.dart`
2. 创建 `WallpaperSettingsController`
3. 在 `SettingsService` 注册控制器
4. 创建 `wallpaper_settings_page.dart` UI（静态壁纸部分）
5. 注册面包屑导航
6. 创建 `AppBackground` 组件，集成到 `main.dart`
7. 本地图片壁纸功能

### 阶段 2：视频壁纸（P2 核心）

8. 创建 `VideoWallpaperPlayer` 服务
9. 视频壁纸渲染集成到 `AppBackground`
10. 本地视频选择功能
11. 循环播放、音量控制

### 阶段 3：协调与冲突处理（P1）

12. 创建 `WallpaperCoordinator`
13. Mica 效果冲突处理
14. 遮罩 + 模糊效果
15. 填充方式适配

### 阶段 4：在线与预设壁纸（P1）

16. 创建 `ItabWallpaperApi`
17. 在线壁纸图库页
18. 预设壁纸
19. 在线壁纸请求头处理

### 阶段 5：备份与收尾（P0）

20. `backup_controller.dart` 集成
21. `_sectionKeys` 注册
22. 验证备份往返

### 阶段 6：优化与边缘处理（P2）

23. 视频壁纸错误回退
24. 内存管理
25. 性能优化
26. i18n 翻译条目

## 十四、关键风险与对策

| 风险                          | 对策                                        |
| ----------------------------- | ------------------------------------------- |
| 全局透明导致文字不可读        | 强制遮罩层默认 0.3 不透明度，用户可调       |
| 视频壁纸与直播双解码 GPU 过载 | 直播播放时自动暂停壁纸解码（默认开）        |
| Mica 与壁纸冲突               | 壁纸激活时禁用 Mica                         |
| 视频解码失败黑屏              | 监听 error 流，回退纯色背景 + Toast         |
| 在线壁纸 CDN 防盗链           | 复用`networkImageHeaders`                 |
| 大内存占用                    | 限制图片尺寸，视频限制 1080p                |
| 循环播放闪烁                  | 使用 mpv`loop=inf`                        |
| 鼠标事件被拦截                | `AppBackground` 用 `IgnorePointer` 包裹 |

## 十五、文件清单

**新建文件（11 个）**：

1. `lib/modules/wallpaper/data/wallpaper_models.dart`
2. `lib/modules/wallpaper/controllers/wallpaper_settings_controller.dart`
3. `lib/modules/wallpaper/services/video_wallpaper_player.dart`
4. `lib/modules/wallpaper/services/wallpaper_coordinator.dart`
5. `lib/modules/wallpaper/data/wallpaper_repository.dart`
6. `lib/modules/wallpaper/data/itab_wallpaper_api.dart`
7. `lib/modules/wallpaper/widgets/app_background.dart`
8. `lib/modules/wallpaper/widgets/wallpaper_preview.dart`
9. `lib/modules/wallpaper/pages/wallpaper_settings_page.dart`
10. `lib/modules/wallpaper/pages/online_wallpaper_page.dart`
11. `lib/modules/wallpaper/pages/preset_wallpaper_page.dart`

**修改文件（5 个）**：

1. `lib/main.dart` — 集成 `AppBackground`
2. `lib/common/services/settings_service.dart` — 注册控制器
3. `lib/common/services/settings/backup_controller.dart` — 备份集成
4. `lib/modules/settings/settings_breadcrumb.dart` — 面包屑注册
5. `lib/modules/settings/settings_page.dart` — 设置页入口

## 十六、依赖确认

所有依赖均已存在于 `pubspec.yaml`，无需新增：

- `file_picker: ^12.0.0`
- `cached_network_image: ^4.0.0`
- `media_kit` + `media_kit_video`
- `dio`
- `hive_ce`
- `flutter_acrylic`

## 十七、验证清单

- [ ] 静态本地壁纸正常显示，填充方式正确
- [ ] 视频壁纸循环播放无闪烁，默认静音
- [ ] 直播开始时视频壁纸自动暂停，直播结束后恢复
- [ ] 壁纸激活时 Mica 自动禁用，关闭后恢复
- [ ] 遮罩/模糊效果可调且不影响交互
- [ ] 壁纸设置可正常备份导出与导入恢复
- [ ] 旧备份（无 wallpaper 段）导入不报错
- [ ] 壁纸层不拦截鼠标点击
- [ ] 切换壁纸类型时旧资源正确释放
- [ ] 视频解码失败时优雅回退
