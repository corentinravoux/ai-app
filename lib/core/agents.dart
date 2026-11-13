/// The coding agents the app knows how to launch and configure.
enum AgentKind {
  claude('claude'),
  codex('codex'),
  opencode('opencode'),
  pi('pi'),
  qwen('qwen');

  const AgentKind(this.exe);

  /// Executable name looked up on PATH; also the `alcf-ai agent configure` name.
  final String exe;
}

/// The agents offered against a model host, in sidebar order. Two of them
/// run the same program (Claude Code, minimal or full), hence a kind of
/// their own rather than [AgentKind].
enum LocalAgent {
  pi(AgentKind.pi, 'Pi', 'pi', 16384),
  opencode(AgentKind.opencode, 'OpenCode', 'opencode', 24576),
  qwen(AgentKind.qwen, 'Qwen Code', 'qwen', 24576),
  claude(AgentKind.claude, 'Claude', 'claude', 32768),
  claudeFull(AgentKind.claude, 'Claude (full)', 'claude-full', 65536);

  const LocalAgent(this.kind, this.label, this.dirName, this.minCtx);

  /// The program it runs.
  final AgentKind kind;
  final String label;

  /// Its config folder under `local/<host>/`, and the middle of its id.
  final String dirName;

  /// Smallest window it works in: its own prompt and tools take about
  /// 1.5K (Pi), 13K (OpenCode), 10K (Qwen Code), 1.2K (Claude, minimal)
  /// and 18.5K (Claude, full) tokens, and Claude Code cannot compact its
  /// history below a 100K window (docs/local-wire-notes.md).
  final int minCtx;

  /// The name used in sentences ("Claude Code needs…").
  String get longName => this == claude ? 'Claude Code' : label;
}
