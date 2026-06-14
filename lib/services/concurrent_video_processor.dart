import 'dart:io' if (dart.library.io) 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/services/dandanplay_service.dart';

/// 视频处理结果
class VideoProcessResult {
  final String filePath;
  final bool success;
  final String? errorMessage;
  final WatchHistoryItem? historyItem;
  final String? animeTitle;

  VideoProcessResult({
    required this.filePath,
    required this.success,
    this.errorMessage,
    this.historyItem,
    this.animeTitle,
  });
}

/// 并发视频处理器，负责并发处理视频文件匹配
class ConcurrentVideoProcessor {
  static const int _maxConcurrency = 4; // 最大并发数
  static const Duration _requestTimeout = Duration(seconds: 20);
  // 单个文件的“整体”处理超时（含网络匹配 + 本地 DB 读写）。
  // 必须大于 _requestTimeout，用来兜底任何未加超时的 await（如 DB 写入、
  // SAF 读取阻塞），确保任意单文件都不会让整次扫描永远停在最后一个。
  static const Duration _perFileTimeout = Duration(seconds: 40);

  /// 并发处理视频文件列表
  static Future<List<VideoProcessResult>> processVideos(
    List<File> videoFiles, {
    bool skipPreviouslyMatchedUnwatched = false,
    Function(int processed, int total, String currentFile)? onProgress,
  }) async {
    return processVideoPaths(
      videoFiles.map((file) => file.path).toList(growable: false),
      skipPreviouslyMatchedUnwatched: skipPreviouslyMatchedUnwatched,
      onProgress: onProgress,
    );
  }

  /// 并发处理视频路径列表。本地文件路径与 Android content:// URI 都通过这里处理。
  static Future<List<VideoProcessResult>> processVideoPaths(
    List<String> videoPaths, {
    bool skipPreviouslyMatchedUnwatched = false,
    Function(int processed, int total, String currentFile)? onProgress,
  }) async {
    if (videoPaths.isEmpty) return [];

    // 根据文件数量决定并发数
    final int concurrency = _calculateOptimalConcurrency(videoPaths.length);
    debugPrint(
        'ConcurrentVideoProcessor: 开始处理 ${videoPaths.length} 个视频文件，并发数: $concurrency');

    final List<VideoProcessResult> results = [];
    final List<String> pathsToProcess = [];
    int skippedCount = 0;

    // 第一阶段：过滤需要处理的文件
    if (skipPreviouslyMatchedUnwatched) {
      for (String videoPath in videoPaths) {
        WatchHistoryItem? existingItem =
            await WatchHistoryManager.getHistoryItem(videoPath);
        if (existingItem != null &&
            existingItem.animeId != null &&
            existingItem.episodeId != null &&
            existingItem.watchProgress <= 0.01) {
          skippedCount++;
          onProgress?.call(
              skippedCount, videoPaths.length, _displayName(videoPath));
          continue;
        }
        pathsToProcess.add(videoPath);
      }
    } else {
      pathsToProcess.addAll(videoPaths);
    }

    if (pathsToProcess.isEmpty) {
      debugPrint('ConcurrentVideoProcessor: 所有文件都被跳过，无需处理');
      return results;
    }

    // 第二阶段：并发处理
    int processedCount = skippedCount;
    final Semaphore semaphore = Semaphore(concurrency);
    final List<Future<VideoProcessResult>> futures = [];

    for (String videoPath in pathsToProcess) {
      final future = semaphore.acquire().then((_) async {
        try {
          final result = await _processSingleVideoPath(videoPath).timeout(
            _perFileTimeout,
            onTimeout: () => VideoProcessResult(
              filePath: videoPath,
              success: false,
              errorMessage: '处理超时',
            ),
          );
          processedCount++;
          onProgress?.call(
              processedCount, videoPaths.length, _displayName(videoPath));
          return result;
        } catch (e) {
          // 任何意外异常都不应让该文件的 future 悬挂，导致整次扫描卡死。
          processedCount++;
          onProgress?.call(
              processedCount, videoPaths.length, _displayName(videoPath));
          return VideoProcessResult(
            filePath: videoPath,
            success: false,
            errorMessage:
                '错误: ${e.toString().substring(0, min(e.toString().length, 30))}',
          );
        } finally {
          semaphore.release();
        }
      });
      futures.add(future);
    }

    // 等待所有任务完成
    final processingResults = await Future.wait(futures);
    results.addAll(processingResults);

    debugPrint(
        'ConcurrentVideoProcessor: 处理完成。成功: ${results.where((r) => r.success).length}, 失败: ${results.where((r) => !r.success).length}, 跳过: $skippedCount');
    return results;
  }

  static Future<VideoProcessResult> _processSingleVideoPath(
      String videoPath) async {
    try {
      // 扫描阶段只做匹配，不预取弹幕（弹幕在播放时再拉）。
      // 否则每个文件都会触发一次弹幕网络请求，弱网下会让整次扫描卡死。
      final videoInfo =
          await DandanplayService.getVideoInfo(videoPath, prefetchDanmaku: false)
              .timeout(_requestTimeout, onTimeout: () {
        throw TimeoutException('获取视频信息超时 (${_displayName(videoPath)})');
      });

      if (videoInfo['isMatched'] == true &&
          videoInfo['matches'] != null &&
          (videoInfo['matches'] as List).isNotEmpty) {
        final match = videoInfo['matches'][0];
        final animeIdFromMatch = match['animeId'] as int?;
        final episodeIdFromMatch = match['episodeId'] as int?;
        final animeTitleFromMatch =
            (match['animeTitle'] as String?)?.isNotEmpty == true
                ? match['animeTitle'] as String
                : p.basenameWithoutExtension(_displayName(videoPath));
        final episodeTitleFromMatch = match['episodeTitle'] as String?;

        if (animeIdFromMatch != null && episodeIdFromMatch != null) {
          WatchHistoryItem? existingItem =
              await WatchHistoryManager.getHistoryItem(videoPath);
          final int durationFromMatch = (videoInfo['duration'] is int)
              ? videoInfo['duration'] as int
              : (existingItem?.duration ?? 0);

          WatchHistoryItem itemToSave;
          if (existingItem != null) {
            if (existingItem.watchProgress > 0.01 && !existingItem.isFromScan) {
              // 保留用户的观看进度
              itemToSave = WatchHistoryItem(
                  filePath: existingItem.filePath,
                  animeName: animeTitleFromMatch,
                  episodeTitle: episodeTitleFromMatch,
                  episodeId: episodeIdFromMatch,
                  animeId: animeIdFromMatch,
                  watchProgress: existingItem.watchProgress,
                  lastPosition: existingItem.lastPosition,
                  duration: durationFromMatch,
                  lastWatchTime: DateTime.now(),
                  thumbnailPath: existingItem.thumbnailPath,
                  isFromScan: false);
            } else {
              // 更新扫描项目
              itemToSave = WatchHistoryItem(
                  filePath: videoPath,
                  animeName: animeTitleFromMatch,
                  episodeTitle: episodeTitleFromMatch,
                  episodeId: episodeIdFromMatch,
                  animeId: animeIdFromMatch,
                  watchProgress: existingItem.watchProgress,
                  lastPosition: existingItem.lastPosition,
                  duration: durationFromMatch,
                  lastWatchTime: DateTime.now(),
                  thumbnailPath: existingItem.thumbnailPath,
                  isFromScan: true);
            }
          } else {
            // 新扫描项目
            itemToSave = WatchHistoryItem(
                filePath: videoPath,
                animeName: animeTitleFromMatch,
                episodeTitle: episodeTitleFromMatch,
                episodeId: episodeIdFromMatch,
                animeId: animeIdFromMatch,
                watchProgress: 0.0,
                lastPosition: 0,
                duration: durationFromMatch,
                lastWatchTime: DateTime.now(),
                thumbnailPath: null,
                isFromScan: true);
          }

          await WatchHistoryManager.addOrUpdateHistory(itemToSave);

          return VideoProcessResult(
            filePath: videoPath,
            success: true,
            historyItem: itemToSave,
            animeTitle: animeTitleFromMatch,
          );
        } else {
          return VideoProcessResult(
            filePath: videoPath,
            success: false,
            errorMessage: '缺少ID',
          );
        }
      } else {
        return VideoProcessResult(
          filePath: videoPath,
          success: false,
          errorMessage: '未匹配',
        );
      }
    } on TimeoutException {
      return VideoProcessResult(
        filePath: videoPath,
        success: false,
        errorMessage: '超时',
      );
    } catch (e) {
      return VideoProcessResult(
        filePath: videoPath,
        success: false,
        errorMessage:
            '错误: ${e.toString().substring(0, min(e.toString().length, 30))}',
      );
    }
  }

  /// 根据文件数量计算最优并发数
  static int _calculateOptimalConcurrency(int fileCount) {
    if (fileCount <= 2) return fileCount;
    if (fileCount <= 4) return fileCount;
    return _maxConcurrency; // 最多4个并发
  }

  static String _displayName(String path) {
    if (path.toLowerCase().startsWith('content://')) {
      // SAF 文档 ID 把真实路径整体编码进 URI，解码后仍带 primary:Movies/... 前缀，
      // 需再取最后一个 '/' 之后的部分才是真正的文件名。
      final decoded = Uri.decodeComponent(path);
      final lastSlash = decoded.lastIndexOf('/');
      final tail = lastSlash >= 0 ? decoded.substring(lastSlash + 1) : decoded;
      return tail.isNotEmpty ? tail : path;
    }
    return p.basename(path);
  }
}

/// 信号量实现，用于控制并发数量
class Semaphore {
  final int maxCount;
  int _currentCount;
  final Queue<Completer<void>> _waitQueue = Queue<Completer<void>>();

  Semaphore(this.maxCount) : _currentCount = maxCount;

  Future<void> acquire() async {
    if (_currentCount > 0) {
      _currentCount--;
      return;
    }

    final completer = Completer<void>();
    _waitQueue.addLast(completer);
    return completer.future;
  }

  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeFirst();
      completer.complete();
    } else {
      _currentCount++;
    }
  }
}
