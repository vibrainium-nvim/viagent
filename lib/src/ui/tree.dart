import 'dart:convert';

import '../models.dart';

/// Sealed node hierarchy for rows in the rendered `viagent` tree buffer.
sealed class AgentTreeNode {
  const AgentTreeNode();
}

/// Top interactive toolbar row with `[+ Antigravity (a)]` and `[+ Claude (c)]` buttons.
class AgentToolbarNode extends AgentTreeNode {
  final int agyColStart;
  final int agyColEnd;
  final int claudeColStart;
  final int claudeColEnd;

  const AgentToolbarNode({
    required this.agyColStart,
    required this.agyColEnd,
    required this.claudeColStart,
    required this.claudeColEnd,
  });
}

/// Horizontal divider row separating the toolbar from the chat list.
class AgentDividerNode extends AgentTreeNode {
  const AgentDividerNode();
}

/// Header row for an [AgentChatSession].
class AgentChatHeaderNode extends AgentTreeNode {
  final AgentChatSession session;
  final bool isActive;
  final bool expanded;
  final int changedFileCount;

  const AgentChatHeaderNode({
    required this.session,
    required this.isActive,
    required this.expanded,
    required this.changedFileCount,
  });
}

/// Row representing a single modified file under an expanded [AgentChatSession].
class AgentChangedFileNode extends AgentTreeNode {
  final AgentChatSession session;
  final AgentChangedFile file;

  const AgentChangedFileNode({
    required this.session,
    required this.file,
  });
}

/// Empty-state hint row (either when no chats exist or when an expanded chat has no modified files).
class AgentEmptyNode extends AgentTreeNode {
  final String text;
  final AgentChatSession? session;

  const AgentEmptyNode(this.text, {this.session});
}

/// Byte-indexed highlight span on a single buffer line.
class AgentHighlightSpan {
  final int line;
  final int colStart;
  final int colEnd;
  final String group;

  const AgentHighlightSpan({
    required this.line,
    required this.colStart,
    required this.colEnd,
    required this.group,
  });
}

/// Output of [AgentTreeState.build].
class RenderedAgentTree {
  final List<String> lines;
  final List<AgentTreeNode> nodes;
  final List<AgentHighlightSpan> highlights;

  const RenderedAgentTree({
    required this.lines,
    required this.nodes,
    required this.highlights,
  });
}

/// Stateful tree builder for the `viagent` left pane inside the `Agents [2]` bottom tab.
class AgentTreeState {
  static const Map<String, String> _fileIcons = {
    'dart': '',
    'lua': '',
    'md': '',
    'json': '',
    'yaml': '',
    'yml': '',
    'toml': '',
    'sh': '',
    'zsh': '',
    'bash': '',
    'py': '',
    'rs': '',
    'go': '',
    'js': '',
    'ts': '',
    'html': '',
    'css': '',
    'c': '',
    'cpp': '',
    'h': '',
  };

  static String iconForFile(String path) {
    final name = AgentPathUtils.basename(path);
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx > 0 && dotIdx < name.length - 1) {
      final ext = name.substring(dotIdx + 1).toLowerCase();
      final match = _fileIcons[ext];
      if (match != null) return match;
    }
    return '󰈙';
  }

  static String highlightForStatus(AgentFileStatus status) {
    switch (status) {
      case AgentFileStatus.added:
        return 'ViagentStatusAdded';
      case AgentFileStatus.modified:
        return 'ViagentStatusModified';
      case AgentFileStatus.deleted:
        return 'ViagentStatusDeleted';
    }
  }

  static int _byteLen(String s) => utf8.encode(s).length;

  RenderedAgentTree build({
    required List<AgentChatSession> sessions,
    required String? activeChatId,
    int width = 38,
  }) {
    final lines = <String>[];
    final nodes = <AgentTreeNode>[];
    final highlights = <AgentHighlightSpan>[];

    // 1. Top Toolbar Row
    const agyBtn = ' + 󰚩 Antigravity [a] ';
    const sep = '│';
    const claudeBtn = ' + 󰜡 Claude [c] ';
    final toolbarLine = '$agyBtn$sep$claudeBtn';
    final agyEnd = _byteLen(agyBtn);
    final sepEnd = agyEnd + _byteLen(sep);
    final claudeEnd = sepEnd + _byteLen(claudeBtn);

    lines.add(toolbarLine);
    nodes.add(
      AgentToolbarNode(
        agyColStart: 0,
        agyColEnd: agyEnd,
        claudeColStart: sepEnd,
        claudeColEnd: claudeEnd,
      ),
    );
    highlights.add(
      AgentHighlightSpan(
        line: 0,
        colStart: 0,
        colEnd: agyEnd,
        group: 'ViagentToolbarButton',
      ),
    );
    highlights.add(
      AgentHighlightSpan(
        line: 0,
        colStart: agyEnd,
        colEnd: sepEnd,
        group: 'ViagentDivider',
      ),
    );
    highlights.add(
      AgentHighlightSpan(
        line: 0,
        colStart: sepEnd,
        colEnd: claudeEnd,
        group: 'ViagentToolbarButton',
      ),
    );

    // 2. Divider Row
    final divWidth = width.clamp(20, 120);
    final divLine = '─' * divWidth;
    lines.add(divLine);
    nodes.add(const AgentDividerNode());
    highlights.add(
      AgentHighlightSpan(
        line: 1,
        colStart: 0,
        colEnd: _byteLen(divLine),
        group: 'ViagentDivider',
      ),
    );

    if (sessions.isEmpty) {
      const hint = '  No chats — press [a] Antigravity or [c] Claude';
      final lineIdx = lines.length;
      lines.add(hint);
      nodes.add(const AgentEmptyNode(hint));
      highlights.add(
        AgentHighlightSpan(
          line: lineIdx,
          colStart: 0,
          colEnd: _byteLen(hint),
          group: 'ViagentEmptyHint',
        ),
      );
      return RenderedAgentTree(
        lines: lines,
        nodes: nodes,
        highlights: highlights,
      );
    }

    for (final session in sessions) {
      final isActive = session.id == activeChatId;
      final chevron = session.expanded ? '▾' : '▸';
      final activeDot = isActive ? '●' : ' ';
      final icon = session.provider.icon;
      final fileCount = session.changedFiles.length;
      final prefix = ' $chevron $activeDot $icon ';
      final titlePart = session.title;
      final countPart = ' ($fileCount)';
      final headerLine = '$prefix$titlePart$countPart';
      final headerIdx = lines.length;

      lines.add(headerLine);
      nodes.add(
        AgentChatHeaderNode(
          session: session,
          isActive: isActive,
          expanded: session.expanded,
          changedFileCount: fileCount,
        ),
      );

      final prefixBytes = _byteLen(prefix);
      final titleBytes = _byteLen(titlePart);
      final countBytes = _byteLen(countPart);

      highlights.add(
        AgentHighlightSpan(
          line: headerIdx,
          colStart: 0,
          colEnd: prefixBytes,
          group: isActive ? 'ViagentChatActiveIndicator' : 'ViagentChatInactive',
        ),
      );
      highlights.add(
        AgentHighlightSpan(
          line: headerIdx,
          colStart: prefixBytes,
          colEnd: prefixBytes + titleBytes,
          group: isActive ? 'ViagentChatTitleActive' : 'ViagentChatTitle',
        ),
      );
      highlights.add(
        AgentHighlightSpan(
          line: headerIdx,
          colStart: prefixBytes + titleBytes,
          colEnd: prefixBytes + titleBytes + countBytes,
          group: 'ViagentCountBadge',
        ),
      );

      if (session.expanded) {
        final sortedFiles = session.changedFiles.values.toList()
          ..sort((a, b) => a.relativePath.compareTo(b.relativePath));

        if (sortedFiles.isEmpty) {
          const emptyFilesText = '     (no modified files)';
          final emptyIdx = lines.length;
          lines.add(emptyFilesText);
          nodes.add(AgentEmptyNode(emptyFilesText, session: session));
          highlights.add(
            AgentHighlightSpan(
              line: emptyIdx,
              colStart: 0,
              colEnd: _byteLen(emptyFilesText),
              group: 'ViagentEmptyHint',
            ),
          );
        } else {
          for (final changed in sortedFiles) {
            final fIcon = iconForFile(changed.filePath);
            final indent = '     $fIcon ';
            final pathStr = changed.relativePath;
            final badge = ' ${changed.status.code}';
            final fileLine = '$indent$pathStr$badge';
            final fileLineIdx = lines.length;

            lines.add(fileLine);
            nodes.add(
              AgentChangedFileNode(
                session: session,
                file: changed,
              ),
            );

            final indentBytes = _byteLen(indent);
            final pathBytes = _byteLen(pathStr);
            final badgeBytes = _byteLen(badge);

            highlights.add(
              AgentHighlightSpan(
                line: fileLineIdx,
                colStart: 0,
                colEnd: indentBytes,
                group: 'ViagentFileIcon',
              ),
            );
            highlights.add(
              AgentHighlightSpan(
                line: fileLineIdx,
                colStart: indentBytes,
                colEnd: indentBytes + pathBytes,
                group: 'ViagentFilePath',
              ),
            );
            highlights.add(
              AgentHighlightSpan(
                line: fileLineIdx,
                colStart: indentBytes + pathBytes,
                colEnd: indentBytes + pathBytes + badgeBytes,
                group: highlightForStatus(changed.status),
              ),
            );
          }
        }
      }
    }

    return RenderedAgentTree(
      lines: lines,
      nodes: nodes,
      highlights: highlights,
    );
  }
}
