import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/client.dart';

class ClientList extends StatelessWidget {
  final List<TsClient> clients;
  final int currentChannelId;
  final ValueChanged<int>? onClientTap;

  const ClientList({
    super.key,
    required this.clients,
    required this.currentChannelId,
    this.onClientTap,
  });

  @override
  Widget build(BuildContext context) {
    final channelClients = clients
        .where((c) => c.channelId == currentChannelId)
        .toList();

    if (channelClients.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          AppLocalizations.of(context).noUsersInChannel,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      itemCount: channelClients.length,
      itemBuilder: (context, index) {
        final client = channelClients[index];
        return ListTile(
          dense: true,
          leading: SizedBox(
            width: 22,
            height: 22,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  _clientIcon(client),
                  size: 18,
                  color: _clientColor(client),
                ),
                if (client.isTalking)
                  const Positioned(
                    right: 0,
                    bottom: 0,
                    child: Icon(Icons.circle, size: 8, color: Colors.blue),
                  ),
              ],
            ),
          ),
          title: Text(
            client.nickname,
            style: TextStyle(
              color: client.away ? Colors.grey : Colors.white,
              fontSize: 13,
            ),
          ),
          onTap: () => onClientTap?.call(client.id),
        );
      },
    );
  }

  IconData _clientIcon(TsClient client) {
    // Away wins over mute icons: an away client shows the clock, not a
    // muted-mic/headset icon (away implies the mic is off anyway).
    if (client.away) return Icons.access_time;
    if (client.outputMuted) return Icons.headset_off;
    if (client.inputMuted) return Icons.mic_off;
    return Icons.person;
  }

  Color _clientColor(TsClient client) {
    if (client.away) return Colors.grey;
    if (client.inputMuted || client.outputMuted) return Colors.orange;
    return Colors.green;
  }
}
