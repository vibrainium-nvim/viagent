import 'package:nvim/nvim.dart';

/// Floating single-line input prompt for renaming an agent chat session.
class AgentInputPrompt {
  final Nvim nvim;
  int? _buf;
  int? _win;
  Future<void> Function(String value)? _onSubmit;

  AgentInputPrompt(this.nvim);

  bool get isOpen => _win != null;
  int? get windowId => _win;
  int? get bufferId => _buf;

  Future<void> open({
    required String title,
    String initialValue = '',
    required Future<void> Function(String value) onSubmit,
  }) async {
    await nvim.activateOverlay(close);
    await close();
    nvim.setOverlayCloser(close);
    _onSubmit = onSubmit;

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'filetype', 'viagent-prompt');
    await nvim.bufSetLines(buf, lines: [initialValue]);

    final editorWidth = await nvim.getEditorWidth();
    final editorHeight = await nvim.getEditorHeight();
    final width = (editorWidth * 0.45).round().clamp(36, 64);
    const height = 1;
    final row = ((editorHeight - height) / 2).floor().clamp(1, editorHeight);
    final col = ((editorWidth - width) / 2).floor().clamp(1, editorWidth);

    final win = await nvim.openWin(buf, true, {
      'relative': 'editor',
      'row': row,
      'col': col,
      'width': width,
      'height': height,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' $title — <CR> confirm, q cancel ',
      'title_pos': 'center',
    });
    _win = win;

    if (initialValue.isNotEmpty) {
      await nvim.winSetCursor(win, 1, initialValue.length);
    }

    await nvim.bufSetKeymap(
      buf,
      'n',
      '<CR>',
      "<Cmd>lua require('vibrainium').action('agent.prompt_submit')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'i',
      '<CR>',
      "<Esc><Cmd>lua require('vibrainium').action('agent.prompt_submit')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      'q',
      "<Cmd>lua require('vibrainium').action('agent.prompt_close')<CR>",
    );
    // <C-c> closes the prompt in both normal and insert mode.
    // In insert mode, <Esc> transitions to normal mode without closing.
    // In normal mode, 'q' (or <C-c>) closes the prompt, while <Esc> stays in normal mode.
    for (final mode in ['n', 'i']) {
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<C-c>',
        mode == 'i'
            ? "<Esc><Cmd>lua require('vibrainium').action('agent.prompt_close')<CR>"
            : "<Cmd>lua require('vibrainium').action('agent.prompt_close')<CR>",
      );
    }

    await nvim.command('startinsert!');
  }

  Future<void> submit() async {
    final buf = _buf;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      await close();
      return;
    }
    final lines = await nvim.bufGetLines(buf);
    final text = lines.isEmpty ? '' : lines.first.trim();
    final callback = _onSubmit;
    await close();
    if (text.isEmpty) return;
    if (callback != null) {
      await callback(text);
    }
  }

  Future<void> close() async {
    nvim.clearOverlayCloser(close);
    final win = _win;
    _win = null;
    _buf = null;
    _onSubmit = null;
    if (win != null) {
      try {
        await nvim.command('stopinsert');
      } catch (_) {}
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }
}

/// Floating confirmation modal for closing/deleting an agent chat session.
class AgentConfirmPrompt {
  final Nvim nvim;
  int? _buf;
  int? _win;
  Future<void> Function()? _onConfirm;

  AgentConfirmPrompt(this.nvim);

  bool get isOpen => _win != null;
  int? get windowId => _win;
  int? get bufferId => _buf;

  Future<void> open({
    required String message,
    required Future<void> Function() onConfirm,
  }) async {
    await nvim.activateOverlay(close);
    await close();
    nvim.setOverlayCloser(close);
    _onConfirm = onConfirm;

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;
    final line = ' $message (y/n) ';

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: [line]);
    await nvim.bufSetOption(buf, 'modifiable', false);
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'filetype', 'viagent-confirm');

    final editorWidth = await nvim.getEditorWidth();
    final editorHeight = await nvim.getEditorHeight();
    final width = (line.length + 4).clamp(32, 68);
    const height = 1;
    final row = ((editorHeight - height) / 2).floor().clamp(1, editorHeight);
    final col = ((editorWidth - width) / 2).floor().clamp(1, editorWidth);

    final win = await nvim.openWin(buf, true, {
      'relative': 'editor',
      'row': row,
      'col': col,
      'width': width,
      'height': height,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' Confirm ',
      'title_pos': 'center',
    });
    _win = win;
    await nvim.command('stopinsert');

    for (final key in ['y', 'Y', '<CR>']) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        key,
        "<Cmd>lua require('vibrainium').action('agent.confirm_yes')<CR>",
      );
    }
    for (final key in ['n', 'N', 'q', '<Esc>', '<C-c>']) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        key,
        "<Cmd>lua require('vibrainium').action('agent.confirm_no')<CR>",
      );
    }
  }

  Future<void> confirm() async {
    final callback = _onConfirm;
    await close();
    if (callback != null) {
      await callback();
    }
  }

  Future<void> close() async {
    nvim.clearOverlayCloser(close);
    final win = _win;
    _win = null;
    _buf = null;
    _onConfirm = null;
    if (win != null) {
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }
}

/// A single item in [AgentPickerModal] or [AgentContextMenu].
class AgentMenuItem extends NvimContextMenuItem {
  const AgentMenuItem({
    required super.label,
    super.shortcut = '',
    required super.onSelect,
  });
}

/// Floating right-click context menu for [AgentsPanel].
class AgentContextMenu extends NvimContextMenu<AgentMenuItem> {
  AgentContextMenu(Nvim nvim)
      : super(
          nvim: nvim,
          actionPrefix: 'agent',
          filetype: 'viagent-menu',
          augroupName: 'ViagentContextMenu',
          rightClickAction: 'agent.context_menu',
        );

  Future<void> open({
    required List<AgentMenuItem> items,
    String title = 'Agent Actions',
    int? anchorWin,
    int row = 1,
    int col = 2,
    Future<void> Function()? onCancel,
  }) =>
      openMenu(
        items: items,
        title: title,
        anchorWin: anchorWin,
        row: row,
        col: col,
        minWidth: 26,
        maxWidth: 64,
        onCancel: onCancel,
      );
}

/// Floating modal menu/picker for selecting a target chat or context action.
class AgentPickerModal {
  final Nvim nvim;
  int? _buf;
  int? _win;
  List<AgentMenuItem> _items = const [];

  AgentPickerModal(this.nvim);

  bool get isOpen => _win != null;
  int? get windowId => _win;
  int? get bufferId => _buf;
  List<AgentMenuItem> get items => List.unmodifiable(_items);

  Future<void> open({
    required List<AgentMenuItem> items,
    String title = 'Select Agent Chat',
    int initialIndex = 0,
  }) async {
    await nvim.activateOverlay(close);
    await close();
    if (items.isEmpty) return;
    nvim.setOverlayCloser(close);
    _items = items;

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;

    var maxLabelLen = 0;
    var maxShortcutLen = 0;
    for (final item in items) {
      if (item.label.length > maxLabelLen) maxLabelLen = item.label.length;
      if (item.shortcut.length > maxShortcutLen) {
        maxShortcutLen = item.shortcut.length;
      }
    }

    final innerWidth = (maxLabelLen + maxShortcutLen + 6).clamp(30, 64);
    final lines = <String>[];
    for (final item in items) {
      if (item.shortcut.isEmpty) {
        lines.add(' ${item.label} ');
      } else {
        final pad = (innerWidth - 2 - item.label.length - item.shortcut.length)
            .clamp(1, innerWidth);
        lines.add(' ${item.label}${' ' * pad}${item.shortcut} ');
      }
    }

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: lines);
    await nvim.bufSetOption(buf, 'modifiable', false);
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'filetype', 'viagent-picker');

    final editorWidth = await nvim.getEditorWidth();
    final editorHeight = await nvim.getEditorHeight();
    final height = lines.length.clamp(1, 14);
    final row = ((editorHeight - height) / 2).floor().clamp(1, editorHeight);
    final col = ((editorWidth - innerWidth) / 2).floor().clamp(1, editorWidth);

    final win = await nvim.openWin(buf, true, {
      'relative': 'editor',
      'row': row,
      'col': col,
      'width': innerWidth,
      'height': height,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' $title ',
      'title_pos': 'center',
    });
    _win = win;

    await nvim.winSetOption(win, 'cursorline', true);
    await nvim.winSetOption(win, 'wrap', false);
    final targetRow =
        (initialIndex >= 0 && initialIndex < lines.length) ? initialIndex + 1 : 1;
    await nvim.winSetCursor(win, targetRow, 0);
    await nvim.command('stopinsert');

    for (final mode in ['n', 'i']) {
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<LeftMouse>',
        "<LeftMouse><Cmd>lua require('vibrainium').action('agent.picker_click')<CR>",
      );
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<2-LeftMouse>',
        "<LeftMouse><Cmd>lua require('vibrainium').action('agent.picker_click')<CR>",
      );
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<CR>',
        "<Cmd>lua require('vibrainium').action('agent.picker_confirm')<CR>",
      );
      for (final cancelKey in ['<Esc>', '<C-c>']) {
        await nvim.bufSetKeymap(
          buf,
          mode,
          cancelKey,
          "<Cmd>lua require('vibrainium').action('agent.picker_close')<CR>",
        );
      }
    }
    await nvim.bufSetKeymap(
      buf,
      'n',
      'q',
      "<Cmd>lua require('vibrainium').action('agent.picker_close')<CR>",
    );

    for (var i = 0; i < items.length; i++) {
      final key = items[i].shortcut;
      if (key.isEmpty ||
          key == '<CR>' ||
          key == 'q' ||
          key == '<Esc>' ||
          key == '<C-c>') {
        continue;
      }
      await nvim.bufSetKeymap(
        buf,
        'n',
        key,
        "<Cmd>lua require('vibrainium').action('agent.picker_select:$i')<CR>",
      );
    }
  }

  Future<void> handleClick() async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) {
      await close();
      return;
    }
    final mousePos = await nvim.getMousePos();
    if (mousePos != null) {
      if (mousePos.winId != win) {
        await close();
        return;
      }
      if (mousePos.line >= 1 && mousePos.line <= _items.length) {
        await selectIndex(mousePos.line - 1);
        return;
      }
    }
    await confirm();
  }

  Future<void> confirm() async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) {
      await close();
      return;
    }
    final (row, _) = await nvim.winGetCursor(win);
    await selectIndex(row - 1);
  }

  Future<void> selectIndex(int index) async {
    final list = _items;
    await close();
    if (index >= 0 && index < list.length) {
      await list[index].onSelect();
    }
  }

  Future<void> close() async {
    nvim.clearOverlayCloser(close);
    final win = _win;
    _win = null;
    _buf = null;
    _items = const [];
    if (win != null) {
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }
}
