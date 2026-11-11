import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../core/launch.dart';
import '../core/pty.dart';
import '../core/term_tools.dart';
import '../core/platform_paths.dart';
import 'theme.dart';

/// Opens [url] in the default browser (named for its first, Linux-only
/// version; it now follows the platform).
void openWithXdg(String url) {
  final cmd = openUrlCommand(url, currentOs());
  Process.run(cmd.first, cmd.sublist(1)).ignore();
}

/// Copy, paste and select-all on Ctrl+Shift, like other Linux terminals, so
/// Ctrl+A / Ctrl+C / Ctrl+V still reach the agent.
final kTerminalShortcuts = <ShortcutActivator, Intent>{
  const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
      const CopyTerminalTextIntent(),
  const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
  const SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true):
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
};

/// Copy handled by the tab rather than xterm, whose copy drops the blank
/// cells full-screen UIs skip over (see [selectionText]).
class CopyTerminalTextIntent extends Intent {
  const CopyTerminalTextIntent();
}

/// One running agent: a pseudo-terminal process drawn by xterm.
/// The process lives as long as the widget; hidden tabs keep running
/// because the home page keeps them in an IndexedStack.
class TerminalTab extends StatefulWidget {
  const TerminalTab({
    super.key,
    required this.spec,
    required this.start,
    required this.title,
    this.onExit,
    this.fontSize = kTermFontSize,
    this.onZoom,
    this.openUrl = openWithXdg,
  });

  final LaunchSpec spec;
  final PtyStarter start;
  final String title;
  final void Function(int code)? onExit;
  final double fontSize;
  final void Function(int step)? onZoom;
  final void Function(String url) openUrl;

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab>
    with AutomaticKeepAliveClientMixin {
  final terminal = Terminal(maxLines: 20000);
  final _controller = TerminalController();
  final _scroll = ScrollController();
  final _termFocus = FocusNode();
  late final PtySession _session;
  StreamSubscription<String>? _sub;
  bool _exited = false;

  bool _finding = false;
  final _findCtrl = TextEditingController();
  List<TextHit> _hits = const [];
  int _hit = 0;
  TerminalHighlight? _highlight;

  @override
  void initState() {
    super.initState();
    _session = widget.start(widget.spec);
    _sub = _session.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
    terminal.onOutput = (data) {
      if (!_exited) _session.write(utf8.encode(data));
    };
    terminal.onResize = (w, h, pw, ph) => _session.resize(h, w);
    _session.exitCode.then((code) {
      _exited = true;
      if (!mounted) return;
      terminal.write('\r\n[process exited with code $code]\r\n');
      widget.onExit?.call(code);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (!_exited) _session.kill();
    _highlight?.dispose();
    _controller.dispose();
    _scroll.dispose();
    _termFocus.dispose();
    _findCtrl.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final kb = HardwareKeyboard.instance;
    if (!kb.isControlPressed) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (kb.isShiftPressed && k == LogicalKeyboardKey.keyF) {
      _openFind();
      return KeyEventResult.handled;
    }
    final step = switch (k) {
      LogicalKeyboardKey.equal ||
      LogicalKeyboardKey.add ||
      LogicalKeyboardKey.numpadAdd => 1,
      LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract => -1,
      LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 => 0,
      _ => null,
    };
    if (step == null || widget.onZoom == null) return KeyEventResult.ignored;
    widget.onZoom!(step);
    return KeyEventResult.handled;
  }

  void _onTapUp(TapUpDetails details, CellOffset cell) {
    if (!HardwareKeyboard.instance.isControlPressed) return;
    final lines = terminal.buffer.lines;
    if (cell.y < 0 || cell.y >= lines.length) return;
    final url = urlAt(lineText(lines[cell.y]), cell.x);
    if (url != null) widget.openUrl(url);
  }

  // ---- search ------------------------------------------------------------

  void _openFind() => setState(() => _finding = true);

  void _closeFind() {
    _highlight?.dispose();
    _highlight = null;
    _findCtrl.clear();
    setState(() {
      _finding = false;
      _hits = const [];
    });
    _termFocus.requestFocus();
  }

  void _search(String q) {
    final lines = terminal.buffer.lines;
    _hits = findAll([
      for (var y = 0; y < lines.length; y++) lineText(lines[y]),
    ], q);
    _hit = _hits.length - 1; // newest output first
    _showHit();
  }

  void _step(int d) {
    if (_hits.isEmpty) return;
    _hit = (_hit + d) % _hits.length;
    _showHit();
  }

  void _showHit() {
    _highlight?.dispose();
    _highlight = null;
    if (_hits.isNotEmpty) {
      final h = _hits[_hit];
      final b = terminal.buffer;
      _highlight = _controller.highlight(
        p1: b.createAnchor(h.start, h.line),
        p2: b.createAnchor(h.end, h.line),
        color: Tok.accent.withValues(alpha: 0.45),
      );
      if (_scroll.hasClients) {
        final lineHeight = widget.fontSize * 1.2;
        final target = (h.line - 3) * lineHeight;
        _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        if (_finding) _findBar(context),
        Expanded(
          child: Actions(
            actions: {
              CopyTerminalTextIntent: CallbackAction<CopyTerminalTextIntent>(
                onInvoke: (_) => _copy(),
              ),
            },
            child: TerminalView(
              terminal,
              controller: _controller,
              scrollController: _scroll,
              focusNode: _termFocus,
              autofocus: true,
              shortcuts: kTerminalShortcuts,
              onKeyEvent: _onKey,
              onTapUp: _onTapUp,
              theme: terminalTheme,
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
              textStyle: TerminalStyle(
                fontFamily: Tok.mono,
                fontSize: widget.fontSize,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _copy() async {
    final sel = _controller.selection;
    if (sel == null) return;
    await Clipboard.setData(
      ClipboardData(text: selectionText(terminal.buffer, sel)),
    );
  }

  Widget _findBar(BuildContext context) {
    final count = _findCtrl.text.isEmpty
        ? ''
        : _hits.isEmpty
        ? 'No matches'
        : '${_hit + 1} of ${_hits.length}';
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: Tok.rail,
        border: Border(bottom: BorderSide(color: Tok.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 260,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _closeFind,
                const SingleActivator(
                  LogicalKeyboardKey.enter,
                  shift: true,
                ): () =>
                    _step(-1),
              },
              child: TextField(
                key: const ValueKey('find-field'),
                controller: _findCtrl,
                autofocus: true,
                onChanged: _search,
                onSubmitted: (_) => _step(1),
                style: const TextStyle(fontSize: 13.5),
                decoration: const InputDecoration(hintText: 'Find in output'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(count, style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          IconButton(
            key: const ValueKey('find-prev'),
            tooltip: 'Previous match',
            onPressed: _hits.isEmpty ? null : () => _step(-1),
            icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
          ),
          IconButton(
            key: const ValueKey('find-next'),
            tooltip: 'Next match',
            onPressed: _hits.isEmpty ? null : () => _step(1),
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
          ),
          IconButton(
            key: const ValueKey('find-close'),
            tooltip: 'Close search',
            onPressed: _closeFind,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}
