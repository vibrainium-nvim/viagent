import 'package:test/test.dart';
import 'package:viagent/viagent.dart';

void main() {
  group('AgentTreeState', () {
    test('renders toolbar, divider, and empty hint when no chats exist', () {
      final tree = AgentTreeState();
      final rendered = tree.build(sessions: const [], activeChatId: null);

      expect(rendered.lines, hasLength(3));
      expect(rendered.lines[0], contains('+ 󰚩 Antigravity [a]'));
      expect(rendered.lines[0], contains('+ 󰜡 Claude [c]'));
      expect(rendered.nodes[0], isA<AgentToolbarNode>());
      expect(rendered.nodes[1], isA<AgentDividerNode>());
      expect(rendered.nodes[2], isA<AgentEmptyNode>());
    });

    test('renders multiple chats with active indicator and changed files', () {
      final chat1 = AgentChatSession(
        id: 'chat-1',
        provider: AgentProviderKind.antigravity,
        title: 'Antigravity #1',
      );
      chat1.changedFiles['/ws/lib/a.dart'] = AgentChangedFile(
        filePath: '/ws/lib/a.dart',
        relativePath: 'lib/a.dart',
        status: AgentFileStatus.modified,
        updatedAt: DateTime.utc(2026),
      );

      final chat2 = AgentChatSession(
        id: 'chat-2',
        provider: AgentProviderKind.claude,
        title: 'Claude Code #1',
      );

      final tree = AgentTreeState();
      final rendered = tree.build(
        sessions: [chat1, chat2],
        activeChatId: 'chat-1',
      );

      expect(
        rendered.lines.any((l) => l.contains('● 󰚩 Antigravity #1 (1)')),
        isTrue,
      );
      expect(
        rendered.lines.any((l) => l.contains('lib/a.dart M')),
        isTrue,
      );
      expect(
        rendered.lines.any((l) => l.contains('Claude Code #1 (0)')),
        isTrue,
      );
    });
  });
}
