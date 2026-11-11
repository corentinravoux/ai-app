import 'dart:ui';

import 'package:ai_app/app/layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('measure splits areas and places dividers', () {
    // [ a | b / c ]
    final a = PaneNode(1), b = PaneNode(2), c = PaneNode(3);
    final root = SplitNode(
      sideBySide: true,
      first: a,
      second: SplitNode(sideBySide: false, first: b, second: c),
    );
    final g = measure(root, const Rect.fromLTWH(0, 0, 207, 107), divider: 7);
    expect(g.panes[1], const Rect.fromLTWH(0, 0, 100, 107));
    expect(g.panes[2], const Rect.fromLTWH(107, 0, 100, 50));
    expect(g.panes[3], const Rect.fromLTWH(107, 57, 100, 50));
    expect(g.dividers.map((d) => d.rect), [
      const Rect.fromLTWH(100, 0, 7, 107),
      const Rect.fromLTWH(107, 50, 100, 7),
    ]);
    expect(panesOf(root).map((p) => p.id), [1, 2, 3]);
  });

  test('replaceNode and parentOf', () {
    final a = PaneNode(1), b = PaneNode(2);
    final root = SplitNode(sideBySide: true, first: a, second: b);
    expect(parentOf(root, b), same(root));
    expect(parentOf(root, root), isNull);
    final c = PaneNode(3);
    expect(replaceNode(root, b, c), same(root));
    expect(root.second, same(c));
    expect(replaceNode(root, root, a), same(a));
  });

  test('zoneAt: quarter-wide edge bands, middle elsewhere', () {
    expect(zoneAt(0.5, 0.5), DropZone.center);
    expect(zoneAt(0.1, 0.5), DropZone.left);
    expect(zoneAt(0.9, 0.5), DropZone.right);
    expect(zoneAt(0.5, 0.05), DropZone.top);
    expect(zoneAt(0.5, 0.95), DropZone.bottom);
    expect(zoneAt(0.05, 0.2), DropZone.left);
  });

  test('previewRect covers the half a drop would fill', () {
    const r = Rect.fromLTWH(10, 10, 100, 60);
    expect(previewRect(r, DropZone.right), const Rect.fromLTWH(60, 10, 50, 60));
    expect(previewRect(r, DropZone.top), const Rect.fromLTWH(10, 10, 100, 30));
    expect(previewRect(r, DropZone.center), r);
  });
}
