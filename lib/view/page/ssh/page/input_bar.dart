part of 'page.dart';

/// 终端文本输入栏和语音输入
extension _InputBar on SSHPageState {
  static const _inputBarHeight = 48.0;
  /// 上滑取消的阈值（像素）
  static const _cancelSlideThreshold = 80.0;

  /// 构建输入栏
  Widget _buildInputBar() {
    if (!_showInputBar) return const SizedBox();
    return Container(
      color: _terminalTheme.background,
      constraints: const BoxConstraints(minHeight: _inputBarHeight, maxHeight: 120),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Input(
              controller: _inputBarController,
              minLines: 1,
              maxLines: 4,
              hint: l10n.termInputBarHint,
              action: TextInputAction.newline,
              autoFocus: true,
              onSubmitted: (_) => _onInputBarSubmit(),
            ),
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _buildVoiceBtn(),
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Btn.icon(
              onTap: _onInputBarSubmit,
              icon: Icon(
                Icons.subdirectory_arrow_left,
                size: 18,
                color: _isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 语音按钮 - 按住说话，松开发送，上滑取消
  /// 蓝色 = 系统引擎，绿色 = 本地模型
  Widget _buildVoiceBtn() {
    final isListening = _isListening;
    final isCancelling = _voiceCancelling;
    final isSherpa = _asrManager.activeEngine == AsrEngine.sherpaOnnx;
    // 系统引擎蓝色，本地模型绿色
    final engineColor = isSherpa ? Colors.green : Colors.blue;

    return GestureDetector(
      onLongPressStart: (_) => _startVoiceInput(),
      onLongPressMoveUpdate: (details) {
        // 上滑超过阈值则标记为取消
        final shouldCancel = details.offsetFromOrigin.dy < -_cancelSlideThreshold;
        if (shouldCancel != _voiceCancelling) {
          _updateVoiceCancelling(shouldCancel);
        }
      },
      onLongPressEnd: (_) => _endVoiceInput(),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: isListening
            ? BoxDecoration(
                color: isCancelling
                    ? Colors.red.withValues(alpha: 0.2)
                    : engineColor.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              )
            : null,
        child: Icon(
          isListening
              ? (isCancelling ? Icons.mic_off : Icons.mic)
              : Icons.mic_none,
          size: 18,
          color: isListening
              ? (isCancelling ? Colors.red : engineColor)
              : (_isDark ? Colors.white : Colors.black),
        ),
      ),
    );
  }

  /// 提交输入：多行时逐行发送，每行后加回车
  void _onInputBarSubmit() {
    _inputBarDebounce?.cancel();
    final text = _inputBarController.text;
    final lines = text.split('\n');

    // 先清掉之前同步到终端的内容
    for (var i = 0; i < _prevInputBarText.length; i++) {
      _terminal.keyInput(TerminalKey.backspace);
    }

    // 逐行发送
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].isNotEmpty) {
        _terminal.textInput(lines[i]);
      }
      _terminal.keyInput(TerminalKey.enter);
    }

    _prevInputBarText = '';
    _inputBarController.clear();
  }
}
