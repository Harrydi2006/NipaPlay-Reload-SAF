import 'package:flutter/services.dart';

class AndroidSafFileEntry {
  const AndroidSafFileEntry({
    required this.relativePath,
    required this.uri,
    required this.name,
    required this.size,
    required this.modifiedMillis,
    required this.fileHash,
  });

  final String relativePath;
  final String uri;
  final String name;
  final int size;
  final int modifiedMillis;
  final String fileHash;

  factory AndroidSafFileEntry.fromMap(Map<dynamic, dynamic> map) {
    return AndroidSafFileEntry(
      relativePath: map['relativePath'] as String,
      uri: map['uri'] as String,
      name: map['name'] as String,
      size: (map['size'] as num?)?.toInt() ?? 0,
      modifiedMillis: (map['modifiedMillis'] as num?)?.toInt() ?? 0,
      fileHash: (map['fileHash'] as String?) ?? '',
    );
  }
}

class AndroidSafFileMetadata {
  const AndroidSafFileMetadata({
    required this.uri,
    required this.name,
    required this.size,
    required this.contentHash,
  });

  final String uri;
  final String name;
  final int size;
  final String contentHash;

  factory AndroidSafFileMetadata.fromMap(Map<dynamic, dynamic> map) {
    return AndroidSafFileMetadata(
      uri: map['uri'] as String,
      name: map['name'] as String,
      size: (map['size'] as num?)?.toInt() ?? 0,
      contentHash: map['contentHash'] as String,
    );
  }
}

class AndroidSafService {
  AndroidSafService._();

  static const MethodChannel _channel = MethodChannel('nipaplay/android_saf');

  static bool isSafUri(String value) {
    return value.toLowerCase().startsWith('content://');
  }

  static Future<String?> pickDirectory() async {
    return _channel.invokeMethod<String>('pickDirectory');
  }

  static Future<bool> canAccessTree(String treeUri) async {
    final result = await _channel.invokeMethod<bool>(
      'canAccessTree',
      {'treeUri': treeUri},
    );
    return result == true;
  }

  static Future<List<AndroidSafFileEntry>> scanDirectory(
    String treeUri,
  ) async {
    final rawEntries = await _channel.invokeMethod<List<dynamic>>(
      'scanDirectory',
      {'treeUri': treeUri},
    );
    return (rawEntries ?? const <dynamic>[])
        .cast<Map<dynamic, dynamic>>()
        .map(AndroidSafFileEntry.fromMap)
        .toList(growable: false);
  }

  /// 扫描 SAF 目录树下的字幕文件（结构同 [scanDirectory]，但只返回字幕）。
  ///
  /// 用于 content:// 视频的外挂字幕自动识别：原生视频扫描只返回视频文件，
  /// 因此需要单独扫描字幕文件，再在 Dart 端按目录与文件名匹配。
  static Future<List<AndroidSafFileEntry>> scanSubtitleDirectory(
    String treeUri,
  ) async {
    final rawEntries = await _channel.invokeMethod<List<dynamic>>(
      'scanSubtitleDirectory',
      {'treeUri': treeUri},
    );
    return (rawEntries ?? const <dynamic>[])
        .cast<Map<dynamic, dynamic>>()
        .map(AndroidSafFileEntry.fromMap)
        .toList(growable: false);
  }

  /// 把 content:// 文件复制到应用缓存目录，返回本地真实路径（失败返回 null）。
  ///
  /// 主要用于外挂字幕：字幕加载流程依赖真实文件路径，无法直接读 content://。
  /// 注意会复制整个文件，仅适合字幕等小文件，不要用于视频本体。
  static Future<String?> copyToCache(String uri) async {
    return _channel.invokeMethod<String>('copyToCache', {'uri': uri});
  }

  static Future<AndroidSafFileMetadata> getFileMetadata(String uri) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getFileMetadata',
      {'uri': uri},
    );
    if (raw == null) {
      throw PlatformException(
        code: 'SAF_METADATA_EMPTY',
        message: 'Android SAF metadata result is empty.',
      );
    }
    return AndroidSafFileMetadata.fromMap(raw);
  }
}
