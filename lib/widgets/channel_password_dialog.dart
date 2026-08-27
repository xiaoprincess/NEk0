import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

/// Password prompt shown before joining a locked channel. Dark-themed to
/// match the other dialogs (e.g. the poke prompt). Returns the entered
/// password, or null when the user cancelled.
Future<String?> showChannelPasswordDialog(
  BuildContext context, {
  required String channelName,
  String? errorMessage,
}) async {
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (ctx) {
        final al = AppLocalizations.of(ctx);
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: Text(
            al.channelPasswordTitle,
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                channelName,
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: al.channelPasswordHint,
                  hintStyle: const TextStyle(color: Colors.grey),
                ),
                onSubmitted: (text) => Navigator.of(ctx).pop(text),
              ),
              if (errorMessage != null && errorMessage.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  errorMessage,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                al.cancel,
                style: const TextStyle(color: Colors.grey),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: Text(
                al.ok,
                style: const TextStyle(color: Colors.blueAccent),
              ),
            ),
          ],
        );
      },
    );
  } finally {
    controller.dispose();
  }
}
