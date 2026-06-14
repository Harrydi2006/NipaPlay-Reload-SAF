# Android SAF 媒体库修复 + 播放器增强

本分支(`feat/android-saf-and-player-enhancements`)针对 Android 11+ 上的本地媒体库问题做了系统性修复,并附带几个播放器增强功能。涉及 issue #615。

## 一、媒体库:扫描结果进不了媒体库(核心修复)

### 问题
Android 11+ 通过 SAF(Storage Access Framework)选择文件夹后,扫描到的视频无法显示在本地媒体库;必须先手动播放某一集,该番剧才会出现。

### 根因
存在两套并行的存储后端,且读写不一致:
- `WatchHistoryManager` 通过 `_migratedToDatabase` 标志决定写 JSON 还是 SQLite,该标志在初始化时用「数据库文件是否已存在」一次性判定,强依赖初始化时序。一旦判为「未迁移」,后续所有写入(含扫描结果)都写进了旧的 JSON 文件。
- 而 `WatchHistoryProvider` / 媒体库页面始终只从 SQLite 读取。

结果:扫描写 JSON、媒体库读空的 SQLite,扫描到的番剧永远进不了媒体库;手动播放走的是直接写数据库的路径,所以只有播放过的才显示。

### 修复
- `WatchHistoryManager.initialize()` 改为与时序无关的可靠迁移:无论数据库是否已存在,只要 JSON 里还有数据(首次安装或历史残留),都读出来迁移进 SQLite,然后统一以数据库为准并备份移除 JSON。`insertOrUpdate` 以 `file_path` 为主键,幂等且不会丢失数据库中已有记录。
- `WatchHistoryProvider` 改为监听「扫描中 → 空闲」的下降沿来刷新历史,不再依赖会被其它监听器抢先 `acknowledge` 的 `scanJustCompleted` 标志,避免扫描后媒体库不刷新。
- `WatchHistoryProvider._validateFilePaths` 跳过 `content://` URI 的 `File.exists()` 校验,避免 SAF 本地视频被误判为无效而从数据库删除。
- `ScanService` 增加「自愈」:磁盘上存在但 `WatchHistoryManager` 中缺失的文件,即使哈希未变也重新处理,修复历史 bug 造成的缺失项。

涉及文件:`lib/models/watch_history_model.dart`、`lib/providers/watch_history_provider.dart`、`lib/services/scan_service.dart`。

## 二、媒体库:SAF 扫描卡死 / 文件名乱码 / 目录树

- 扫描阶段不再预取弹幕(`prefetchDanmaku: false`),避免每个文件都发一次弹幕请求,弱网下导致整次扫描卡死。
- `content://` URI 的显示名单独解码,修复文件名乱码(`primary%3A...`)。
- 本地库管理基于「根目录一次递归扫描的缓存」+ 自定义 `safdir://` 虚拟路径,按层级重建出与桌面端一致的目录树,而不必为每个子目录重新发起原生扫描(SAF 子目录没有独立可复用的 tree URI)。

涉及文件:`lib/services/concurrent_video_processor.dart`、`lib/services/dandanplay_service_io.dart`、`lib/services/dandanplay_service_stub.dart`、`lib/themes/nipaplay/widgets/library_management_tab.dart`。

## 三、播放:`content://` 文件无法播放

多个入口在播放前用 `io.File().existsSync()` 校验文件存在性,对 SAF 的 `content://` 路径恒为 false,导致提示「文件不存在或无法访问」。统一将 `content://` 视为非真实文件系统路径,跳过本地存在性校验,交给底层播放器 / `ContentResolver` 处理。

涉及文件:`lib/utils/video_player_state/video_player_state_player_setup.dart`、`lib/pages/anime_page.dart`、`lib/pages/anime_detail_page.dart`、`lib/themes/nipaplay/widgets/dashboard_home_page_actions.dart`、`lib/themes/nipaplay/pages/settings/watch_history_page.dart`、`lib/themes/nipaplay/widgets/tag_search_widget.dart`、`lib/themes/cupertino/pages/cupertino_home_page.dart`、`lib/themes/cupertino/pages/cupertino_media_library_page.dart`。

## 四、Android:再按一次返回键退出

在主界面顶层用 `PopScope` 拦截返回键,2 秒内连按两次才退出,首次按下提示「再按一次返回键退出」,避免误触退回桌面。仅 Android 生效。

涉及文件:`lib/main.dart`。

## 五、弹幕:垂直位置偏移

新增弹幕垂直偏移设置(0–200px),在弹幕层容器整体下移,用于规避刘海屏 / 挖孔屏遮挡顶部弹幕。设置持久化,NipaPlay 与 Cupertino 两套主题均提供入口。

涉及文件:`lib/utils/video_player_state.dart`、`lib/utils/video_player_state/video_player_state_preferences.dart`、`lib/utils/video_player_state/video_player_state_initialization.dart`、`lib/themes/nipaplay/widgets/video_player_ui.dart`、`lib/themes/cupertino/pages/cupertino_play_video_page.dart`、`lib/themes/nipaplay/widgets/danmaku_settings_menu.dart`、`lib/themes/cupertino/widgets/player_menu/cupertino_danmaku_settings_pane.dart`。

## 六、MPV(media_kit / libmpv)自定义配置

选择 Libmpv 内核时,可在「播放器设置 → MPV 自定义配置」里编辑 `mpv.conf` 风格的 `key=value` 选项(支持 `#` 注释),保存到 `SharedPreferences`,在内核初始化时解析并通过 `setProperty` 下发。配置在内核初始化时读取,保存后需重启 App 生效;部分需在初始化前设置的选项可能不生效。

涉及文件:`lib/player_abstraction/media_kit_player_adapter.dart`、`lib/themes/nipaplay/pages/settings/player_settings_page.dart`。

