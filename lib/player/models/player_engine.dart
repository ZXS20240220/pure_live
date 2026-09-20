/// 项目仅保留 mpv（media_kit）播放内核；历史上的 fijk / exo(BetterPlayer)
/// 内核已随其适配器彻底移除，枚举保留单值以维持 PlayerManager 等调用方
/// 的类型签名与备份/设置存储兼容。
enum PlayerEngine { mediaKit }
