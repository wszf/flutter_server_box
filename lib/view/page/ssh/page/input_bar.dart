part of 'page.dart';

/// 终端文本输入栏和语音输入
extension _InputBar on SSHPageState {
  static const _inputBarHeight = 48.0;

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
              onSubmitted: (_) => _sendInputBarText(),
            ),
          ),
          const SizedBox(width: 4),
          _buildVoiceBtn(),
          const SizedBox(width: 4),
          Btn.icon(
            onTap: _sendInputBarText,
            icon: Icon(
              Icons.send,
              size: 18,
              color: _isDark ? Colors.white : Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  /// 语音按钮
  Widget _buildVoiceBtn() {
    final isListening = _isListening;
    return Btn.icon(
      onTap: () => isListening ? _stopVoiceInput() : _startVoiceInput(),
      icon: Icon(
        isListening ? Icons.mic : Icons.mic_none,
        size: 18,
        color: isListening ? Colors.red : (_isDark ? Colors.white : Colors.black),
      ),
    );
  }

  /// 发送输入框文本到终端
  void _sendInputBarText() {
    final text = _inputBarController.text;
    if (text.isEmpty) return;
    _terminal.textInput(text);
    _inputBarController.clear();
  }
}
