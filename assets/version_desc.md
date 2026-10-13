# 纯粹直播-dev

### 🖥️ Windows 便携版

- **Portable ZIP**：解压即用，无需安装
- 适配：Windows 10/11 x64

### 🔧 Build Metadata

[BUILD_METADATA.json](https://github.com/{repo}/releases/download/{tag}/BUILD_METADATA.json)

### 📝 本次更新

**version: 1.0.10 (build 314) [Pre-release]**

- 修复虎牙直播偶发性 40s 周期性刷新(根因来自上游移植的虎牙反风控随机 UA，已回退)
- 修复虎牙录播无法播放的问题，并添加相关测试(录播观看功能并不完善)
- 沉浸模式顶栏增加退出程序按钮，去除获取直链按钮
- 现在直播间侧栏的最大宽度会根据窗口宽度实时调整
- 现在窗口尺寸过小时，直播间不会触发紧凑模式`MobileLayout`了
- 抖音 IP 属地添加至悬浮卡片
- 补充播放页 tooltip 鼠标悬浮信息
- CTRL 打开的悬浮直播窗，现在不会在后台残留
- ❌暂不考虑增加录制视频播放功能(可能涉及到的问题较多)
- (斗鱼历史 SC 状态继续待验证)
