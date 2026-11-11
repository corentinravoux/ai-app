import 'dart:io';

import 'package:ai_app/core/agents.dart';
import 'package:ai_app/core/sandbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String realHome;
  late Sandbox sb;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aiapp_sb_');
    realHome = '${tmp.path}/home';
    Directory('$realHome/.globus').createSync(recursive: true);
    Directory('$realHome/.claude/plugins').createSync(recursive: true);
    sb = Sandbox(
      root: '$realHome/.local/share/alcfai/home',
      realHome: realHome,
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('ensure creates home and globus symlink', () async {
    await sb.ensure();
    expect(Directory(sb.home).existsSync(), isTrue);
    expect(Link('${sb.home}/.globus').targetSync(), '$realHome/.globus');
    await sb.ensure();
  });

  test('overrideValue per agent', () {
    final h = sb.home;
    expect(sb.claudeDir, '$h/.claude');
    expect(sb.overrideValue(AgentKind.claude), '$h/.claude');
    expect(sb.overrideValue(AgentKind.codex), '$h/.codex');
    expect(sb.overrideValue(AgentKind.pi), '$h/.pi/agent');
    expect(
      sb.overrideValue(AgentKind.opencode),
      '$h/.config/opencode/opencode.jsonc',
    );
  });

  test('isConfigured', () async {
    await sb.ensure();
    for (final k in AgentKind.values) {
      expect(sb.isConfigured(k), isFalse, reason: k.name);
    }
    final h = sb.home;
    File('$h/.claude/settings.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"theme": "dark"}');
    expect(sb.isConfigured(AgentKind.claude), isFalse);
    File('$h/.claude/settings.json')
        .writeAsStringSync('{"env": {"ANTHROPIC_BASE_URL": "x"}}');
    expect(sb.isConfigured(AgentKind.claude), isTrue);
    File('$h/.pi/agent/models.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"providers": {"alcf-inference-service-x": {}}}');
    expect(sb.isConfigured(AgentKind.pi), isTrue);
    File('$h/.codex/config.toml')
      ..createSync(recursive: true)
      ..writeAsStringSync('model = "x"');
    expect(sb.isConfigured(AgentKind.codex), isFalse);
    File('$h/.codex/config.toml')
        .writeAsStringSync('[model_providers.alcf-inference-service-x]');
    expect(sb.isConfigured(AgentKind.codex), isTrue);
    File('$h/.config/opencode/opencode.jsonc')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    expect(sb.isConfigured(AgentKind.opencode), isFalse);
    File('$h/.config/opencode/opencode.jsonc')
        .writeAsStringSync('{"provider": {"alcf-inference-service-x": {}}}');
    expect(sb.isConfigured(AgentKind.opencode), isTrue);
  });

  test('sharedConfigLinked true only when CLAUDE.md is a symlink', () async {
    await sb.ensure();
    expect(sb.sharedConfigLinked, isFalse);
    File('${tmp.path}/CLAUDE.md').writeAsStringSync('x');
    Directory(sb.claudeDir).createSync(recursive: true);
    File('${sb.claudeDir}/CLAUDE.md').writeAsStringSync('copy');
    expect(sb.sharedConfigLinked, isFalse);
    File('${sb.claudeDir}/CLAUDE.md').deleteSync();
    Link('${sb.claudeDir}/CLAUDE.md').createSync('${tmp.path}/CLAUDE.md');
    expect(sb.sharedConfigLinked, isTrue);
  });

  test('setPluginsLink toggles the plugins link only', () async {
    await sb.ensure();
    File('$realHome/.claude/plugins/keep').writeAsStringSync('k');
    await sb.setPluginsLink(true);
    final link = Link('${sb.claudeDir}/plugins');
    expect(link.targetSync(), '$realHome/.claude/plugins');
    await sb.setPluginsLink(true);
    await sb.setPluginsLink(false);
    expect(link.existsSync(), isFalse);
    expect(File('$realHome/.claude/plugins/keep').existsSync(), isTrue);
  });

  test('ensure refuses a root inside realHome/.claude*', () async {
    for (final bad in ['.claude/x', '.claude-alt/x', '.claude']) {
      final s = Sandbox(root: '$realHome/$bad', realHome: realHome);
      await expectLater(s.ensure(), throwsStateError, reason: bad);
    }
  });
}
