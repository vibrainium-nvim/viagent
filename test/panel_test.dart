import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:viagent/viagent.dart';

class _FakeNvimServer {
  final StreamController<List<int>> _toClient = StreamController<List<int>>();
  final StreamController<List<int>> _fromClient = StreamController<List<int>>();
  late final RpcSession serverSession;
  late final RpcSession clientSession;

  String cwd;
  int _nextBuf = 1;
  int _nextWin = 100;
  final Map<int, List<String>> bufLines = {1: ['line 1', 'line 2']};
  final Map<int, String> bufNames = {};
  final Map<int, Map<String, Object?>> bufOptions = {};
  final Map<int, Map<String, Object?>> bufVars = {};
  final Map<int, Map<String, String>> bufKeymaps = {};
  final Map<int, List<Map<String, Object?>>> bufExtmarks = {};
  final Set<int> validWins = {1};
  final Map<int, int> winBufs = {1: 1};
  final Map<int, Map<String, Object?>> winConfigs = {};
  final Map<int, Map<String, Object?>> winOptions = {};
  final Map<int, (int, int)> cursors = {1: (1, 0)};
  final List<String> notifications = [];
  final List<String> commands = [];
  final List<(int, String)> chanSent = [];
  int currentWin = 1;

  _FakeNvimServer({required this.cwd}) {
    bufNames[1] = '$cwd/lib/main.dart';
    serverSession = RpcSession(
      input: _fromClient.stream,
      output: (Uint8List b) => _toClient.add(b),
    );
    clientSession = RpcSession(
      input: _toClient.stream,
      output: (Uint8List b) => _fromClient.add(b),
    );
    serverSession.onRequest = _handleRequest;
  }

  Future<Object?> _handleRequest(String method, List<Object?> params) async {
    switch (method) {
      case 'nvim_create_namespace':
        return 1;
      case 'nvim_set_hl':
        return null;
      case 'nvim_create_buf':
        final id = _nextBuf++;
        bufLines[id] = [];
        bufKeymaps[id] = {};
        bufExtmarks[id] = [];
        return MsgpackExt(0, MsgpackCodec.encode(id));
      case 'nvim_buf_is_valid':
        return bufLines.containsKey(params[0] as int);
      case 'nvim_buf_set_lines':
        final buf = params[0] as int;
        final lines = (params[4] as List).map((e) => e.toString()).toList();
        bufLines[buf] = lines;
        return null;
      case 'nvim_buf_get_lines':
        final buf = params[0] as int;
        return bufLines[buf] ?? const <String>[];
      case 'nvim_set_option_value':
        final name = params[0].toString();
        final value = params[1];
        final opts = (params[2] as Map).cast<String, Object?>();
        if (opts.containsKey('win')) {
          final win = opts['win'] as int;
          winOptions.putIfAbsent(win, () => {})[name] = value;
        } else if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          bufOptions.putIfAbsent(buf, () => {})[name] = value;
        }
        return null;
      case 'nvim_get_option_value':
        final name = params[0].toString();
        final opts = (params[1] as Map).cast<String, Object?>();
        if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          return bufOptions[buf]?[name] ?? '';
        }
        if (name == 'columns') return 120;
        if (name == 'lines') return 40;
        return '';
      case 'nvim_buf_set_var':
        final buf = params[0] as int;
        bufVars.putIfAbsent(buf, () => {})[params[1].toString()] = params[2];
        return null;
      case 'nvim_buf_set_keymap':
        final buf = params[0] as int;
        final lhs = params[2].toString();
        final rhs = params[3].toString();
        bufKeymaps.putIfAbsent(buf, () => {})[lhs] = rhs;
        return null;
      case 'nvim_buf_clear_namespace':
        final buf = params[0] as int;
        bufExtmarks[buf] = [];
        return null;
      case 'nvim_buf_set_extmark':
        final buf = params[0] as int;
        final line = params[2] as int;
        final col = params[3] as int;
        final opts = (params[4] as Map).cast<String, Object?>();
        bufExtmarks.putIfAbsent(buf, () => []).add({
          'line': line,
          'col': col,
          ...opts,
        });
        return 1;
      case 'nvim_open_win':
        final buf = params[0] as int;
        final enter = params[1] as bool;
        final config = (params[2] as Map).cast<String, Object?>();
        final win = _nextWin++;
        validWins.add(win);
        winBufs[win] = buf;
        winConfigs[win] = config;
        cursors[win] = (1, 0);
        if (enter) currentWin = win;
        return MsgpackExt(1, MsgpackCodec.encode(win));
      case 'nvim_win_is_valid':
        return validWins.contains(params[0] as int);
      case 'nvim_win_close':
        validWins.remove(params[0] as int);
        winBufs.remove(params[0] as int);
        return null;
      case 'nvim_win_set_buf':
        final win = params[0] as int;
        final buf = params[1] as int;
        winBufs[win] = buf;
        return null;
      case 'nvim_win_get_buf':
        return winBufs[params[0] as int] ?? 0;
      case 'nvim_win_get_config':
        return winConfigs[params[0] as int] ?? const <String, Object?>{};
      case 'nvim_win_set_width':
        return null;
      case 'nvim_get_current_win':
        return MsgpackExt(1, MsgpackCodec.encode(currentWin));
      case 'nvim_set_current_win':
        currentWin = params[0] as int;
        return null;
      case 'nvim_list_wins':
        return validWins
            .map((w) => MsgpackExt(1, MsgpackCodec.encode(w)))
            .toList();
      case 'nvim_win_get_cursor':
        final win = params[0] as int;
        final c = cursors[win] ?? (1, 0);
        return [c.$1, c.$2];
      case 'nvim_win_set_cursor':
        final win = params[0] as int;
        final pos = params[1] as List;
        cursors[win] = (pos[0] as int, pos[1] as int);
        return null;
      case 'nvim_buf_get_name':
        final buf = params[0] as int;
        return bufNames[buf] ?? '';
      case 'nvim_buf_set_name':
        final buf = params[0] as int;
        bufNames[buf] = params[1].toString();
        return null;
      case 'nvim_call_function':
        final fn = params[0].toString();
        if (fn == 'getcwd') return cwd;
        if (fn == 'winnr') return 0;
        return null;
      case 'nvim_command':
        commands.add(params[0].toString());
        return null;
      case 'nvim_notify':
        notifications.add(params[0].toString());
        return null;
      case 'nvim_chan_send':
        chanSent.add((params[0] as int, params[1].toString()));
        return null;
      case 'nvim_exec_lua':
        return null;
      default:
        return null;
    }
  }
}

void main() {
  group('AgentsPanel', () {
    late Directory tempDir;
    late _FakeNvimServer fakeServer;
    late AgentsPanel panel;
    var nextJobId = 500;
    final spawnedJobs = <({int buf, List<String> cmd, Map<String, String> env})>[];

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('viagent_panel_test_');
      fakeServer = _FakeNvimServer(cwd: tempDir.path);
      nextJobId = 500;
      spawnedJobs.clear();

      panel = AgentsPanel(
        nvim: Nvim(fakeServer.clientSession),
        socketPath: '/tmp/test-viagent.sock',
        terminalSpawner: ({
          required buf,
          required command,
          required env,
          required cwd,
        }) async {
          spawnedJobs.add((buf: buf, cmd: command, env: env));
          return nextJobId++;
        },
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('supports multiple agent chats (Antigravity & Claude Code) and swaps terminal split buffer', () async {
      await panel.open();
      expect(panel.treeWindowId, isNotNull);
      expect(panel.termWindowId, isNotNull);

      final agyChat = await panel.createChat(AgentProviderKind.antigravity);
      final claudeChat = await panel.createChat(AgentProviderKind.claude);

      expect(panel.sessions, hasLength(2));
      expect(panel.activeChatId, claudeChat.id);
      expect(fakeServer.winBufs[panel.termWindowId!], claudeChat.terminalBufId);

      // Switch back to Antigravity chat
      await panel.selectChat(agyChat.id);
      expect(panel.activeChatId, agyChat.id);
      expect(fakeServer.winBufs[panel.termWindowId!], agyChat.terminalBufId);
    });

    test('safely sends compact @file#Lstart-Lend selection context via bracketed paste without newline', () async {
      await panel.open();
      final agyChat = await panel.createChat(AgentProviderKind.antigravity);

      await panel.handleAction('agent.send_selection', [
        'agent.send_selection',
        '${tempDir.path}/lib/main.dart',
        12,
        28,
      ]);

      expect(fakeServer.chanSent, hasLength(1));
      final (jobId, payload) = fakeServer.chanSent.single;
      expect(jobId, agyChat.terminalJobId);
      expect(payload, '\x1b[200~@lib/main.dart#L12-L28 \x1b[201~');
      expect(payload.contains('\n'), isFalse);
      expect(payload.contains('\r'), isFalse);
    });

    test('tracks per-chat changed files via PreToolUse/PostToolUse hooks and opens pre-chat baseline diff in viff', () async {
      final targetFile = File('${tempDir.path}/lib/feature.dart');
      await targetFile.parent.create(recursive: true);
      await targetFile.writeAsString('void feature() {\n  print("v1");\n}\n');

      await panel.open();
      final chat1 = await panel.createChat(AgentProviderKind.antigravity);
      final chat2 = await panel.createChat(AgentProviderKind.claude);

      // Chat 1 modifies feature.dart from v1 -> v2
      final hookJson1 = jsonEncode({
        'toolCall': {
          'name': 'edit_file',
          'args': {'Path': targetFile.path},
        },
      });
      await panel.handleAction('agent.hook', [
        'agent.hook',
        'pre',
        chat1.id,
        'agy',
        hookJson1,
      ]);
      await targetFile.writeAsString('void feature() {\n  print("v2 by agy");\n}\n');
      await panel.handleAction('agent.hook', [
        'agent.hook',
        'post',
        chat1.id,
        'agy',
        hookJson1,
      ]);

      expect(chat1.changedFiles, hasLength(1));
      expect(chat2.changedFiles, isEmpty);

      // Now Chat 2 modifies feature.dart from v2 -> v3
      final hookJson2 = jsonEncode({
        'tool_name': 'Edit',
        'tool_input': {'file_path': targetFile.path},
      });
      await panel.handleAction('agent.hook', [
        'agent.hook',
        'pre',
        chat2.id,
        'claude',
        hookJson2,
      ]);
      await targetFile.writeAsString('void feature() {\n  print("v3 by claude");\n}\n');
      await panel.handleAction('agent.hook', [
        'agent.hook',
        'post',
        chat2.id,
        'claude',
        hookJson2,
      ]);

      // Chat 1 baseline is v1, while Chat 2 baseline is v2!
      final normPath = AgentPathUtils.normalizePath(targetFile.path);
      expect(chat1.baselines[normPath]!.lines[1], '  print("v1");');
      expect(chat2.baselines[normPath]!.lines[1], '  print("v2 by agy");');

      // Find the row of chat2's changed file in the rendered tree and press <CR>
      final rendered = panel.renderedTree!;
      final fileRowIdx = rendered.nodes.indexWhere(
        (n) => n is AgentChangedFileNode && n.session.id == chat2.id,
      );
      expect(fileRowIdx, greaterThan(0));
      fakeServer.cursors[panel.treeWindowId!] = (fileRowIdx + 1, 0);

      await panel.handleEnter();

      // Verify viff opened AgentChatDiffTarget for Chat 2
      expect(panel.viff.activeTarget, isA<AgentChatDiffTarget>());
      final diffTarget = panel.viff.activeTarget as AgentChatDiffTarget;
      expect(diffTarget.chatId, chat2.id);
      expect(panel.viff.hunks, hasLength(1));
      expect(panel.viff.hunks.first.oldLines, ['  print("v2 by agy");']);
      expect(panel.viff.hunks.first.newLines, ['  print("v3 by claude");']);
    });

    test('opens floating context menu on cross-window right-click and ignores stale menu_close buffer IDs', () async {
      await panel.open();
      final chat = await panel.createChat(AgentProviderKind.antigravity);
      final treeWin = panel.treeWindowId!;
      final treeBuf = fakeServer.winBufs[treeWin]!;

      expect(
        fakeServer.bufVars[treeBuf]!['vibrainium_right_mouse_action'],
        'agent.context_menu',
      );
      expect(fakeServer.bufKeymaps[treeBuf]!.keys, isNot(contains('<RightMouse>')));

      final chatRow = panel.renderedTree!.nodes.indexWhere(
        (n) => n is AgentChatHeaderNode && n.session.id == chat.id,
      ) + 1;
      fakeServer.currentWin = panel.termWindowId!;
      fakeServer.cursors[treeWin] = (1, 0);

      await panel.handleAction('agent.context_menu', [
        'agent.context_menu',
        treeWin,
        chatRow,
        chatRow,
        4,
        chatRow,
        4,
      ]);
      expect(panel.contextMenu.isOpen, isTrue);
      expect(fakeServer.cursors[treeWin], (chatRow, 0));
      final firstMenuBuf = panel.contextMenu.bufferId!;

      // Reopen context menu and verify stale menu_close from firstMenuBuf is ignored
      await panel.handleAction('agent.context_menu', [
        'agent.context_menu',
        treeWin,
        chatRow,
        chatRow,
        4,
        chatRow,
        4,
      ]);
      final secondMenuBuf = panel.contextMenu.bufferId!;
      expect(secondMenuBuf, isNot(firstMenuBuf));

      await panel.handleAction('agent.menu_close', ['agent.menu_close', firstMenuBuf]);
      expect(panel.contextMenu.isOpen, isTrue);

      await panel.handleAction('agent.menu_close', ['agent.menu_close', secondMenuBuf]);
      expect(panel.contextMenu.isOpen, isFalse);
    });
  });
}
