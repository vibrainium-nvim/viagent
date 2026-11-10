import 'dart:io';

import 'package:viff/viff.dart';

import '../hook_config.dart';
import '../models.dart';
import 'modals.dart';
import 'tree.dart';

/// Signature for spawning a terminal job inside buffer [buf] and returning its Neovim channel/job ID.
typedef AgentTerminalSpawner = Future<int> Function({
  required int buf,
  required List<String> command,
  required Map<String, String> env,
  required String cwd,
});

/// Main controller for the `viagent` bottom-panel tab (`Agents [2]`).
///
/// Manages:
/// - The left tree pane (`_treeWin`, `filetype=viagent`) listing all active chats
///   and expandable per-chat changed files.
/// - The right terminal pane (`_termWin`, `filetype=viagent-term`) displaying the
///   active chat's interactive TUI (`agy` or `claude`).
/// - Safe `@file#Lstart-Lend ` selection context injection via Bracketed Paste.
/// - Per-chat `PreToolUse` / `PostToolUse` baseline snapshots and `viff` diffing.
class AgentsPanel {
  final Nvim nvim;
  final int panelHeight;
  final int treeWidth;
  final Map<String, String> extraKeymaps;
  final String? socketPath;
  final String? devPackagePath;
  final Future<void> Function()? onAgentsUpdated;
  final Future<void> Function()? onRequestOpenPanel;
  late final ViffController viff;
  final AgentTerminalSpawner? _customSpawner;

  final AgentTreeState treeState = AgentTreeState();
  late final AgentInputPrompt _inputPrompt = AgentInputPrompt(nvim);
  late final AgentConfirmPrompt _confirmPrompt = AgentConfirmPrompt(nvim);
  late final AgentPickerModal _pickerModal = AgentPickerModal(nvim);
  late final AgentContextMenu _contextMenu = AgentContextMenu(nvim);

  static const Set<String> _nonEditorFiletypes = {
    'viworkspace',
    'viff',
    'viff-picker',
    'viff-menu',
    'vivcs',
    'vivcs-picker',
    'vivcs-menu',
    'viproblems',
    'viproblems-detail',
    'viagent',
    'viagent-term',
    'viagent-picker',
    'viagent-prompt',
    'viagent-confirm',
    'viagent-menu',
    'vibrainium-tabbar',
    'vibrainium-bottom-tabbar',
    'viworkspace-prompt',
    'viworkspace-confirm',
    'viworkspace-menu',
    'visearch-padding',
    'visearch-prompt',
    'visearch-results',
    'visearch-preview',
    'visearch-dropdown',
  };

  int? _nsId;
  int? _treeBuf;
  int? _treeWin;
  int? _termWin;
  int? _emptyTermBuf;
  int? _lastActiveEditorWin;
  Set<int> _excludedWindows = const {};
  bool _highlightsInitialized = false;

  final List<AgentChatSession> _sessions = [];
  String? _activeChatId;
  int _nextAgyNumber = 1;
  int _nextClaudeNumber = 1;
  int _nextSessionSeq = 1;

  RenderedAgentTree? _rendered;
  DateTime? _lastClickTime;
  int? _lastClickRow;
  DateTime? _lastDoubleClickTime;

  /// Records all payloads sent via [chanSend] for inspection in tests.
  final List<(int jobId, String data)> sentPayloads = [];

  AgentsPanel({
    required this.nvim,
    this.panelHeight = 12,
    this.treeWidth = 38,
    this.extraKeymaps = const {},
    this.socketPath,
    this.devPackagePath,
    this.onAgentsUpdated,
    this.onRequestOpenPanel,
    ViffController? viff,
    AgentTerminalSpawner? terminalSpawner,
    bool bindRpc = true,
  }) : _customSpawner = terminalSpawner {
    this.viff = viff ?? ViffController(nvim: nvim);
    if (bindRpc) {
      nvim.rpc.onRequest = _handleRpc;
      nvim.rpc.onNotification = (method, params) async {
        await _handleRpc(method, params);
      };
    }
  }

  int? get bufferId => _treeBuf;
  int? get windowId => _treeWin;
  int? get treeWindowId => _treeWin;
  int? get termWindowId => _termWin;
  int? get lastActiveEditorWin => _lastActiveEditorWin;
  List<AgentChatSession> get sessions => List.unmodifiable(_sessions);
  String? get activeChatId => _activeChatId;
  RenderedAgentTree? get renderedTree => _rendered;
  AgentInputPrompt get inputPrompt => _inputPrompt;
  AgentConfirmPrompt get confirmPrompt => _confirmPrompt;
  AgentPickerModal get pickerModal => _pickerModal;
  AgentContextMenu get contextMenu => _contextMenu;

  int get chatCount => _sessions.length;

  int get totalChangedFilesCount {
    var count = 0;
    for (final s in _sessions) {
      count += s.changedFiles.length;
    }
    return count;
  }

  AgentChatSession? get activeSession {
    final id = _activeChatId;
    if (id == null) return null;
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  AgentChatSession? findSession(String chatId) {
    for (final s in _sessions) {
      if (s.id == chatId) return s;
    }
    return null;
  }

  void attachWindow(
    int? win, {
    Set<int> excludedWins = const {},
    int? lastActiveEditorWin,
  }) {
    _treeWin = win;
    _excludedWindows = excludedWins;
    if (lastActiveEditorWin != null && lastActiveEditorWin > 0) {
      _lastActiveEditorWin = lastActiveEditorWin;
    }
    viff.updateWindowContext(
      excludedWins: {
        if (_treeWin != null) _treeWin!,
        if (_termWin != null) _termWin!,
        ..._excludedWindows,
      },
      lastActiveEditorWin: _lastActiveEditorWin,
    );
  }

  Future<bool> isOpen() async {
    final win = _treeWin;
    if (win == null) return false;
    return nvim.winIsValid(win);
  }

  Future<int> ensureBuffer() async {
    await _ensureHighlights();
    var buf = _treeBuf;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      buf = await nvim.createBuf(listed: false, scratch: true);
      _treeBuf = buf;
      await nvim.bufSetOption(buf, 'buftype', 'nofile');
      await nvim.bufSetOption(buf, 'bufhidden', 'hide');
      await nvim.bufSetOption(buf, 'swapfile', false);
      await nvim.bufSetOption(buf, 'filetype', 'viagent');
      await nvim.bufSetOption(buf, 'modifiable', false);
      try {
        await nvim.bufSetName(buf, 'viagent://chats');
      } catch (_) {}
      await _bindTreeKeys(buf);
    }
    return buf;
  }

  /// Ensures the right-hand terminal split (`_termWin`) exists next to `_treeWin`
  /// and displays the active chat's terminal buffer (or the empty placeholder buffer).
  Future<void> syncTerminalSplit({bool focusTerminal = false}) async {
    final treeWin = _treeWin;
    if (treeWin == null || !await nvim.winIsValid(treeWin)) return;

    await nvim.winSetOption(treeWin, 'winfixwidth', true);
    try {
      await nvim.rpc.request('nvim_win_set_width', [treeWin, treeWidth]);
    } catch (_) {}

    final targetTermBuf = await _resolveActiveTerminalBuffer();

    var termWin = _termWin;
    if (termWin == null || !await nvim.winIsValid(termWin)) {
      termWin = await nvim.openWin(targetTermBuf, false, {
        'win': treeWin,
        'split': 'right',
        'style': 'minimal',
      });
      _termWin = termWin;
      await _configureTermWin(termWin);
    } else {
      final currentBuf = await nvim.winGetBuf(termWin);
      if (currentBuf != targetTermBuf) {
        await nvim.winSetBuf(termWin, targetTermBuf);
      }
      await _configureTermWin(termWin);
    }

    try {
      await nvim.rpc.request('nvim_win_set_width', [treeWin, treeWidth]);
    } catch (_) {}

    if (focusTerminal && await nvim.winIsValid(termWin)) {
      await nvim.setCurrentWin(termWin);
    }
  }

  /// Closes the right-hand terminal split (`_termWin`) while keeping all
  /// underlying chat terminal buffers (`bufhidden=hide`) alive in the background.
  Future<void> closeTerminalSplit() async {
    final termWin = _termWin;
    _termWin = null;
    if (termWin != null && await nvim.winIsValid(termWin)) {
      try {
        await nvim.winClose(termWin, force: true);
      } catch (_) {}
    }
    final treeWin = _treeWin;
    if (treeWin != null && await nvim.winIsValid(treeWin)) {
      try {
        await nvim.winSetOption(treeWin, 'winfixwidth', false);
      } catch (_) {}
    }
  }

  Future<int> _resolveActiveTerminalBuffer() async {
    final active = activeSession;
    if (active != null &&
        active.terminalBufId != null &&
        await nvim.bufIsValid(active.terminalBufId!)) {
      return active.terminalBufId!;
    }
    return _ensureEmptyTermBuf();
  }

  Future<int> _ensureEmptyTermBuf() async {
    var buf = _emptyTermBuf;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      buf = await nvim.createBuf(listed: false, scratch: true);
      _emptyTermBuf = buf;
      await nvim.bufSetOption(buf, 'buftype', 'nofile');
      await nvim.bufSetOption(buf, 'bufhidden', 'hide');
      await nvim.bufSetOption(buf, 'swapfile', false);
      await nvim.bufSetOption(buf, 'filetype', 'viagent-term');
      await nvim.bufSetOption(buf, 'modifiable', true);
      await nvim.bufSetLines(
        buf,
        lines: const [
          '',
          '  󰚩 Vibrainium AI Agents',
          '  ────────────────────────────────────────────────────────',
          '  Press [a] to start a new Antigravity (agy) chat',
          '  Press [c] to start a new Claude Code (claude) chat',
          '  Press <leader>as in visual mode to send @file#Lstart-Lend',
        ],
      );
      await nvim.bufSetOption(buf, 'modifiable', false);
      await _bindCommonAgentBufferKeys(buf);
    }
    return buf;
  }

  Future<void> _configureTermWin(int win) async {
    await nvim.winSetOption(win, 'number', false);
    await nvim.winSetOption(win, 'relativenumber', false);
    await nvim.winSetOption(win, 'signcolumn', 'no');
    await nvim.winSetOption(win, 'foldcolumn', '0');
    await nvim.winSetOption(win, 'statuscolumn', '');
    await nvim.winSetOption(win, 'wrap', true);
    await nvim.winSetOption(win, 'cursorline', false);
    await nvim.winSetOption(win, 'winfixheight', true);
  }

  /// Creates and starts a new [AgentChatSession] for [provider].
  Future<AgentChatSession> createChat(
    AgentProviderKind provider, {
    String? customTitle,
    bool focusTerminal = false,
  }) async {
    final seq = _nextSessionSeq++;
    final numLabel = provider == AgentProviderKind.antigravity
        ? _nextAgyNumber++
        : _nextClaudeNumber++;
    final sessionId =
        'chat-$seq-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    final title = customTitle ?? '${provider.label} #$numLabel';

    final session = AgentChatSession(
      id: sessionId,
      provider: provider,
      title: title,
    );

    final cwd = await nvim.getCwd();
    if (provider == AgentProviderKind.antigravity &&
        socketPath != null &&
        socketPath!.isNotEmpty) {
      try {
        await AgentHookConfig.ensureAntigravityWorkspaceHooks(
          workspaceRoot: cwd,
          devPackagePath: devPackagePath,
        );
      } catch (_) {}
    }

    final termBuf = await nvim.createBuf(listed: false, scratch: true);
    await nvim.bufSetOption(termBuf, 'bufhidden', 'hide');
    await nvim.bufSetOption(termBuf, 'swapfile', false);
    await nvim.bufSetOption(termBuf, 'filetype', 'viagent-term');
    await _bindCommonAgentBufferKeys(termBuf);

    final spec = AgentHookConfig.buildSpawnSpec(
      session: session,
      socketPath: socketPath,
      devPackagePath: devPackagePath,
    );

    final spawner = _customSpawner ?? _defaultTerminalSpawner;
    final jobId = await spawner(
      buf: termBuf,
      command: spec.command,
      env: spec.env,
      cwd: cwd,
    );

    session.terminalBufId = termBuf;
    session.terminalJobId = jobId;

    _sessions.add(session);
    _activeChatId = session.id;

    if (await isOpen()) {
      await syncTerminalSplit(focusTerminal: focusTerminal);
      await render();
    }
    if (onAgentsUpdated != null) {
      await onAgentsUpdated!();
    }
    return session;
  }

  Future<int> _defaultTerminalSpawner({
    required int buf,
    required List<String> command,
    required Map<String, String> env,
    required String cwd,
  }) async {
    try {
      final res = await nvim.execLua(
        '''
local buf, cmd, env, cwd = ...
local job_id = 0
vim.api.nvim_buf_call(buf, function()
  local ok, jid = pcall(vim.fn.termopen, cmd, {
    cwd = cwd,
    env = env,
  })
  if ok and type(jid) == 'number' then
    job_id = jid
  end
end)
return job_id
''',
        [buf, command, env, cwd],
      );
      if (res is int) return res;
    } catch (_) {}
    return 0;
  }

  /// Selects [chatId] as the active chat and updates the terminal split.
  Future<void> selectChat(
    String chatId, {
    bool focusTerminal = false,
  }) async {
    final session = findSession(chatId);
    if (session == null) return;
    _activeChatId = session.id;
    if (await isOpen()) {
      await syncTerminalSplit(focusTerminal: focusTerminal);
      await render();
    }
    if (onAgentsUpdated != null) {
      await onAgentsUpdated!();
    }
  }

  /// Closes and removes [chatId], stopping its terminal job and deleting its buffer.
  Future<void> closeChat(String chatId) async {
    final idx = _sessions.indexWhere((s) => s.id == chatId);
    if (idx < 0) return;
    final removed = _sessions.removeAt(idx);

    final jobId = removed.terminalJobId;
    if (jobId != null && jobId > 0) {
      try {
        await nvim.execLua('pcall(vim.fn.jobstop, ...)', [jobId]);
      } catch (_) {}
    }

    if (_activeChatId == chatId) {
      if (_sessions.isNotEmpty) {
        final nextIdx = idx.clamp(0, _sessions.length - 1);
        _activeChatId = _sessions[nextIdx].id;
      } else {
        _activeChatId = null;
      }
    }

    if (await isOpen()) {
      await syncTerminalSplit(focusTerminal: false);
      await render();
    }

    final termBuf = removed.terminalBufId;
    if (termBuf != null && await nvim.bufIsValid(termBuf)) {
      try {
        await nvim.execLua(
          'pcall(vim.api.nvim_buf_delete, ..., { force = true })',
          [termBuf],
        );
      } catch (_) {}
    }

    if (onAgentsUpdated != null) {
      await onAgentsUpdated!();
    }
  }

  /// Safely sends a compact `@file#Lstart-Lend ` selection reference to [targetChat]
  /// (or the active chat) using Bracketed Paste with no trailing newline so it
  /// never auto-submits.
  Future<void> sendSelectionContext({
    String? filePath,
    int? startLine,
    int? endLine,
    String? targetChatId,
    bool promptForTargetChat = false,
  }) async {
    await _rememberActiveEditorWin();
    final resolved = await _resolveSelectionParams(
      filePath: filePath,
      startLine: startLine,
      endLine: endLine,
    );
    if (resolved == null) {
      await nvim.notify('[Vibrainium] No active file to send to agent', level: 3);
      return;
    }

    final cwd = await nvim.getCwd();
    final refToken = AgentPathUtils.formatSelectionReference(
      filePath: resolved.filePath,
      workspaceRoot: cwd,
      startLine: resolved.startLine,
      endLine: resolved.endLine,
    );

    if (targetChatId != null) {
      final session = findSession(targetChatId);
      if (session != null) {
        await _deliverReferenceToSession(session, refToken);
        return;
      }
    }

    if (promptForTargetChat || _sessions.isEmpty) {
      await _openTargetChatPickerForReference(refToken);
      return;
    }

    final target = activeSession ?? _sessions.first;
    await _deliverReferenceToSession(target, refToken);
  }

  Future<void> _openTargetChatPickerForReference(String refToken) async {
    final items = <AgentMenuItem>[
      for (final s in _sessions)
        AgentMenuItem(
          label:
              '${s.id == _activeChatId ? "●" : " "} ${s.provider.icon} ${s.title}',
          onSelect: () async {
            await _deliverReferenceToSession(s, refToken);
          },
        ),
      AgentMenuItem(
        label: '+ 󰚩 New Antigravity (agy) Chat',
        shortcut: 'a',
        onSelect: () async {
          final created = await createChat(AgentProviderKind.antigravity);
          await _deliverReferenceToSession(created, refToken);
        },
      ),
      AgentMenuItem(
        label: '+ 󰜡 New Claude Code (claude) Chat',
        shortcut: 'c',
        onSelect: () async {
          final created = await createChat(AgentProviderKind.claude);
          await _deliverReferenceToSession(created, refToken);
        },
      ),
    ];

    await _pickerModal.open(
      items: items,
      title: 'Send ${refToken.trim()} to Agent Chat',
    );
  }

  Future<void> _deliverReferenceToSession(
    AgentChatSession session,
    String refToken,
  ) async {
    _activeChatId = session.id;
    if (onRequestOpenPanel != null) {
      await onRequestOpenPanel!();
    } else if (!await isOpen()) {
      await open();
    } else {
      await syncTerminalSplit(focusTerminal: false);
      await render();
    }

    final jobId = session.terminalJobId;
    final payload = AgentPathUtils.wrapBracketedPaste(refToken);
    if (jobId != null && jobId > 0) {
      sentPayloads.add((jobId, payload));
      await nvim.chanSend(jobId, payload);
    }

    final termWin = _termWin;
    if (termWin != null && await nvim.winIsValid(termWin)) {
      await nvim.setCurrentWin(termWin);
    }
    await nvim.notify('Sent ${refToken.trim()} to ${session.title}');
  }

  Future<({String filePath, int? startLine, int? endLine})?>
      _resolveSelectionParams({
    String? filePath,
    int? startLine,
    int? endLine,
  }) async {
    if (filePath != null && filePath.trim().isNotEmpty) {
      return (
        filePath: filePath.trim(),
        startLine: startLine,
        endLine: endLine,
      );
    }

    final editorWin = _lastActiveEditorWin ?? await nvim.getCurrentWin();
    if (!await nvim.winIsValid(editorWin)) return null;
    final buf = await nvim.winGetBuf(editorWin);
    if (buf <= 0) return null;
    final name = await nvim.bufGetName(buf);
    if (name.trim().isEmpty) return null;

    final (cursorRow, _) = await nvim.winGetCursor(editorWin);
    return (
      filePath: name.trim(),
      startLine: startLine ?? cursorRow,
      endLine: endLine ?? startLine ?? cursorRow,
    );
  }

  /// Processes a `PreToolUse` or `PostToolUse` hook event emitted by `vibrainium agent-hook`.
  Future<void> handleHookEvent(ParsedAgentHookEvent event) async {
    final session = findSession(event.chatId);
    if (session == null) return;

    final cwd = await nvim.getCwd();
    if (event.phase == 'pre') {
      for (final path in event.filePaths) {
        final absPath = AgentPathUtils.resolvePath(path, cwd);
        await session.ensureBaseline(absPath);
      }
      return;
    }

    for (final path in event.filePaths) {
      final absPath = AgentPathUtils.resolvePath(path, cwd);
      await session.syncFileAfterEdit(absPath, workspaceRoot: cwd);
    }

    try {
      await nvim.command('checktime');
    } catch (_) {}

    if (await isOpen()) {
      await render();
    }
    if (onAgentsUpdated != null) {
      await onAgentsUpdated!();
    }
  }

  Future<void> open() async {
    await _rememberActiveEditorWin();
    await _ensureHighlights();
    if (!await isOpen()) {
      await _createStandalonePanelWin();
    }
    await syncTerminalSplit(focusTerminal: false);
    await refresh();
  }

  Future<void> toggle() async {
    if (await isOpen()) {
      await close();
    } else {
      await open();
    }
  }

  Future<void> closeModals() async {
    await _inputPrompt.close();
    await _confirmPrompt.close();
    await _pickerModal.close();
    await _contextMenu.close();
  }

  Future<void> close() async {
    await closeModals();
    await closeTerminalSplit();
    final win = _treeWin;
    _treeWin = null;
    if (win != null && await nvim.winIsValid(win)) {
      await nvim.winClose(win, force: true);
    }
  }

  Future<void> refresh() async {
    final cwd = await nvim.getCwd();
    for (final session in _sessions) {
      await session.refreshTrackedFiles(workspaceRoot: cwd);
    }
    await render();
    if (onAgentsUpdated != null) {
      await onAgentsUpdated!();
    }
  }

  Future<void> render() async {
    final buf = await ensureBuffer();
    final nsId = _nsId;
    if (nsId == null || !await nvim.bufIsValid(buf)) return;

    final rendered = treeState.build(
      sessions: _sessions,
      activeChatId: _activeChatId,
      width: treeWidth,
    );
    _rendered = rendered;

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: rendered.lines);
    await nvim.bufSetOption(buf, 'modifiable', false);

    await nvim.bufClearNamespace(buf, nsId);
    for (final hl in rendered.highlights) {
      await nvim.bufSetExtmark(buf, nsId, hl.line, hl.colStart, {
        'end_col': hl.colEnd,
        'hl_group': hl.group,
      });
    }
  }

  Future<void> onHotReloaded() async {
    _highlightsInitialized = false;
    nvim.resetRightMouseRouterForHotReload();
    final buf = _treeBuf;
    if (buf != null && await nvim.bufIsValid(buf)) {
      await _bindTreeKeys(buf);
    }
    for (final s in _sessions) {
      final tBuf = s.terminalBufId;
      if (tBuf != null && await nvim.bufIsValid(tBuf)) {
        await _bindCommonAgentBufferKeys(tBuf);
      }
    }
    if (await isOpen()) {
      await _ensureHighlights();
      await syncTerminalSplit(focusTerminal: false);
      await render();
    }
    await viff.onHotReloaded();
  }

  Future<Object?> handleAction(
    String rawAction, [
    List<Object?> params = const [],
  ]) async {
    final action = rawAction.startsWith('agent.')
        ? rawAction.substring('agent.'.length)
        : rawAction.startsWith('agents.')
            ? rawAction.substring('agents.'.length)
            : rawAction;

    if (action.startsWith('picker_select:')) {
      final idx = int.tryParse(action.substring('picker_select:'.length));
      if (idx != null) {
        await _pickerModal.selectIndex(idx);
      }
      return true;
    }
    if (action.startsWith('menu_select:')) {
      final idx = int.tryParse(action.substring('menu_select:'.length));
      if (idx != null) {
        await _contextMenu.selectIndex(idx);
      }
      return true;
    }

    switch (action) {
      case 'open':
        if (onRequestOpenPanel != null) {
          await onRequestOpenPanel!();
        } else {
          await open();
        }
        return true;
      case 'close':
        await close();
        return true;
      case 'toggle':
        await toggle();
        return true;
      case 'refresh':
        await refresh();
        return true;
      case 'new_antigravity':
      case 'new_agy':
        await createChat(AgentProviderKind.antigravity, focusTerminal: true);
        return true;
      case 'new_claude':
        await createChat(AgentProviderKind.claude, focusTerminal: true);
        return true;
      case 'new_picker':
        await openNewChatPicker();
        return true;
      case 'rename':
        await handleRenameChat();
        return true;
      case 'delete':
      case 'kill':
        await handleDeleteChat();
        return true;
      case 'focus_terminal':
        final termWin = _termWin;
        if (termWin != null && await nvim.winIsValid(termWin)) {
          await nvim.setCurrentWin(termWin);
        }
        return true;
      case 'focus_tree':
        final treeWin = _treeWin;
        if (treeWin != null && await nvim.winIsValid(treeWin)) {
          await nvim.setCurrentWin(treeWin);
        }
        return true;
      case 'enter':
        await handleEnter();
        return true;
      case 'diff_sbs':
        await handleOpenDiff(mode: DiffViewMode.sideBySide);
        return true;
      case 'open_plain':
        await handleOpenPlainFile();
        return true;
      case 'click':
        await handleClick(doubleClick: false);
        return true;
      case 'double_click':
        await handleClick(doubleClick: true);
        return true;
      case 'context_menu':
        final clickedPos = NvimMouseRouter.parseActionParams(params);
        await openContextMenu(mousePos: clickedPos);
        return true;
      case 'menu_click':
        await _contextMenu.handleClick();
        return true;
      case 'menu_confirm':
        await _contextMenu.confirm();
        return true;
      case 'menu_close':
        final expectedBuf =
            params.length > 1 ? int.tryParse(params[1]?.toString() ?? '') : null;
        await _contextMenu.cancel(expectedBufId: expectedBuf);
        return true;
      case 'send_selection':
        final filePath = params.length > 1 ? params[1]?.toString() : null;
        final startLine =
            params.length > 2 ? int.tryParse(params[2].toString()) : null;
        final endLine =
            params.length > 3 ? int.tryParse(params[3].toString()) : null;
        await sendSelectionContext(
          filePath: filePath,
          startLine: startLine,
          endLine: endLine,
          promptForTargetChat: false,
        );
        return true;
      case 'send_selection_to':
        final filePath = params.length > 1 ? params[1]?.toString() : null;
        final startLine =
            params.length > 2 ? int.tryParse(params[2].toString()) : null;
        final endLine =
            params.length > 3 ? int.tryParse(params[3].toString()) : null;
        await sendSelectionContext(
          filePath: filePath,
          startLine: startLine,
          endLine: endLine,
          promptForTargetChat: true,
        );
        return true;
      case 'send_file':
        final filePath = params.length > 1 ? params[1]?.toString() : null;
        await sendSelectionContext(
          filePath: filePath,
          promptForTargetChat: false,
        );
        return true;
      case 'prompt_submit':
        await _inputPrompt.submit();
        return true;
      case 'prompt_close':
        await _inputPrompt.close();
        return true;
      case 'confirm_yes':
        await _confirmPrompt.confirm();
        return true;
      case 'confirm_no':
        await _confirmPrompt.close();
        return true;
      case 'picker_click':
        await _pickerModal.handleClick();
        return true;
      case 'picker_confirm':
        await _pickerModal.confirm();
        return true;
      case 'picker_close':
        await _pickerModal.close();
        return true;
      case 'hook':
        if (params.length >= 4) {
          final phase = params[1]?.toString() ?? 'post';
          final chatId = params[2]?.toString() ?? '';
          final prov = AgentProviderKind.fromString(
            params[3]?.toString() ?? 'agy',
          );
          final rawJson = params.length > 4 ? params[4]?.toString() ?? '' : '';
          final parsed = AgentHookConfig.parseHookStdin(
            rawJson: rawJson,
            phase: phase,
            chatId: chatId,
            provider: prov,
          );
          if (parsed != null) {
            await handleHookEvent(parsed);
          }
        }
        return true;
      default:
        return null;
    }
  }

  Future<Object?> _handleRpc(String method, List<Object?> params) async {
    if (method == 'vibrainium_agent_hook' && params.length >= 3) {
      final phase = params[0]?.toString() ?? 'post';
      final chatId = params[1]?.toString() ?? '';
      final prov = AgentProviderKind.fromString(params[2]?.toString() ?? 'agy');
      final rawJson = params.length > 3 ? params[3]?.toString() ?? '' : '';
      final parsed = AgentHookConfig.parseHookStdin(
        rawJson: rawJson,
        phase: phase,
        chatId: chatId,
        provider: prov,
      );
      if (parsed != null) {
        await handleHookEvent(parsed);
      }
      return true;
    }

    final action =
        (method == 'vibrainium_action' || method == 'viagent_action') &&
                params.isNotEmpty
            ? params.first.toString()
            : method;
    return handleAction(action, params);
  }

  Future<AgentTreeNode?> _nodeUnderCursor() async {
    final win = _treeWin;
    final rendered = _rendered;
    if (win == null || rendered == null || !await nvim.winIsValid(win)) {
      return null;
    }
    final (row1, _) = await nvim.winGetCursor(win);
    final idx = row1 - 1;
    if (idx < 0 || idx >= rendered.nodes.length) return null;
    return rendered.nodes[idx];
  }

  Future<AgentChatSession?> _sessionUnderCursorOrActive() async {
    final node = await _nodeUnderCursor();
    return switch (node) {
      AgentChatHeaderNode(:final session) => session,
      AgentChangedFileNode(:final session) => session,
      AgentEmptyNode(:final session) => session ?? activeSession,
      _ => activeSession,
    };
  }

  Future<void> handleEnter() async {
    final win = _treeWin;
    if (win == null || !await nvim.winIsValid(win)) return;
    final node = await _nodeUnderCursor();
    if (node == null) return;

    switch (node) {
      case AgentToolbarNode(:final claudeColStart):
        final (_, col0) = await nvim.winGetCursor(win);
        if (col0 >= claudeColStart) {
          await createChat(AgentProviderKind.claude, focusTerminal: true);
        } else {
          await createChat(AgentProviderKind.antigravity, focusTerminal: true);
        }
      case AgentChatHeaderNode(:final session):
        if (_activeChatId == session.id) {
          session.expanded = !session.expanded;
        } else {
          _activeChatId = session.id;
          session.expanded = true;
          await syncTerminalSplit(focusTerminal: false);
        }
        await render();
      case AgentChangedFileNode(:final session, :final file):
        await _openDiffForChangedFile(session, file);
      case AgentDividerNode() || AgentEmptyNode():
        break;
    }
  }

  Future<void> handleOpenDiff({DiffViewMode? mode}) async {
    final node = await _nodeUnderCursor();
    if (node is AgentChangedFileNode) {
      await _openDiffForChangedFile(node.session, node.file, mode: mode);
    }
  }

  Future<void> handleOpenPlainFile() async {
    final node = await _nodeUnderCursor();
    if (node is! AgentChangedFileNode) return;
    await _rememberActiveEditorWin();
    final targetWin = await _resolveEditorWin();
    if (targetWin == null) return;
    await nvim.setCurrentWin(targetWin);
    final escaped = node.file.filePath.replaceAll(' ', r'\ ');
    await nvim.command('edit $escaped');
  }

  Future<void> _openDiffForChangedFile(
    AgentChatSession session,
    AgentChangedFile changed, {
    DiffViewMode? mode,
  }) async {
    await _rememberActiveEditorWin();
    final cwd = await nvim.getCwd();
    final diskFile = File(changed.filePath);
    final existsNow = await diskFile.exists();

    viff.updateWindowContext(
      excludedWins: {
        if (_treeWin != null) _treeWin!,
        if (_termWin != null) _termWin!,
        ..._excludedWindows,
      },
      lastActiveEditorWin: _lastActiveEditorWin,
    );

    final target = AgentChatDiffTarget(
      chatId: session.id,
      chatTitle: session.title,
      providerName: session.provider.label,
      filePath: changed.filePath,
      workspaceRoot: cwd,
      fileExistsOnDisk: existsNow,
      onRefreshAgent: () async {
        await session.syncFileAfterEdit(changed.filePath, workspaceRoot: cwd);
        if (await isOpen()) {
          await render();
        }
        if (onAgentsUpdated != null) {
          await onAgentsUpdated!();
        }
      },
    );

    await viff.openDiff(
      target: target,
      mode: mode,
      loadOldLines: () async {
        final baseline = session.baselines[changed.filePath];
        if (baseline == null || !baseline.existedBefore) {
          return const [];
        }
        return baseline.lines;
      },
      loadNewLines: () async {
        final f = File(changed.filePath);
        if (!await f.exists()) return const [];
        return DiffEngine.splitLines(await f.readAsString());
      },
    );
  }

  Future<void> handleClick({required bool doubleClick}) async {
    await _rememberActiveEditorWin();
    final win = _treeWin;
    if (win == null || !await nvim.winIsValid(win)) return;

    int? clickedCol0;
    final mousePos = await nvim.getMousePos();
    if (mousePos != null && mousePos.winId > 0 && mousePos.winId != win) {
      return;
    }
    final maxLine = (_rendered?.nodes.length ?? 1).clamp(1, 999999);
    if (mousePos != null && mousePos.winId == win && mousePos.line >= 1) {
      final targetLine = mousePos.line.clamp(1, maxLine);
      final col0 = (mousePos.column > 0 ? mousePos.column - 1 : 0).clamp(0, 999);
      clickedCol0 = col0;
      await nvim.setCurrentWin(win);
      await nvim.winSetCursor(win, targetLine, col0);
    }

    final (row1, cursorCol0) = await nvim.winGetCursor(win);
    final node = await _nodeUnderCursor();
    final now = DateTime.now();

    if (node is AgentToolbarNode) {
      final col = clickedCol0 ?? cursorCol0;
      if (col >= node.claudeColStart) {
        await createChat(AgentProviderKind.claude, focusTerminal: true);
      } else {
        await createChat(AgentProviderKind.antigravity, focusTerminal: true);
      }
      return;
    }

    if (node is AgentChatHeaderNode && !doubleClick) {
      await selectChat(node.session.id, focusTerminal: false);
    }

    if (!doubleClick) {
      if (_lastClickRow == row1 &&
          _lastClickTime != null &&
          now.difference(_lastClickTime!) <=
              const Duration(milliseconds: 400)) {
        _lastClickTime = null;
        _lastClickRow = null;
        _lastDoubleClickTime = now;
        await handleEnter();
        return;
      }
      _lastClickRow = row1;
      _lastClickTime = now;
      return;
    }

    _lastClickTime = null;
    _lastClickRow = null;
    if (_lastDoubleClickTime != null &&
        now.difference(_lastDoubleClickTime!) <=
            const Duration(milliseconds: 250)) {
      return;
    }
    _lastDoubleClickTime = now;
    await handleEnter();
  }

  Future<void> openNewChatPicker() async {
    await _pickerModal.open(
      title: 'Start New Agent Chat',
      items: [
        AgentMenuItem(
          label: '󰚩 Antigravity (agy)',
          shortcut: 'a',
          onSelect: () async {
            await createChat(AgentProviderKind.antigravity, focusTerminal: true);
          },
        ),
        AgentMenuItem(
          label: '󰜡 Claude Code (claude)',
          shortcut: 'c',
          onSelect: () async {
            await createChat(AgentProviderKind.claude, focusTerminal: true);
          },
        ),
      ],
    );
  }

  Future<void> handleRenameChat() async {
    final session = await _sessionUnderCursorOrActive();
    if (session == null) return;
    await _inputPrompt.open(
      title: 'Rename Chat',
      initialValue: session.title,
      onSubmit: (newTitle) async {
        session.title = newTitle;
        await render();
      },
    );
  }

  Future<void> handleDeleteChat() async {
    final session = await _sessionUnderCursorOrActive();
    if (session == null) return;
    await _confirmPrompt.open(
      message: 'Close chat "${session.title}"?',
      onConfirm: () async {
        await closeChat(session.id);
      },
    );
  }

  Future<void> openContextMenu({MousePosition? mousePos}) async {
    await _rememberActiveEditorWin();
    await _contextMenu.close();
    final win = _treeWin;
    var winRow = 1;
    if (win != null && await nvim.winIsValid(win)) {
      final resolvedMouse = mousePos ?? await nvim.getMousePos();
      final maxLine = (_rendered?.nodes.length ?? 1).clamp(1, 999999);
      if (resolvedMouse != null) {
        if (resolvedMouse.winId == win &&
            (resolvedMouse.line >= 1 || resolvedMouse.winRow >= 1)) {
          final targetLine = resolvedMouse.line >= 1
              ? resolvedMouse.line.clamp(1, maxLine)
              : maxLine;
          await nvim.setCurrentWin(win);
          await nvim.winSetCursor(win, targetLine, 0);
          winRow = resolvedMouse.winRow > 0 ? resolvedMouse.winRow : targetLine;
        } else if (resolvedMouse.winId > 0 &&
            resolvedMouse.winId != win &&
            await nvim.winIsValid(resolvedMouse.winId)) {
          return;
        } else if (resolvedMouse.screenRow > 0) {
          final (winTop0, _) = await nvim.winGetPosition(win);
          final topLine = await nvim.winGetTopLine(win);
          winRow = (resolvedMouse.screenRow - winTop0).clamp(1, 999);
          final targetLine = (topLine + winRow - 1).clamp(1, maxLine);
          await nvim.setCurrentWin(win);
          await nvim.winSetCursor(win, targetLine, 0);
        } else {
          final (row1, _) = await nvim.winGetCursor(win);
          winRow = row1;
        }
      } else {
        final (row1, _) = await nvim.winGetCursor(win);
        winRow = row1;
      }
    }

    final node = await _nodeUnderCursor();
    final session = await _sessionUnderCursorOrActive();
    final items = <AgentMenuItem>[
      if (node is AgentChangedFileNode) ...[
        AgentMenuItem(
          label: 'Open Per-Chat Diff',
          shortcut: '<CR>',
          onSelect: () => _openDiffForChangedFile(node.session, node.file),
        ),
        AgentMenuItem(
          label: 'Open Side-by-Side Diff',
          shortcut: 'D',
          onSelect: () => _openDiffForChangedFile(
            node.session,
            node.file,
            mode: DiffViewMode.sideBySide,
          ),
        ),
        AgentMenuItem(
          label: 'Open File in Editor',
          shortcut: 'o',
          onSelect: handleOpenPlainFile,
        ),
      ],
      AgentMenuItem(
        label: 'New Antigravity Chat',
        shortcut: 'a',
        onSelect: () =>
            createChat(AgentProviderKind.antigravity, focusTerminal: true),
      ),
      AgentMenuItem(
        label: 'New Claude Code Chat',
        shortcut: 'c',
        onSelect: () =>
            createChat(AgentProviderKind.claude, focusTerminal: true),
      ),
      if (session != null) ...[
        AgentMenuItem(
          label: 'Rename "${session.title}"',
          shortcut: 'r',
          onSelect: handleRenameChat,
        ),
        AgentMenuItem(
          label: 'Close "${session.title}"',
          shortcut: 'x',
          onSelect: handleDeleteChat,
        ),
      ],
    ];
    await _contextMenu.open(
      items: items,
      title: 'Agent Actions',
      anchorWin: (win != null && await nvim.winIsValid(win)) ? win : null,
      row: winRow,
      col: 2,
      onCancel: () async {
        if (win != null && await nvim.winIsValid(win)) {
          await nvim.setCurrentWin(win);
        }
      },
    );
  }

  Future<void> _createStandalonePanelWin() async {
    final buf = await ensureBuffer();
    final win = await nvim.openWin(buf, true, {
      'split': 'below',
      'height': panelHeight,
      'style': 'minimal',
    });
    _treeWin = win;
    await nvim.winSetOption(win, 'number', false);
    await nvim.winSetOption(win, 'relativenumber', false);
    await nvim.winSetOption(win, 'signcolumn', 'no');
    await nvim.winSetOption(win, 'foldcolumn', '0');
    await nvim.winSetOption(win, 'statuscolumn', '');
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetOption(win, 'cursorline', true);
    await nvim.winSetOption(win, 'winfixheight', true);
  }

  Future<bool> _isEditorCandidateWin(int? win) async {
    if (win == null || win <= 0) return false;
    if (win == _treeWin ||
        win == _termWin ||
        _excludedWindows.contains(win)) {
      return false;
    }
    if (!await nvim.winIsValid(win)) return false;
    final config = await nvim.winGetConfig(win);
    final relative = config['relative']?.toString() ?? '';
    if (relative.isNotEmpty) return false;
    final buf = await nvim.winGetBuf(win);
    if (buf > 0) {
      final ft = (await nvim.bufGetOption(buf, 'filetype'))?.toString() ?? '';
      if (_nonEditorFiletypes.contains(ft)) return false;
      final bt = (await nvim.bufGetOption(buf, 'buftype'))?.toString() ?? '';
      if (bt == 'terminal') return false;
    }
    return true;
  }

  Future<void> _rememberActiveEditorWin() async {
    final cur = await nvim.getCurrentWin();
    if (await _isEditorCandidateWin(cur)) {
      _lastActiveEditorWin = cur;
      return;
    }
    final alt = await nvim.getAlternateWin();
    if (await _isEditorCandidateWin(alt)) {
      _lastActiveEditorWin = alt;
    }
  }

  Future<int?> _resolveEditorWin() async {
    if (await _isEditorCandidateWin(_lastActiveEditorWin)) {
      return _lastActiveEditorWin;
    }
    final wins = await nvim.listWins();
    for (final w in wins) {
      if (await _isEditorCandidateWin(w)) {
        _lastActiveEditorWin = w;
        return w;
      }
    }
    return null;
  }

  Future<void> _bindTreeKeys(int buf) async {
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<LeftMouse>',
      "<LeftMouse><Cmd>lua require('vibrainium').action('agent.click')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<2-LeftMouse>',
      "<LeftMouse><Cmd>lua require('vibrainium').action('agent.double_click')<CR>",
    );
    await nvim.registerRightClickBuffer(buf, 'agent.context_menu');

    final mappings = <String, String>{
      '<CR>': 'agent.enter',
      'D': 'agent.diff_sbs',
      'o': 'agent.open_plain',
      'a': 'agent.new_antigravity',
      'c': 'agent.new_claude',
      'n': 'agent.new_picker',
      'r': 'agent.rename',
      'x': 'agent.delete',
      'd': 'agent.delete',
      'i': 'agent.focus_terminal',
      '<C-l>': 'agent.focus_terminal',
      'R': 'agent.refresh',
      'q': 'agent.close',
      ...extraKeymaps,
    };

    for (final entry in mappings.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<Cmd>lua require('vibrainium').action('${entry.value}')<CR>",
      );
    }
  }

  Future<void> _bindCommonAgentBufferKeys(int buf) async {
    for (final entry in extraKeymaps.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<Cmd>lua require('vibrainium').action('${entry.value}')<CR>",
      );
    }
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<C-h>',
      "<Cmd>lua require('vibrainium').action('agent.focus_tree')<CR>",
    );
  }

  Future<void> _ensureHighlights() async {
    _nsId ??= await nvim.createNamespace('viagent_panel');
    if (_highlightsInitialized) return;
    _highlightsInitialized = true;

    const groups = <String, Map<String, Object?>>{
      'ViagentToolbarButton': {'bold': true, 'link': 'Title'},
      'ViagentDivider': {'link': 'WinSeparator'},
      'ViagentChatActiveIndicator': {'bold': true, 'link': 'DiagnosticOk'},
      'ViagentChatInactive': {'link': 'Comment'},
      'ViagentChatTitleActive': {'bold': true, 'link': 'Function'},
      'ViagentChatTitle': {'link': 'Normal'},
      'ViagentCountBadge': {'link': 'Number'},
      'ViagentFileIcon': {'link': 'Directory'},
      'ViagentFilePath': {'link': 'Normal'},
      'ViagentStatusAdded': {'bold': true, 'link': 'DiagnosticOk'},
      'ViagentStatusModified': {'bold': true, 'link': 'DiagnosticWarn'},
      'ViagentStatusDeleted': {'bold': true, 'link': 'DiagnosticError'},
      'ViagentEmptyHint': {'italic': true, 'link': 'Comment'},
    };

    for (final entry in groups.entries) {
      await nvim.setHl(0, entry.key, entry.value);
    }
  }
}
