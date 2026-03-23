import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// ASR 模型信息
class AsrModelInfo {
  final String id;
  final String name;
  final String lang;
  final String url;
  final String size;

  /// 模型目录内的文件相对路径
  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;

  const AsrModelInfo({
    required this.id,
    required this.name,
    required this.lang,
    required this.url,
    required this.size,
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });
}

/// 可选模型列表
abstract final class AsrModels {
  static const zhMulti = AsrModelInfo(
    id: 'sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12',
    name: '中文 Zipformer',
    lang: 'zh',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12.tar.bz2',
    size: '~67MB',
    encoder: 'encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx',
    decoder: 'decoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx',
    joiner: 'joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx',
    tokens: 'tokens.txt',
  );

  static const en = AsrModelInfo(
    id: 'sherpa-onnx-streaming-zipformer-en-2023-06-26',
    name: 'English Zipformer',
    lang: 'en',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2',
    size: '~68MB',
    encoder: 'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    decoder: 'decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    joiner: 'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    tokens: 'tokens.txt',
  );

  static const all = [zhMulti, en];

  /// 根据 ID 查找模型
  static AsrModelInfo? byId(String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }
}

/// 模型下载和存储管理
class AsrModelManager {
  AsrModelManager._();
  static final instance = AsrModelManager._();

  final _dio = Dio();
  String? _modelsDir;

  /// 获取模型存储目录
  Future<String> get modelsDir async {
    if (_modelsDir != null) return _modelsDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _modelsDir = p.join(appDir.path, 'asr_models');
    return _modelsDir!;
  }

  /// 检查模型是否已下载
  Future<bool> isModelReady(AsrModelInfo model) async {
    final dir = await modelsDir;
    final modelDir = p.join(dir, model.id);
    final tokensFile = File(p.join(modelDir, model.tokens));
    return tokensFile.existsSync();
  }

  /// 获取模型文件路径
  Future<String> getModelDir(AsrModelInfo model) async {
    final dir = await modelsDir;
    return p.join(dir, model.id);
  }

  /// 下载模型
  /// [onProgress] 回调下载进度 0.0 ~ 1.0
  Future<void> downloadModel(
    AsrModelInfo model, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await modelsDir;
    final targetDir = Directory(p.join(dir, model.id));

    // 已存在则跳过
    if (await isModelReady(model)) return;

    // 确保目录存在
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    final tmpFile = File(p.join(dir, '${model.id}.tar.bz2'));

    try {
      // 下载
      await _dio.download(
        model.url,
        tmpFile.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call(received / total);
          }
        },
      );

      // 解压 tar.bz2
      await Process.run('tar', ['xjf', tmpFile.path, '-C', dir]);

      // 验证
      if (!await isModelReady(model)) {
        throw Exception('模型解压后缺少文件');
      }
    } finally {
      // 清理临时文件
      if (tmpFile.existsSync()) {
        tmpFile.deleteSync();
      }
    }
  }

  /// 删除模型
  Future<void> deleteModel(AsrModelInfo model) async {
    final dir = await modelsDir;
    final modelDir = Directory(p.join(dir, model.id));
    if (modelDir.existsSync()) {
      modelDir.deleteSync(recursive: true);
    }
  }

  /// 获取所有已下载的模型
  Future<List<AsrModelInfo>> getDownloadedModels() async {
    final result = <AsrModelInfo>[];
    for (final model in AsrModels.all) {
      if (await isModelReady(model)) {
        result.add(model);
      }
    }
    return result;
  }
}
