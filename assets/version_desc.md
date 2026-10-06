# 纯粹直播-dev

### 🖥️ Windows 便携版

- **Portable ZIP**：解压即用，无需安装
- 适配：Windows 10/11 x64

### 🔧 Build Metadata

[BUILD_METADATA.json](https://github.com/{repo}/releases/download/{tag}/BUILD_METADATA.json)

### 📝 本次更新

version: 1.0.6 (build 314) [Pre-release]

- 播放页内小窗 (mini PiP) 透明度范围调整、控件保持不透明
- Windows PiP 小窗在调整尺寸时会保持宽高比
- 现在所有的小窗都会根据实际直播画面自动调整窗口比例
- 现在 Windows PiP 小窗观看会计入观看时长 (其他小窗仍不计入)
- 添加窗口置顶功能，支持在播放页切换窗口置顶状态
- 添加自动检查更新模式，支持仅正式版/所有版本/关闭
- 现在可以在关于页中手动检查更新，<关于>更名为<关于与更新>
- 下载更新时的目录可以设置并持久化保存
- 斗鱼 cookie 不再排除 passport 会话字段
- 斗鱼历史 SC 无法保证稳定获取([上游v2.6.0平台边界](https://github.com/liuchuancong/pure_live/blob/master/docs/STAGE_UPDATE_2_6_0.md)曾提及)。**为防止风控等风险，现在不再自动获取斗鱼历史 SC**，只有用户手动刷新 SC 面板时才尝试获取 [需验证]
- 新增斗鱼直播间 SC 进程内本地缓存，退出/切换直播间、手动刷新不会丢失 SC 记录 [需验证]
- (保留了斗鱼 SC 相关的本地日志以供后续验证，若未启用本地日志则无影响)
