import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Parsed payload from an Antigravity (`agy`) or Claude Code (`claude`)
/// `PreToolUse` or `PostToolUse` lifecycle hook.
class ParsedAgentHookEvent {
  final String phase; // 'pre' or 'post'
  final String chatId;
  final AgentProviderKind provider;
  final String toolName;
  final List<String> filePaths;

  const ParsedAgentHookEvent({
    required this.phase,
    required this.chatId,
    required this.provider,
    required this.toolName,
    required this.filePaths,
  });
}

/// Builds CLI launch configurations and parses lifecycle hook payloads for
/// Antigravity (`agy`) and Claude Code (`claude`).
class AgentHookConfig {
  /// Extracts target file paths and tool name from a raw hook stdin JSON string.
  /// Supports both Antigravity (`toolCall.name`, `toolCall.args.Path`) and
  /// Claude Code (`tool_name`, `tool_input.file_path`).
  static ParsedAgentHookEvent? parseHookStdin({
    required String rawJson,
    required String phase,
    required String chatId,
    required AgentProviderKind provider,
    String? workspaceRoot,
  }) {
    if (rawJson.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    var toolName = '';
    final rawPaths = <String>[];

    // 1. Antigravity (agy) format: { "toolCall": { "name": "...", "args": { "Path": "..." } } }
    final toolCall = decoded['toolCall'];
    if (toolCall is Map) {
      toolName = toolCall['name']?.toString() ?? '';
      final args = toolCall['args'];
      if (args is Map) {
        _collectPathsFromMap(args, rawPaths);
      }
    }

    // 2. Claude Code format: { "tool_name": "...", "tool_input": { "file_path": "..." } }
    if (toolName.isEmpty && decoded['tool_name'] != null) {
      toolName = decoded['tool_name'].toString();
    }
    final toolInput = decoded['tool_input'];
    if (toolInput is Map) {
      _collectPathsFromMap(toolInput, rawPaths);
    }

    // Also allow direct top-level args in case of simplified/custom payloads
    _collectPathsFromMap(decoded, rawPaths);

    // Resolve and deduplicate paths
    final root = workspaceRoot ??
        _extractWorkspaceRoot(decoded) ??
        Directory.current.path;
    final resolved = <String>{};
    for (final raw in rawPaths) {
      final clean = raw.trim();
      if (clean.isEmpty) continue;
      resolved.add(AgentPathUtils.resolvePath(clean, root));
    }

    return ParsedAgentHookEvent(
      phase: phase == 'pre' ? 'pre' : 'post',
      chatId: chatId,
      provider: provider,
      toolName: toolName,
      filePaths: resolved.toList(),
    );
  }

  static String? _extractWorkspaceRoot(Map<Object?, Object?> decoded) {
    final cwd = decoded['cwd']?.toString();
    if (cwd != null && cwd.isNotEmpty) return cwd;
    final wsPaths = decoded['workspacePaths'];
    if (wsPaths is List && wsPaths.isNotEmpty) {
      final first = wsPaths.first?.toString();
      if (first != null && first.isNotEmpty) return first;
    }
    return null;
  }

  static void _collectPathsFromMap(
    Map<Object?, Object?> map,
    List<String> out,
  ) {
    const pathKeys = <String>[
      'Path',
      'path',
      'file_path',
      'filePath',
      'TargetFile',
      'target_file',
      'notebook_path',
    ];
    for (final key in pathKeys) {
      final val = map[key];
      if (val is String && val.trim().isNotEmpty) {
        out.add(val);
      }
    }
    final files = map['files'] ?? map['paths'];
    if (files is List) {
      for (final item in files) {
        if (item is String && item.trim().isNotEmpty) {
          out.add(item);
        } else if (item is Map) {
          _collectPathsFromMap(item, out);
        }
      }
    }
    final edits = map['edits'];
    if (edits is List) {
      for (final item in edits) {
        if (item is Map) {
          _collectPathsFromMap(item, out);
        }
      }
    }
  }

  /// Builds the shell command string that executes `vibrainium agent-hook`.
  static String buildHookShellCommand({
    required String phase,
    String? socketPath,
    String? chatId,
    required AgentProviderKind provider,
    String? devPackagePath,
  }) {
    final sockExpr = socketPath != null
        ? "'${_escapeSingleQuotes(socketPath)}'"
        : r'"$VIBRAINIUM_SOCKET"';
    final chatExpr = chatId != null
        ? "'${_escapeSingleQuotes(chatId)}'"
        : r'"$VIBRAINIUM_CHAT_ID"';
    final prov = provider == AgentProviderKind.claude ? 'claude' : 'agy';

    final String binCmd;
    if (devPackagePath != null && devPackagePath.isNotEmpty) {
      final escapedPkg = _escapeSingleQuotes(devPackagePath);
      binCmd =
          "dart run --verbosity=error '$escapedPkg/bin/vibrainium.dart'";
    } else {
      binCmd = 'vibrainium';
    }

    return '$binCmd agent-hook $phase --socket $sockExpr --chat $chatExpr --provider $prov';
  }

  /// Generates the inline JSON string for Claude Code's `--settings <json>` flag
  /// so `PreToolUse` and `PostToolUse` file-editing events are reported for [chatId].
  static String buildClaudeSettingsJson({
    required String socketPath,
    required String chatId,
    String? devPackagePath,
  }) {
    final preCmd = buildHookShellCommand(
      phase: 'pre',
      socketPath: socketPath,
      chatId: chatId,
      provider: AgentProviderKind.claude,
      devPackagePath: devPackagePath,
    );
    final postCmd = buildHookShellCommand(
      phase: 'post',
      socketPath: socketPath,
      chatId: chatId,
      provider: AgentProviderKind.claude,
      devPackagePath: devPackagePath,
    );

    final settings = <String, Object?>{
      'hooks': {
        'PreToolUse': [
          {
            'matcher': 'Edit|MultiEdit|Write|NotebookEdit',
            'hooks': [
              {
                'type': 'command',
                'command': preCmd,
              },
            ],
          },
        ],
        'PostToolUse': [
          {
            'matcher': 'Edit|MultiEdit|Write|NotebookEdit',
            'hooks': [
              {
                'type': 'command',
                'command': postCmd,
              },
            ],
          },
        ],
      },
    };
    return jsonEncode(settings);
  }

  /// Ensures `.agents/hooks.json` in [workspaceRoot] contains the
  /// `vibrainium-agent-tracker` hook entry for Antigravity (`agy`) when
  /// [socketPath] is active.
  ///
  /// The hook checks `VIBRAINIUM_CHAT_ID` and `VIBRAINIUM_SOCKET` env vars so
  /// any `agy` session launched outside `vibrainium` is a fast no-op.
  static Future<void> ensureAntigravityWorkspaceHooks({
    required String workspaceRoot,
    String? devPackagePath,
  }) async {
    if (workspaceRoot.trim().isEmpty) return;
    final dir = Directory('$workspaceRoot/.agents');
    final hooksFile = File('${dir.path}/hooks.json');

    Map<String, Object?> existing = {};
    if (await hooksFile.exists()) {
      try {
        final raw = await hooksFile.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          existing = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {}
    } else {
      await dir.create(recursive: true);
    }

    final preInner = buildHookShellCommand(
      phase: 'pre',
      provider: AgentProviderKind.antigravity,
      devPackagePath: devPackagePath,
    );
    final postInner = buildHookShellCommand(
      phase: 'post',
      provider: AgentProviderKind.antigravity,
      devPackagePath: devPackagePath,
    );

    final preCmd =
        'if [ -n "\$VIBRAINIUM_CHAT_ID" ] && [ -n "\$VIBRAINIUM_SOCKET" ]; then $preInner; else echo \'{"decision":"allow"}\'; fi';
    final postCmd =
        'if [ -n "\$VIBRAINIUM_CHAT_ID" ] && [ -n "\$VIBRAINIUM_SOCKET" ]; then $postInner; else echo \'{}\'; fi';

    existing['vibrainium-agent-tracker'] = {
      'enabled': true,
      'PreToolUse': [
        {
          'matcher': 'write_file|edit_file|replace_file_content|multi_replace_file_content',
          'hooks': [
            {
              'type': 'command',
              'command': preCmd,
              'timeout': 5,
            },
          ],
        },
      ],
      'PostToolUse': [
        {
          'matcher': 'write_file|edit_file|replace_file_content|multi_replace_file_content',
          'hooks': [
            {
              'type': 'command',
              'command': postCmd,
              'timeout': 5,
            },
          ],
        },
      ],
    };

    const encoder = JsonEncoder.withIndent('  ');
    await hooksFile.writeAsString('${encoder.convert(existing)}\n');
  }

  /// Builds the command argv list and environment map to spawn [session] in
  /// a Neovim terminal buffer.
  static ({List<String> command, Map<String, String> env}) buildSpawnSpec({
    required AgentChatSession session,
    String? socketPath,
    String? devPackagePath,
  }) {
    final env = <String, String>{
      'VIBRAINIUM_CHAT_ID': session.id,
      if (socketPath != null && socketPath.isNotEmpty)
        'VIBRAINIUM_SOCKET': socketPath,
    };

    switch (session.provider) {
      case AgentProviderKind.antigravity:
        return (
          command: <String>[session.provider.executable],
          env: env,
        );
      case AgentProviderKind.claude:
        final cmd = <String>[
          session.provider.executable,
          if (socketPath != null && socketPath.isNotEmpty) ...[
            '--settings',
            buildClaudeSettingsJson(
              socketPath: socketPath,
              chatId: session.id,
              devPackagePath: devPackagePath,
            ),
          ],
        ];
        return (
          command: cmd,
          env: env,
        );
    }
  }

  /// Standard stdout response required by the calling agent's hook runner.
  static String formatHookStdout({
    required String phase,
    required AgentProviderKind provider,
  }) {
    if (provider == AgentProviderKind.antigravity && phase == 'pre') {
      return '{"decision":"allow"}';
    }
    return '{}';
  }

  static String _escapeSingleQuotes(String input) =>
      input.replaceAll("'", r"'\''");
}
