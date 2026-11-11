import 'package:flutter/material.dart';

import 'theme.dart';

/// A selectable monospace text box in a dialog: the server log, or the log
/// tail of a failed start.
Future<void> showTextDialog(
  BuildContext context, {
  required String title,
  required Future<String> text,
}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title, style: Theme.of(context).textTheme.titleMedium),
    content: SizedBox(
      width: 720,
      height: 380,
      child: FutureBuilder<String>(
        future: text,
        builder: (context, snap) => snap.hasData
            ? Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Tok.bg,
                  border: Border.all(color: Tok.line),
                  borderRadius: BorderRadius.circular(Tok.radius),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    snap.data!,
                    style: const TextStyle(
                      fontFamily: Tok.mono,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              )
            : const Center(child: CircularProgressIndicator()),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  ),
);
