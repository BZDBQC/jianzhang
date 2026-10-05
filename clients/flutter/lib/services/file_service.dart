import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'atomic_file.dart';

class PickedJson {
  const PickedJson(this.path, {this.ownedTemporary = false});
  final String path;
  final bool ownedTemporary;
}

class FileService {
  static const _channel = MethodChannel('jianzhang/files');
  Future<PickedJson?> pickJson() async {
    if (Platform.isAndroid) {
      final path = await _channel.invokeMethod<String>('openFile', {
        'extensions': ['json'],
      });
      return path == null ? null : PickedJson(path, ownedTemporary: true);
    }
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '简账 JSON 备份', extensions: ['json']),
      ],
    );
    return file == null ? null : PickedJson(file.path);
  }

  Future<void> releasePickedJson(PickedJson picked) async {
    if (!picked.ownedTemporary) return;
    if (!Platform.isAndroid) {
      throw StateError('Only the Android picker owns imported cache files');
    }
    await _channel.invokeMethod<void>('releaseFile', {'path': picked.path});
  }

  Future<bool> save(
    String sourcePath, {
    required String name,
    required String mime,
  }) async {
    if (!await File(sourcePath).exists()) {
      throw const FileSystemException('导出文件不存在');
    }
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('saveFile', {
            'name': name,
            'mime': mime,
            'sourcePath': sourcePath,
          }) ??
          false;
    }
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [
        XTypeGroup(label: '简账导出', extensions: [p.extension(name).substring(1)]),
      ],
    );
    if (location == null) return false;
    await copyExportAtomic(sourcePath, location.path);
    return true;
  }

  static Future<void> copyExportAtomic(
    String sourcePath,
    String targetPath,
  ) async {
    final target = File(targetPath);
    if (p.equals(p.absolute(sourcePath), p.absolute(target.path))) return;
    final suffix = const Uuid().v4();
    final staging = File('${target.path}.jianzhang-$suffix.tmp');
    try {
      await File(sourcePath).copy(staging.path);
      await atomicReplaceFile(staging.path, target.path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  }
}
