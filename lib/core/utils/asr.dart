import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart';

import 'package:server_box/core/utils/asr_model.dart';
import 'package:server_box/core/utils/sherpa_asr.dart';

/// ASR 引擎类型
enum AsrEngine {
  /// 系统语音引擎（Google / 系统自带）
  system,
  /// sherpa_onnx 本地引擎
  sherpaOnnx,
}

/// ASR 状态
enum AsrStatus {
  /// 可用
  ready,
  /// 需要下载模型
  needModel,
  /// 不可用
  unavailable,
}

/// 统一 ASR 管理器
/// 检测降级顺序：系统引擎 → sherpa_onnx → 提示下载
class AsrManager {
  final SpeechToText _speechToText = SpeechToText();
  SherpaAsr? _sherpaAsr;
  bool _systemChecked = false;
  bool _systemAvailable = false;
  AsrEngine? _activeEngine;

  /// 检测系统语音引擎是否可用
  Future<bool> isSystemAvailable() async {
    if (_systemChecked) return _systemAvailable;
    try {
      _systemAvailable = await _speechToText.initialize(
        onError: (_) {},
        onStatus: (_) {},
      );
    } catch (_) {
      _systemAvailable = false;
    }
    // 初始化后立即停止，避免残留状态
    if (_systemAvailable) {
      await _speechToText.stop();
    }
    _systemChecked = true;
    return _systemAvailable;
  }

  /// 检测 sherpa_onnx 是否有可用模型
  Future<AsrModelInfo?> getReadySherpaModel() async {
    final models = await AsrModelManager.instance.getDownloadedModels();
    if (models.isEmpty) return null;
    return models.first;
  }

  /// 获取当前 ASR 状态
  Future<AsrStatus> getStatus() async {
    if (await isSystemAvailable()) return AsrStatus.ready;
    final model = await getReadySherpaModel();
    if (model != null) return AsrStatus.ready;
    return AsrStatus.needModel;
  }

  /// 开始识别（自动选择引擎）
  /// 返回 false 表示需要用户操作（下载模型等）
  Future<bool> startListening({
    required void Function(String text) onResult,
    required void Function(String error) onError,
    required void Function(String status) onStatus,
    required String localeId,
  }) async {
    // 优先使用系统引擎
    if (await isSystemAvailable()) {
      _activeEngine = AsrEngine.system;
      await _speechToText.listen(
        onResult: (result) {
          onResult(result.recognizedWords);
        },
        localeId: localeId,
      );
      return true;
    }

    // 尝试 sherpa_onnx
    final model = await getReadySherpaModel();
    if (model != null) {
      _activeEngine = AsrEngine.sherpaOnnx;
      _sherpaAsr ??= SherpaAsr();
      await _sherpaAsr!.init(model);
      await _sherpaAsr!.startListening(
        onResult: onResult,
        onError: onError,
      );
      return true;
    }

    // 都不可用，需要用户操作
    return false;
  }

  /// 停止识别
  Future<void> stopListening() async {
    switch (_activeEngine) {
      case AsrEngine.system:
        await _speechToText.stop();
        break;
      case AsrEngine.sherpaOnnx:
        await _sherpaAsr?.stopListening();
        break;
      case null:
        break;
    }
    _activeEngine = null;
  }

  /// 取消识别
  Future<void> cancel() async {
    switch (_activeEngine) {
      case AsrEngine.system:
        await _speechToText.cancel();
        break;
      case AsrEngine.sherpaOnnx:
        await _sherpaAsr?.stopListening();
        break;
      case null:
        break;
    }
    _activeEngine = null;
  }

  /// 释放资源
  void dispose() {
    _speechToText.cancel();
    _sherpaAsr?.dispose();
    _sherpaAsr = null;
    _activeEngine = null;
  }
}
