import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/channel.dart';

/// Result values the sheet pops with so the caller can react after close.
const channelMenuJoin = 'join';
const channelMenuFileManager = 'file_manager';

/// Bottom sheet opened by a long press (or swapped short tap) on a channel
/// row. First entry joins the channel, second opens its file management —
/// keep this order when adding further entries later.
Future<String?> showChannelMenu(BuildContext context, TsChannel channel) async {
  final al = AppLocalizations.of(context);
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF12122A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (ctx) => SafeArea(
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Small drag handle like the other sheets in the app.
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.tag, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      channel.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A4A)),
            // Join channel — always the first entry.
            ListTile(
              leading: const Icon(
                Icons.login,
                size: 22,
                color: Colors.blueAccent,
              ),
              title: Text(
                al.menuEnterChannel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => Navigator.of(ctx).pop(channelMenuJoin),
            ),
            // File management — only when we may browse (or upload to) this
            // channel's file area. The hints arrive from the server shortly
            // after connect; `permissionHints == 0` means "not known yet"
            // and the entry stays visible (a denied request surfaces a
            // server error in the file manager anyway).
            if (channel.permissionHints == 0 ||
                channel.canFileBrowse ||
                channel.canFileUpload)
              ListTile(
                leading: const Icon(
                  Icons.folder_open,
                  size: 22,
                  color: Colors.blueAccent,
                ),
                title: Text(
                  al.menuFileManager,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                onTap: () => Navigator.of(ctx).pop(channelMenuFileManager),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}
