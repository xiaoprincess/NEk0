import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

/// Password prompt shown before joining a locked channel. Dark-themed to
/// match the other dialogs (e.g. the poke prompt). Returns the entered
/// password, or null when the user cancelled.
Future<String?> showChannelPasswordDialog(
  BuildContext context, {
  required String channelName,
  String? errorMessage,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _ChannelPasswordDialog(
      channelName: channelName,
      errorMessage: errorMessage,
    ),
  );
}

/// Owns its [TextEditingController] so the controller outlives the dialog's
/// exit transition: [State.dispose] runs only after the route's widget tree
/// has stopped rebuilding, so no "used after being disposed" crashes on
/// the animated close frames. (Disposing manually right after the route's
/// future resolves throws in exactly that window.)
class _ChannelPasswordDialog extends StatefulWidget {
  const _ChannelPasswordDialog({required this.channelName, this.errorMessage});

  final String channelName;
  final String? errorMessage;

  @override
  State<_ChannelPasswordDialog> createState() => _ChannelPasswordDialogState();
}

class _ChannelPasswordDialogState extends State<_ChannelPasswordDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
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
            widget.channelName,
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: al.channelPasswordHint,
              hintStyle: const TextStyle(color: Colors.grey),
            ),
            onSubmitted: (text) => Navigator.of(context).pop(text),
          ),
          if (widget.errorMessage != null &&
              widget.errorMessage!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              widget.errorMessage!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(al.cancel, style: const TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(al.ok, style: const TextStyle(color: Colors.blueAccent)),
        ),
      ],
    );
  }
}
