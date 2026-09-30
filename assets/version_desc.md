version: 1.0.2 (build 314)
- 新增斗鱼 Cookie 自动获取功能，支持剔除风控字段并补充 passport 域 Cookie 查询
- 将各平台账号行的点击事件改为打开 Cookie 编辑
- add webview reload and devtools to cookie capture page
- 优化斗鱼 Cookie 自动抓取流程，抓取后自动清除 WebView 会话 Cookie，避免服务端判定会话失效导致的网页问题