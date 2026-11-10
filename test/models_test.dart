import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:viagent/viagent.dart';

void main() {
  group('AgentPathUtils', () {
    test('formatSelectionReference formats compact @file#Lstart-Lend with trailing space and no newline', () {
      expect(
        AgentPathUtils.formatSelectionReference(
          filePath: '/workspace/lib/src/app.dart',
          workspaceRoot: '/workspace',
          startLine: 10,
          endLine: 25,
        ),
        '@lib/src/app.dart#L10-L25 ',
      );

      // Reversed visual bounds are normalized to low-high
      expect(
        AgentPathUtils.formatSelectionReference(
          filePath: '/workspace/lib/src/app.dart',
          workspaceRoot: '/workspace',
          startLine: 40,
          endLine: 12,
        ),
        '@lib/src/app.dart#L12-L40 ',
      );

      // Single-line selection uses #L<line>
      expect(
        AgentPathUtils.formatSelectionReference(
          filePath: '/workspace/lib/src/app.dart',
          workspaceRoot: '/workspace',
          startLine: 15,
          endLine: 15,
        ),
        '@lib/src/app.dart#L15 ',
      );

      // Whole-file reference without line numbers
      expect(
        AgentPathUtils.formatSelectionReference(
          filePath: '/workspace/README.md',
          workspaceRoot: '/workspace',
        ),
        '@README.md ',
      );
    });

    test('wrapBracketedPaste wraps reference in ANSI bracketed paste without trailing newline', () {
      final wrapped = AgentPathUtils.wrapBracketedPaste('@lib/main.dart#L5-L9 \n');
      expect(wrapped, '\x1b[200~@lib/main.dart#L5-L9 \x1b[201~');
      expect(wrapped.contains('\n'), isFalse);
      expect(wrapped.contains('\r'), isFalse);
    });
  });

  group('AgentChatSession per-chat baseline & changed file tracking', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('viagent_models_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('captures baseline on first PreToolUse and preserves it across multiple edits in the same chat', () async {
      final file = File('${tempDir.path}/lib/service.dart');
      await file.parent.create(recursive: true);
      await file.writeAsString('line 1\nline 2\n');

      final chat = AgentChatSession(
        id: 'chat-1',
        provider: AgentProviderKind.antigravity,
        title: 'Antigravity #1',
      );

      // 1st PreToolUse captures original baseline
      final baseline1 = await chat.ensureBaseline(file.path);
      expect(baseline1.existedBefore, isTrue);
      expect(baseline1.lines, ['line 1', 'line 2']);

      // Agent performs 1st edit
      await file.writeAsString('line 1\nline 2 modified\n');
      final changed1 = await chat.syncFileAfterEdit(
        file.path,
        workspaceRoot: tempDir.path,
      );
      expect(changed1, isNotNull);
      expect(changed1!.relativePath, 'lib/service.dart');
      expect(changed1.status, AgentFileStatus.modified);

      // 2nd PreToolUse on the same file must NOT overwrite the original pre-chat baseline
      final baseline2 = await chat.ensureBaseline(file.path);
      expect(baseline2.lines, ['line 1', 'line 2']);

      // Agent performs 2nd edit
      await file.writeAsString('line 1\nline 2 modified again\nline 3\n');
      await chat.syncFileAfterEdit(file.path, workspaceRoot: tempDir.path);
      expect(chat.baselines[AgentPathUtils.normalizePath(file.path)]!.lines, [
        'line 1',
        'line 2',
      ]);

      // If reverted back to original baseline, file is removed from changedFiles
      await file.writeAsString('line 1\nline 2\n');
      final afterRevert = await chat.syncFileAfterEdit(
        file.path,
        workspaceRoot: tempDir.path,
      );
      expect(afterRevert, isNull);
      expect(chat.changedFiles, isEmpty);
    });

    test('tracks newly created files as Added and deleted files as Deleted per chat', () async {
      final newFile = File('${tempDir.path}/new_feature.dart');
      final existingFile = File('${tempDir.path}/old_feature.dart');
      await existingFile.writeAsString('old content\n');

      final chat = AgentChatSession(
        id: 'chat-claude',
        provider: AgentProviderKind.claude,
        title: 'Claude Code #1',
      );

      // PreToolUse before creating newFile
      await chat.ensureBaseline(newFile.path);
      await newFile.writeAsString('void main() {}\n');
      final added = await chat.syncFileAfterEdit(
        newFile.path,
        workspaceRoot: tempDir.path,
      );
      expect(added?.status, AgentFileStatus.added);

      // PreToolUse before deleting existingFile
      await chat.ensureBaseline(existingFile.path);
      await existingFile.delete();
      final deleted = await chat.syncFileAfterEdit(
        existingFile.path,
        workspaceRoot: tempDir.path,
      );
      expect(deleted?.status, AgentFileStatus.deleted);
    });
  });

  group('AgentHookConfig', () {
    test('parses Antigravity (agy) and Claude Code (claude) hook payloads', () {
      final agyPayload = jsonEncode({
        'conversationId': 'conv-1',
        'workspacePaths': ['/workspace'],
        'toolCall': {
          'name': 'edit_file',
          'args': {
            'Path': '/workspace/lib/main.dart',
          },
        },
      });
      final parsedAgy = AgentHookConfig.parseHookStdin(
        rawJson: agyPayload,
        phase: 'pre',
        chatId: 'chat-1',
        provider: AgentProviderKind.antigravity,
      );
      expect(parsedAgy, isNotNull);
      expect(parsedAgy!.phase, 'pre');
      expect(parsedAgy.toolName, 'edit_file');
      expect(parsedAgy.filePaths, ['/workspace/lib/main.dart']);

      final claudePayload = jsonEncode({
        'session_id': 'sess-2',
        'cwd': '/workspace',
        'tool_name': 'Edit',
        'tool_input': {
          'file_path': 'lib/claude_edited.dart',
        },
      });
      final parsedClaude = AgentHookConfig.parseHookStdin(
        rawJson: claudePayload,
        phase: 'post',
        chatId: 'chat-2',
        provider: AgentProviderKind.claude,
      );
      expect(parsedClaude, isNotNull);
      expect(parsedClaude!.phase, 'post');
      expect(parsedClaude.toolName, 'Edit');
      expect(parsedClaude.filePaths, ['/workspace/lib/claude_edited.dart']);
    });

    test('builds Claude settings JSON and Antigravity hooks.json', () async {
      final claudeJson = AgentHookConfig.buildClaudeSettingsJson(
        socketPath: '/tmp/vibrainium.sock',
        chatId: 'chat-42',
      );
      final decoded = jsonDecode(claudeJson) as Map<String, Object?>;
      expect(decoded['hooks'], isA<Map<String, Object?>>());

      final tempDir = await Directory.systemTemp.createTemp('viagent_hooks_');
      try {
        await AgentHookConfig.ensureAntigravityWorkspaceHooks(
          workspaceRoot: tempDir.path,
        );
        final hooksFile = File('${tempDir.path}/.agents/hooks.json');
        expect(await hooksFile.exists(), isTrue);
        final hooksContent =
            jsonDecode(await hooksFile.readAsString()) as Map<String, Object?>;
        expect(hooksContent.containsKey('vibrainium-agent-tracker'), isTrue);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
