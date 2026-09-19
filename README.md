<p align="center">
  <img src="assets/icons/icon.png" width="150" alt="Pure Live 图标"/>
</p>

<h1 align="center">纯粹直播（Pure Live）— 个人学习分支</h1>

<h4 align="center">基于 Flutter 的第三方多平台直播聚合播放器（Windows 桌面版）</h4>

---

## 仓库来源

本仓库 Fork 自开源项目 [liuchuancong/pure_live](https://github.com/liuchuancong/pure_live)，以上游 **v3.1.4** 版本为基线建立分支 [dev_from_v3.1.4](https://github.com/ZXS20240220/pure_live/tree/dev_from_v3.1.4)。

由于上游主仓库后续演进方向与个人需求不同，本分支在其基础上独立维护，主要做了两类工作：

1. **平台聚焦**：仅保留 Windows 桌面平台支持，移除 Android / iOS / macOS / Linux / Web 相关代码与 Firebase 依赖，降低维护成本；
2. **功能移植与修复**：参照开发版dev_20260910分支实现，移植了个人需要的功能，并针对 Windows 桌面使用场景做了交互优化与问题修复（如网页搜索、播放页、窗口交互等）。

完整的修改清单可在应用内查看：**关于页 → 修改总结**。

> 本分支为个人学习用途的私有分支，不接受功能请求，也不建议直接投入生产使用。

## 功能特点

- **多平台聚合**：Bilibili、虎牙、斗鱼、快手、抖音、网易 CC、Twitch、SOOP、YY 等九个平台，以及自定义 M3U / M3U8 直播源；
- **Windows 桌面体验**：键盘快捷键、鼠标滚轮与拖拽操作、侧边栏宽度自由拖拽调整、窗口边缘缩放热区收敛，画面切换无黑闪；
- **播放能力**：直播时移回放、实时录制、定时关闭、多画面同看、ASMR 纯音频模式；
- **弹幕系统**：过滤 / 屏蔽 / 样式 / 速度 / 显示区域等完整配置，斗鱼弹幕显示用户等级与粉丝牌；
- **刷新体系**：平台级并发控制、刷新成功冷却与失败重试间隔双保护（均可配置）；
- **数据管理**：本地备份导出导入、WebDAV 备份、跨设备远程同步（覆盖同步语义，字段结构自动对齐目标端）；
- **账号支持**：Cookie 手动填写与内置浏览器网页自动抓取（抖音 / 虎牙 / 快手 / SOOP / Twitch），抖音与 Twitch 支持登录态校验；
- **网页搜索**：内置 WebView 搜索网页直播间并自动识别跳转。

## 本地构建

本项目仅面向 Windows 桌面平台，请使用匹配 `pubspec.yaml` 中 SDK 约束的 Flutter 版本：

```powershell
flutter pub get
flutter build windows --release
```

构建产物位于 `build/windows/x64/runner/Release/`。

## 免责声明

- 本项目**仅供学习交流与个人使用**，请勿用于任何商业用途；
- 本项目为第三方客户端，本身**不提供、不存储、不上传任何直播内容**，所有内容均来自各公开直播平台的公开接口，版权归原平台及主播所有；
- 使用本项目时请遵守所在地区法律法规及各平台服务条款，因使用本项目产生的一切后果由使用者自行承担；
- 如本项目侵犯您的合法权益，请通过 Issue 或其他方式联系，将及时处理。

## 致谢

- 上游原项目：[liuchuancong/pure_live](https://github.com/liuchuancong/pure_live)
- 代码参考：[dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live)、[pure_live (Jackiu1997)](https://github.com/Jackiu1997/pure_live)
- 以及所有上游贡献者。

本项目沿用上游原项目的开源许可证，详见 [LICENSE](LICENSE)。
