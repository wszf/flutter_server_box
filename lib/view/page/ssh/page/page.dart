import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dartssh2/dartssh2.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:server_box/core/chan.dart';
import 'package:server_box/core/extension/context/locale.dart';
import 'package:server_box/core/utils/server.dart';
import 'package:server_box/core/utils/ssh_auth.dart';
import 'package:server_box/data/model/ai/ask_ai_models.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/data/model/server/snippet.dart';
import 'package:server_box/data/model/ssh/virtual_key.dart';
import 'package:server_box/data/provider/ai/ask_ai.dart';
import 'package:server_box/data/provider/server/single.dart';
import 'package:server_box/data/provider/snippet.dart';
import 'package:server_box/data/provider/virtual_keyboard.dart';
import 'package:server_box/data/res/store.dart';
import 'package:server_box/data/res/terminal.dart';
import 'package:server_box/data/ssh/session_manager.dart';
import 'package:server_box/view/page/storage/sftp.dart';
import 'package:server_box/core/utils/asr.dart';
import 'package:server_box/core/utils/asr_model.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:xterm/core.dart';
import 'package:xterm/ui.dart' hide TerminalThemes;

part 'ask_ai.dart';
part 'init.dart';
part 'input_bar.dart';
part 'keyboard.dart';
part 'virt_key.dart';

final class SshPageArgs {
  final Spi spi;
  final String? initCmd;
  final Snippet? initSnippet;
  final bool notFromTab;
  final Function()? onSessionEnd;
  final GlobalKey<TerminalViewState>? terminalKey;
  final FocusNode? focusNode;

  const SshPageArgs({
    required this.spi,
    this.initCmd,
    this.initSnippet,
    this.notFromTab = true,
    this.onSessionEnd,
    this.terminalKey,
    this.focusNode,
  });
}

class SSHPage extends ConsumerStatefulWidget {
  final SshPageArgs args;

  const SSHPage({super.key, required this.args});

  @override
  ConsumerState<SSHPage> createState() => SSHPageState();

  static const route = AppRouteArg<void, SshPageArgs>(page: SSHPage.new, path: '/ssh/page');
}

const _horizonPadding = 7.0;

class SSHPageState extends ConsumerState<SSHPage>
    with AutomaticKeepAliveClientMixin, AfterLayoutMixin, TickerProviderStateMixin {
  late final _terminal = Terminal();
  late final TerminalController _terminalController = TerminalController(vsync: this);
  final List<List<VirtKey>> _virtKeysList = [];
  late final _termKey = widget.args.terminalKey ?? GlobalKey<TerminalViewState>();

  late MediaQueryData _media;
  late TerminalStyle _terminalStyle;
  late TerminalTheme _terminalTheme;
  double _virtKeysHeight = 0;
  late final _horizonVirtKeys = Stores.setting.horizonVirtKey.fetch();

  bool _isDark = false;
  Timer? _virtKeyLongPressTimer;

  // 输入栏相关字段
  final _inputBarController = TextEditingController();
  bool _showInputBar = false;
  /// 用户主动开启输入栏（用于备用屏幕退出后恢复）
  bool _inputBarEnabledByUser = false;
  final _asrManager = AsrManager();
  bool _isListening = false;
  bool _voiceCancelling = false;
  /// 记录上一次已同步到终端的文本
  String _prevInputBarText = '';
  /// 防抖定时器，批量处理快速输入/删除
  Timer? _inputBarDebounce;

  SSHClient? _client;
  SSHSession? _session;
  Timer? _discontinuityTimer;
  static const _connectionCheckInterval = Duration(seconds: 60);
  static const _connectionCheckTimeout = Duration(seconds: 30);
  static const _maxKeepAliveFailures = 3;
  int _missedKeepAliveCount = 0;
  bool _isCheckingConnection = false;
  bool _disconnectDialogOpen = false;
  bool _reportedDisconnected = false;

  /// Used for (de)activate the wake lock and forground service
  static var _sshConnCount = 0;
  late final String _sessionId = ShortId.generate();
  late final int _sessionStartMs = DateTime.now().millisecondsSinceEpoch;

  @override
  void dispose() {
    _virtKeyLongPressTimer?.cancel();
    _terminalController.dispose();
    _inputBarController.removeListener(_onInputBarChanged);
    _inputBarDebounce?.cancel();
    _inputBarController.dispose();
    _terminal.removeListener(_onTerminalStateChanged);
    _asrManager.dispose();
    _discontinuityTimer?.cancel();

    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);

    if (--_sshConnCount <= 0) {
      WakelockPlus.disable();
      if (isAndroid) {
        MethodChans.stopService();
      }
    }

    // Remove session entry
    TermSessionManager.remove(_sessionId);

    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initStoredCfg();
    _initVirtKeys();
    _setupDiscontinuityTimer();
    _terminal.addListener(_onTerminalStateChanged);
    
    // Initialize client from provider
    final serverState = ref.read(serverProvider(widget.args.spi.id));
    _client = serverState.client;

    if (++_sshConnCount == 1) {
      WakelockPlus.enable();
      if (isAndroid) {
        MethodChans.startService();
      }
    }

    // Add session entry (for Android notifications & iOS Live Activities)
    TermSessionManager.add(
      id: _sessionId,
      spi: widget.args.spi,
      startTimeMs: _sessionStartMs,
      disconnect: _disconnectFromNotification,
      status: TermSessionStatus.connecting,
    );
    TermSessionManager.setActive(_sessionId, hasTerminal: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // 保存旋转前的输入内容
    final savedText = _inputBarController.text;
    final savedSelection = _inputBarController.selection;

    _isDark = switch (Stores.setting.termTheme.fetch()) {
      1 => false,
      2 => true,
      _ => context.isDark,
    };
    _media = context.mediaQuery;

    _terminalTheme = _isDark ? TerminalThemes.dark : TerminalThemes.light;
    _terminalTheme = _terminalTheme.copyWith(selectionCursor: UIs.primaryColor);

    // Because the virtual keyboard only displayed on mobile devices
    if (isMobile) {
      if (_horizonVirtKeys) {
        _virtKeysHeight = 37;
      } else {
        _virtKeysHeight = 37.0 * _virtKeysList.length;
      }
    }

    // 恢复旋转前的输入内容
    if (savedText.isNotEmpty && _inputBarController.text != savedText) {
      _inputBarController.text = savedText;
      try {
        _inputBarController.selection = savedSelection;
      } catch (_) {
        _inputBarController.selection = TextSelection.collapsed(offset: savedText.length);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final bgImage = Stores.setting.sshBgImage.fetch();
    final hasBg = bgImage.isNotEmpty;
    Widget child = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleEscKeyOrBackButton();
      },
      child: Scaffold(
        appBar: widget.args.notFromTab
            ? CustomAppBar(
                leading: BackButton(onPressed: context.pop),
                title: Text(widget.args.spi.name),
                centerTitle: false,
              )
            : null,
        backgroundColor: hasBg ? Colors.transparent : _terminalTheme.background,
        body: _buildBody(),
        bottomNavigationBar: isDesktop ? null : _buildBottom(),
      ),
    );

    if (isIOS) {
      child = AnnotatedRegion(
        value: _isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        child: child,
      );
    }
    return child;
  }

  Widget _buildBody() {
    final letterCache = Stores.setting.letterCache.fetch();
    final bgImage = Stores.setting.sshBgImage.fetch();
    final opacity = Stores.setting.sshBgOpacity.fetch();
    final blur = Stores.setting.sshBlurRadius.fetch();
    final file = File(bgImage);
    final hasBg = bgImage.isNotEmpty && file.existsSync();
    final theme = hasBg ? _terminalTheme.copyWith(background: Colors.transparent) : _terminalTheme;
    final children = <Widget>[];
    if (hasBg) {
      children.add(
        Positioned.fill(
          child: Image.file(file, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
        ),
      );
      if (blur > 0) {
        children.add(
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: const SizedBox(),
            ),
          ),
        );
      }
      children.add(
        Positioned.fill(
          child: ColoredBox(color: _terminalTheme.background.withValues(alpha: opacity)),
        ),
      );
    }
    children.add(
      Padding(
        padding: EdgeInsets.only(left: _horizonPadding, right: _horizonPadding),
        child: TerminalView(
          _terminal,
          key: _termKey,
          controller: _terminalController,
          keyboardType: TextInputType.text,
          enableSuggestions: letterCache,
          textStyle: _terminalStyle,
          backgroundOpacity: 0,
          theme: theme,
          deleteDetection: isMobile,
          autofocus: false,
          keyboardAppearance: _isDark ? Brightness.dark : Brightness.light,
          showToolbar: true,
          viewOffset: Offset(2 * _horizonPadding, CustomAppBar.sysStatusBarHeight),
          hideScrollBar: false,
          focusNode: widget.args.focusNode,
          toolbarBuilder: _buildTerminalToolbar,
          onCopied: _onTerminalCopied,
          onSelectAll: _onTerminalSelectAll,
          onPaste: _onTerminalPaste,
        ),
      ),
    );

    final inputBarH = _showInputBar ? _InputBar._inputBarHeight : 0.0;
    return SizedBox(
      height: _media.size.height - _virtKeysHeight - inputBarH - _media.padding.bottom - _media.padding.top,
      child: Stack(children: children),
    );
  }

  Widget _buildBottom() {
    return SafeArea(
      top: false,
      child: AnimatedPadding(
        padding: _media.viewInsets,
        duration: const Duration(milliseconds: 23),
        curve: Curves.fastOutSlowIn,
        child: Container(
          color: _terminalTheme.background,
          child: Consumer(
            builder: (context, ref, child) {
              final virtKeyState = ref.watch(virtKeyboardProvider);
              final virtKeyNotifier = ref.read(virtKeyboardProvider.notifier);

              // 设置终端输入处理器
              _terminal.inputHandler = virtKeyNotifier;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildInputBar(),
                  SizedBox(
                    height: _virtKeysHeight,
                    child: _buildVirtualKey(virtKeyState, virtKeyNotifier),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildVirtualKey(VirtKeyState virtKeyState, VirtKeyboard virtKeyNotifier) {
    final count = _horizonVirtKeys ? _virtKeysList.length : _virtKeysList.firstOrNull?.length ?? 0;
    if (count == 0) return UIs.placeholder;
    return LayoutBuilder(
      builder: (_, cons) {
        final virtKeyWidth = cons.maxWidth / count;
        if (_horizonVirtKeys) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _virtKeysList
                  .expand((e) => e)
                  .map((e) => _buildVirtKeyItem(e, virtKeyWidth, virtKeyState, virtKeyNotifier))
                  .toList(),
            ),
          );
        }
        final rows = _virtKeysList
            .map((e) => Row(children: e.map((e) => _buildVirtKeyItem(e, virtKeyWidth, virtKeyState, virtKeyNotifier)).toList()))
            .toList();
        return Column(mainAxisSize: MainAxisSize.min, children: rows);
      },
    );
  }

  Widget _buildVirtKeyItem(VirtKey item, double virtKeyWidth, VirtKeyState virtKeyState, VirtKeyboard virtKeyNotifier) {
    var selected = false;
    switch (item.key) {
      case TerminalKey.control:
        selected = virtKeyState.ctrl;
        break;
      case TerminalKey.alt:
        selected = virtKeyState.alt;
        break;
      case TerminalKey.shift:
        selected = virtKeyState.shift;
        break;
      default:
        break;
    }

    final child = item.icon != null
        ? Icon(item.icon, size: 17, color: _isDark ? Colors.white : Colors.black)
        : Text(
            item.text,
            style: TextStyle(
              color: selected ? UIs.primaryColor : (_isDark ? Colors.white : Colors.black),
              fontSize: 15,
            ),
          );

    return InkWell(
      onTap: () => _doVirtualKey(item, virtKeyNotifier),
      onTapDown: (details) {
        if (item.canLongPress) {
          _virtKeyLongPressTimer = Timer.periodic(
            const Duration(milliseconds: 137),
            (_) => _doVirtualKey(item, virtKeyNotifier),
          );
        }
      },
      onTapCancel: () => _virtKeyLongPressTimer?.cancel(),
      onTapUp: (_) => _virtKeyLongPressTimer?.cancel(),
      child: SizedBox(
        width: virtKeyWidth,
        height: _horizonVirtKeys ? _virtKeysHeight : _virtKeysHeight / _virtKeysList.length,
        child: Center(child: child),
      ),
    );
  }

  void _onTerminalCopied() {
    if (!mounted) return;
    context.showSnackBar(libL10n.success);
    _terminalController.clearSelection();
  }

  void _onTerminalSelectAll() {
    if (!mounted) return;
    _termKey.currentState?.renderTerminal.selectAll();
  }

  Future<void> _onTerminalPaste() async {
    final value = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = value?.text;
    if (text == null) return;
    _terminal.textInput(text);
    _terminalController.clearSelection();
  }

  Future<void> _onClipboardAction() async {
    if (_terminalController.selection != null) {
      final selectedText = _termKey.currentState?.renderTerminal.selectedText;
      if (selectedText != null && selectedText.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: selectedText));
        if (!mounted) return;
        context.showSnackBar(libL10n.success);
        _terminalController.clearSelection();
        return;
      }
      return;
    }
    await _onTerminalPaste();
  }

  @override
  bool get wantKeepAlive => true;

  /// 切换输入栏显示
  void _toggleInputBar() {
    _inputBarEnabledByUser = !_showInputBar;
    _setInputBarVisible(_inputBarEnabledByUser);
  }

  /// 设置输入栏可见性
  void _setInputBarVisible(bool visible) {
    if (_showInputBar == visible) return;
    setState(() {
      _showInputBar = visible;
    });
    if (visible) {
      _prevInputBarText = '';
      _inputBarController.clear();
      _inputBarController.addListener(_onInputBarChanged);
    } else {
      _inputBarController.removeListener(_onInputBarChanged);
      _inputBarDebounce?.cancel();
    }
  }

  /// 监听终端状态变化，检测备用屏幕切换
  /// 进入备用屏幕（vim/top等）时自动隐藏输入栏，退出时恢复
  bool _wasAltBuffer = false;
  void _onTerminalStateChanged() {
    final isAlt = _terminal.isUsingAltBuffer;
    if (isAlt == _wasAltBuffer) return;
    _wasAltBuffer = isAlt;

    if (isAlt && _showInputBar) {
      // 进入备用屏幕，自动隐藏
      _setInputBarVisible(false);
    } else if (!isAlt && _inputBarEnabledByUser) {
      // 退出备用屏幕，恢复用户之前的选择
      _setInputBarVisible(true);
    }
  }

  /// 输入框内容变化时，使用防抖批量同步到终端
  void _onInputBarChanged() {
    // 语音识别更新的文本不实时同步
    if (_isListening) return;

    _inputBarDebounce?.cancel();
    _inputBarDebounce = Timer(const Duration(milliseconds: 50), _syncInputBarToTerminal);
  }

  /// 将输入框内容与上次同步状态对比，批量发送差异到终端
  void _syncInputBarToTerminal() {
    final newText = _inputBarController.text;
    final oldText = _prevInputBarText;
    if (newText == oldText) return;
    _prevInputBarText = newText;

    if (newText.length > oldText.length && newText.startsWith(oldText)) {
      // 追加了新字符
      _terminal.textInput(newText.substring(oldText.length));
    } else if (newText.length < oldText.length && oldText.startsWith(newText)) {
      // 删除了字符（退格），批量发送
      final deletedCount = oldText.length - newText.length;
      for (var i = 0; i < deletedCount; i++) {
        _terminal.keyInput(TerminalKey.backspace);
      }
    } else {
      // 非连续变化（粘贴替换等），先删旧再输新
      for (var i = 0; i < oldText.length; i++) {
        _terminal.keyInput(TerminalKey.backspace);
      }
      if (newText.isNotEmpty) {
        _terminal.textInput(newText);
      }
    }
  }

  /// 更新语音取消状态
  void _updateVoiceCancelling(bool value) {
    setState(() => _voiceCancelling = value);
  }

  /// 开始语音识别（按住触发）
  Future<void> _startVoiceInput() async {
    _voiceCancelling = false;

    // 获取系统语言作为识别语言
    final locale = Localizations.localeOf(context);
    final localeId = '${locale.languageCode}_${locale.countryCode ?? locale.languageCode.toUpperCase()}';

    final started = await _asrManager.startListening(
      onResult: (text) {
        if (!mounted) return;
        _inputBarController.text = text;
        _inputBarController.selection = TextSelection.fromPosition(
          TextPosition(offset: _inputBarController.text.length),
        );
      },
      onError: (error) {
        if (!mounted) return;
        setState(() => _isListening = false);
        context.showSnackBar('${l10n.voiceInput}: $error');
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => _isListening = false);
        }
      },
      localeId: localeId,
      enginePref: Stores.setting.asrEngine.fetch(),
    );

    if (!started) {
      // 需要下载模型
      if (mounted) await _showAsrModelDialog();
      return;
    }

    if (mounted) setState(() => _isListening = true);
  }

  /// 结束语音识别（松开触发）
  Future<void> _endVoiceInput() async {
    await _asrManager.stopListening();
    if (!mounted) return;

    final cancelled = _voiceCancelling;
    setState(() {
      _isListening = false;
      _voiceCancelling = false;
    });

    if (cancelled) {
      // 取消输入，清空识别结果
      _inputBarController.clear();
      _prevInputBarText = '';
      context.showSnackBar(l10n.voiceInputCancelled);
    }
    // 不取消时，识别结果保留在输入框，等用户确认后发送
  }

  /// 显示 ASR 模型下载对话框
  Future<void> _showAsrModelDialog() async {
    final progressNotifier = ValueNotifier<double?>(null);

    await context.showRoundDialog(
      title: l10n.asrSelectModel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.asrSystemUnavailable),
          const SizedBox(height: 16),
          ...AsrModels.all.map((model) => ListTile(
                title: Text(model.name),
                subtitle: Text(l10n.asrModelSize(model.size)),
                trailing: const Icon(Icons.download),
                onTap: () async {
                  context.pop();
                  await _downloadAsrModel(model, progressNotifier);
                },
              )),
          const SizedBox(height: 8),
          Text(
            l10n.asrOrInstallEngine,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  /// 下载 ASR 模型
  Future<void> _downloadAsrModel(
    AsrModelInfo model,
    ValueNotifier<double?> progressNotifier,
  ) async {
    // 显示下载进度对话框
    context.showRoundDialog(
      title: l10n.asrModelDownloading,
      child: ValueListenableBuilder<double?>(
        valueListenable: progressNotifier,
        builder: (_, progress, __) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 8),
                Text('${((progress ?? 0) * 100).toStringAsFixed(1)}%'),
              ],
            ),
          );
        },
      ),
    );

    try {
      await AsrModelManager.instance.downloadModel(
        model,
        onProgress: (p) => progressNotifier.value = p,
      );
      // 保存模型选择
      Stores.setting.asrModelId.put(model.id);

      if (mounted) {
        context.pop(); // 关闭进度对话框
        context.showSnackBar(l10n.asrDownloadComplete);
      }
    } catch (e) {
      if (mounted) {
        context.pop();
        context.showSnackBar('${l10n.voiceInput}: $e');
      }
    }
  }

  @override
  FutureOr<void> afterFirstLayout(BuildContext context) async {
    await _showHelp();
    await _initTerminal();

    if (Stores.setting.sshWakeLock.fetch()) WakelockPlus.enable();

    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }
}
