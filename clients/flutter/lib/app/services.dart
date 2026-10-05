import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cloud_service.dart';
import '../services/file_service.dart';

final fileServiceProvider = Provider<FileService>((ref) => FileService());
final cloudServiceProvider = Provider<CloudService>((ref) {
  final service = CloudService();
  ref.onDispose(service.close);
  return service;
});
