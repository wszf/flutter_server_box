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
      height: _inputBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Input(
              controller: _inputBarController,
              minLines: 1,
              maxLines: 1,
              hint: l10n.termInputBarHint,
              action: TextInputAction.send,
              autoFocus: true,
              onSubmitted: (_) => _onInputBarSubmit(),
            ),
          ),
          const SizedBox(width: 4),
          _buildVoiceBtn(),
          const SizedBox(width: 4),
          Btn.icon(
            onTap: _onInputBarSubmit,
            icon: Icon(
              Icons.subdirectory_arrow_left,
              size: 18,
              color: _isDark ? Colors.white : Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  /// 语音按钮 - 按住说话，松开发送，上滑取消
  Widget _buildVoiceBtn() {
    final isListening = _isListening;
    final isCancelling = _voiceCancelling;
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
                    : Colors.blue.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              )
            : null,
        child: Icon(
          isListening
              ? (isCancelling ? Icons.mic_off : Icons.mic)
              : Icons.mic_none,
          size: 18,
          color: isListening
              ? (isCancelling ? Colors.red : Colors.blue)
              : (_isDark ? Colors.white : Colors.black),
        ),
      ),
    );
  }

  /// 提交输入：发送回车并清空输入框
  void _onInputBarSubmit() {
    // 语音识别的文本还没同步到终端，先发送
    if (_prevInputBarText.isEmpty && _inputBarController.text.isNotEmpty) {
      _terminal.textInput(_inputBarController.text);
    }
    _terminal.keyInput(TerminalKey.enter);
    _prevInputBarText = '';
    _inputBarController.clear();
  }
}
