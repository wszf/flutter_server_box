import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'package:server_box/core/utils/asr_model.dart';

/// 将 PCM 16-bit 字节数据转为 Float32 采样
Float32List _convertBytesToFloat32(Uint8List bytes) {
  final int16List = Int16List.view(bytes.buffer);
  final float32List = Float32List(int16List.length);
  for (var i = 0; i < int16List.length; i++) {
    float32List[i] = int16List[i] / 32768.0;
  }
  return float32List;
}

/// sherpa_onnx 流式语音识别封装
class SherpaAsr {
  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _stream;
  AudioRecorder? _recorder;
  StreamSubscription? _audioSub;
  bool _initialized = false;

  static const _sampleRate = 16000;

  /// 初始化识别器
  Future<void> init(AsrModelInfo model) async {
    if (_initialized) return;

    final modelDir = await AsrModelManager.instance.getModelDir(model);

    sherpa_onnx.initBindings();

    final modelConfig = sherpa_onnx.OnlineModelConfig(
      transducer: sherpa_onnx.OnlineTransducerModelConfig(
        encoder: p.join(modelDir, model.encoder),
        decoder: p.join(modelDir, model.decoder),
        joiner: p.join(modelDir, model.joiner),
      ),
      tokens: p.join(modelDir, model.tokens),
      numThreads: 2,
      provider: 'cpu',
      modelType: 'zipformer2',
    );

    final config = sherpa_onnx.OnlineRecognizerConfig(
      model: modelConfig,
      enableEndpoint: true,
      rule1MinTrailingSilence: 2.4,
      rule2MinTrailingSilence: 1.2,
      rule3MinUtteranceLength: 20,
    );

    _recognizer = sherpa_onnx.OnlineRecognizer(config);
    _stream = _recognizer!.createStream();
    _recorder = AudioRecorder();
    _initialized = true;
  }

  /// 开始流式识别
  /// [onResult] 实时返回识别文本
  Future<void> startListening({
    required void Function(String text) onResult,
    required void Function(String error) onError,
  }) async {
    if (!_initialized || _recognizer == null) {
      onError('ASR 未初始化');
      return;
    }

    try {
      if (!await _recorder!.hasPermission()) {
        onError('无麦克风权限');
        return;
      }

      // 重置 stream
      _stream?.free();
      _stream = _recognizer!.createStream();

      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      );

      final audioStream = await _recorder!.startStream(config);

      _audioSub = audioStream.listen(
        (data) {
          final samples = _convertBytesToFloat32(Uint8List.fromList(data));
          _stream!.acceptWaveform(
            samples: samples,
            sampleRate: _sampleRate,
          );

          while (_recognizer!.isReady(_stream!)) {
            _recognizer!.decode(_stream!);
          }

          final result = _recognizer!.getResult(_stream!);
          if (result.text.isNotEmpty) {
            onResult(result.text);
          }

          // 端点检测：一句话说完后重置
          if (_recognizer!.isEndpoint(_stream!)) {
            _recognizer!.reset(_stream!);
          }
        },
        onError: (e) {
          onError(e.toString());
        },
      );
    } catch (e) {
      onError(e.toString());
    }
  }

  /// 停止识别
  Future<void> stopListening() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder?.stop();
  }

  /// 释放所有资源
  void dispose() {
    _audioSub?.cancel();
    _recorder?.dispose();
    _stream?.free();
    _recognizer?.free();
    _recognizer = null;
    _stream = null;
    _recorder = null;
    _initialized = false;
  }
}
