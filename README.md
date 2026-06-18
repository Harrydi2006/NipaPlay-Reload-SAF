# NipaPlay-Reload（Android SAF / 播放器增强分支）

> 本仓库是 [AimesSoft/NipaPlay-Reload](https://github.com/AimesSoft/NipaPlay-Reload) 的一个 **fork 分支**。
>
> 由于改动较大且高度聚焦于 **Android 11+ 的本地文件访问（SAF）** 与 **播放器体验**，本分支 **不计划合并回上游主分支**，作为独立分支长期存在。
>
> 本 README 只描述 **本分支相对上游主分支的差异**。项目本身的完整介绍、构建方式、其它平台说明请参阅上游仓库。

---

## 为什么有这个分支

上游版本在 Android 11+（作用域存储 / Scoped Storage）下，本地媒体库存在一系列问题：扫描卡死、文件名乱码、权限误报、SAF 视频无法播放、播放列表/字幕无法识别等。本分支针对这些问题做了系统性修复，并顺带增强了播放器的若干体验。

---

## 主要差异一览

### 1. Android 11+ 本地媒体库（SAF）修复
- 通过 `ACTION_OPEN_DOCUMENT_TREE` 取得的 `content://` 目录可以正常 **扫描 / 入库 / 播放**。
- 修复扫描 **卡死 / 假死**。
- 修复媒体库中 **文件名乱码**（不再显示 `primary%3A…` 这类编码串，统一解码为真实文件名）。
- 修复 **权限误报**（content:// 路径不再走 `File().existsSync()` 误判为“文件不存在”）。
- 扩充 **视频格式** 识别范围。
- 修复入库后 **媒体库持久化** 问题（重启后仍在）。

涉及：`MainActivity.kt`、`android_saf_service.dart`、`scan_service.dart`、`concurrent_video_processor.dart`、`library_management_tab.dart`、`file_picker_service.dart`、`watch_history_*`、`dandanplay_service_io.dart` 等。

### 2. 播放列表支持 SAF（content://）
- 从 SAF 目录播放时，正确列出 **同目录的其它视频** 并可切换播放。
- 修复混入非视频文件的目录导致 **播放列表为空 / 条目空白** 的问题（根因是 `content://` 文件名被二次解码抛异常，已改为安全的单次解码）。

涉及：`playlist_menu.dart`、`cupertino_playlist_pane.dart`。

### 3. 播放器标题显示修复
- 播放器顶部标题 **始终回退到可读文件名**，不再显示 `primary%3A…` 编码串。
- 对历史记录中已被污染的标题做 **自愈式修正**。

涉及：`video_player_state_metadata.dart`、`video_player_state_player_setup.dart`、`video_player_ui.dart`。

### 4. 字幕：SAF 自动识别 + 多轨 + 子目录扫描
- 恢复并增强 SAF 视频的 **字幕自动识别**（新增原生 `scanSubtitleDirectory`）。
- 支持 **多个匹配字幕** 同时加载并在字幕轨道中切换（例如同时存在 SC / TC）。
- 扫描字幕时一并扫描 **`sub` / `subs` / `subtitle` / `字幕`** 等关键词子目录。
- 修复 Android 上 **手动选择字幕** 无法显示目标格式文件的问题。

涉及：`subtitle_manager.dart`、`android_saf_service.dart`、`MainActivity.kt`。

### 5. 媒体库：同一集多版本选择
- 当同一 `(animeId + 集数)` 匹配到 **多个本地文件**（例如 PV 被误刮削成某一集）时，媒体库中显示 **版本数量**，可在 **二级菜单** 中选择具体文件播放，避免正确文件被挤掉。

涉及：`watch_history_database.dart`、`watch_history_model.dart`、`anime_detail_page.dart`、`large_screen_anime_detail_page.dart`。

### 6. 播放器体验增强
- **MPV（media_kit）内核支持自定义配置**（自定义 `mpv.conf`）。
- **弹幕垂直偏移** 设置。
- Android **双击返回键退出**。

涉及：`media_kit_player_adapter.dart`、`player_settings_page.dart`、`danmaku_settings_menu.dart`、`cupertino_danmaku_settings_pane.dart`、`main.dart` 等。

---

## 说明
- 以上修改主要面向 **Android**；iOS（Cupertino）主题中的对应改动仅作兼容性保留，未做重点验证。
- 完整文件级改动请见提交记录与 `Documentation/` 下的补充说明。
