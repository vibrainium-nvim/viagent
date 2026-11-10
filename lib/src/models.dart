import 'dart:io';

import 'package:viff/viff.dart';

/// Supported AI coding agent providers in `viagent`.
enum AgentProviderKind {
  antigravity(
    label: 'Antigravity',
    executable: 'agy',
    icon: '󰚩',
  ),
  claude(
    label: 'Claude Code',
    executable: 'claude',
    icon: '󰜡',
  );

  final String label;
  final String executable;
  final String icon;

  const AgentProviderKind({
    required this.label,
    required this.executable,
    required this.icon,
  });

  static AgentProviderKind fromString(String raw) {
    final lower = raw.trim().toLowerCase();
    if (lower == 'claude' || lower == 'claude-code' || lower == 'claudecode') {
      return AgentProviderKind.claude;
    }
    return AgentProviderKind.antigravity;
  }
}

/// Modification status of a file tracked under an [AgentChatSession].
enum AgentFileStatus {
  added('A'),
  modified('M'),
  deleted('D');

  final String code;
  const AgentFileStatus(this.code);
}

/// Baseline snapshot of a file's contents captured before an [AgentChatSession]
/// first modifies it.
class FileBaselineSnapshot {
  final String filePath;
  final bool existedBefore;
  final List<String> lines;
  final DateTime capturedAt;

  const FileBaselineSnapshot({
    required this.filePath,
    required this.existedBefore,
    required this.lines,
    required this.capturedAt,
  });

  static Future<FileBaselineSnapshot> captureFromDisk(
    String filePath, {
    DateTime? now,
  }) async {
    final normalized = AgentPathUtils.normalizePath(filePath);
    final file = File(normalized);
    final exists = await file.exists();
    List<String> lines = const [];
    if (exists) {
      try {
        final raw = await file.readAsString();
        lines = DiffEngine.splitLines(raw);
      } catch (_) {
        lines = const [];
      }
    }
    return FileBaselineSnapshot(
      filePath: normalized,
      existedBefore: exists,
      lines: lines,
      capturedAt: now ?? DateTime.now(),
    );
  }
}

/// A file modified by a specific [AgentChatSession].
class AgentChangedFile {
  final String filePath;
  final String relativePath;
  final AgentFileStatus status;
  final DateTime updatedAt;

  const AgentChangedFile({
    required this.filePath,
    required this.relativePath,
    required this.status,
    required this.updatedAt,
  });
}

/// Represents a single interactive AI agent chat session (`Antigravity` or `Claude Code`)
/// and tracks its per-chat baseline snapshots and modified files.
class AgentChatSession {
  final String id;
  final AgentProviderKind provider;
  final DateTime createdAt;
  String title;
  int? terminalBufId;
  int? terminalJobId;
  bool expanded;

  /// Pre-modification baseline snapshots keyed by normalized absolute path.
  /// Recorded only on the *first* `PreToolUse` event for each file in this chat.
  final Map<String, FileBaselineSnapshot> baselines = {};

  /// Currently modified files in this chat keyed by normalized absolute path.
  final Map<String, AgentChangedFile> changedFiles = {};

  AgentChatSession({
    required this.id,
    required this.provider,
    required this.title,
    DateTime? createdAt,
    this.terminalBufId,
    this.terminalJobId,
    this.expanded = true,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Records the baseline snapshot for [filePath] if this chat has not yet
  /// captured a baseline for it.
  Future<FileBaselineSnapshot> ensureBaseline(
    String filePath, {
    DateTime? now,
  }) async {
    final norm = AgentPathUtils.normalizePath(filePath);
    final existing = baselines[norm];
    if (existing != null) {
      return existing;
    }
    final captured = await FileBaselineSnapshot.captureFromDisk(
      norm,
      now: now,
    );
    baselines[norm] = captured;
    return captured;
  }

  /// Evaluates the current disk state of [filePath] against its recorded
  /// [FileBaselineSnapshot] and updates [changedFiles].
  ///
  /// If the file on disk has been reverted to match the baseline identically,
  /// it is removed from [changedFiles].
  Future<AgentChangedFile?> syncFileAfterEdit(
    String filePath, {
    required String workspaceRoot,
    DateTime? now,
  }) async {
    final norm = AgentPathUtils.normalizePath(filePath);
    final baseline = baselines[norm] ??
        FileBaselineSnapshot(
          filePath: norm,
          existedBefore: false,
          lines: const [],
          capturedAt: now ?? DateTime.now(),
        );
    baselines.putIfAbsent(norm, () => baseline);

    final file = File(norm);
    final existsNow = await file.exists();
    List<String> currentLines = const [];
    if (existsNow) {
      try {
        currentLines = DiffEngine.splitLines(await file.readAsString());
      } catch (_) {
        currentLines = const [];
      }
    }

    if (!baseline.existedBefore && !existsNow) {
      changedFiles.remove(norm);
      return null;
    }

    if (baseline.existedBefore &&
        existsNow &&
        _linesEqual(baseline.lines, currentLines)) {
      changedFiles.remove(norm);
      return null;
    }

    final AgentFileStatus status;
    if (!baseline.existedBefore && existsNow) {
      status = AgentFileStatus.added;
    } else if (baseline.existedBefore && !existsNow) {
      status = AgentFileStatus.deleted;
    } else {
      status = AgentFileStatus.modified;
    }

    final entry = AgentChangedFile(
      filePath: norm,
      relativePath: AgentPathUtils.relativize(norm, workspaceRoot),
      status: status,
      updatedAt: now ?? DateTime.now(),
    );
    changedFiles[norm] = entry;
    return entry;
  }

  /// Re-evaluates all tracked files in [changedFiles] against their baselines.
  Future<void> refreshTrackedFiles({required String workspaceRoot}) async {
    for (final path in changedFiles.keys.toList()) {
      await syncFileAfterEdit(path, workspaceRoot: workspaceRoot);
    }
  }

  static bool _linesEqual(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Path normalization and `@file#Lstart-Lend` formatting helpers for `viagent`.
class AgentPathUtils {
  static String normalizePath(String rawPath) {
    var p = rawPath.replaceAll(r'\', '/').trim();
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String basename(String path) {
    final norm = normalizePath(path);
    final idx = norm.lastIndexOf('/');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }

  static String relativize(String filePath, String workspaceRoot) {
    final normFile = normalizePath(filePath);
    final normRoot = normalizePath(workspaceRoot);
    if (normRoot.isNotEmpty && normFile.startsWith('$normRoot/')) {
      return normFile.substring(normRoot.length + 1);
    }
    return normFile;
  }

  static String resolvePath(String rawPath, String workspaceRoot) {
    final norm = normalizePath(rawPath);
    if (norm.isEmpty) return norm;
    if (norm.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(norm)) {
      return norm;
    }
    final normRoot = normalizePath(workspaceRoot);
    if (normRoot.isEmpty) return norm;
    return '$normRoot/$norm';
  }

  /// Formats a compact `@relative/path#Lstart-Lend ` token (with trailing space,
  /// no newline) suitable for safe insertion into an agent prompt.
  static String formatSelectionReference({
    required String filePath,
    required String workspaceRoot,
    int? startLine,
    int? endLine,
  }) {
    final rel = relativize(filePath, workspaceRoot);
    if (startLine == null || startLine <= 0) {
      return '@$rel ';
    }
    final s = startLine;
    final e = (endLine != null && endLine > 0) ? endLine : s;
    final low = s <= e ? s : e;
    final high = s <= e ? e : s;
    if (low == high) {
      return '@$rel#L$low ';
    }
    return '@$rel#L$low-L$high ';
  }

  /// Wraps [text] in ANSI Bracketed Paste escape sequences (`\x1b[200~...\x1b[201~`)
  /// and strips any trailing CR/LF so interactive TUIs (`agy` and `claude`) insert
  /// the text into the input line without submitting.
  static String wrapBracketedPaste(String text) {
    final safe = text.replaceAll(RegExp(r'[\r\n]+$'), '');
    return '\x1b[200~$safe\x1b[201~';
  }
}
