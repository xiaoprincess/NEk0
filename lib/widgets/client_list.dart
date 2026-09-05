import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/client.dart';
import '../models/group.dart';
import '../models/privilege.dart';

class ClientList extends StatelessWidget {
  final List<TsClient> clients;
  final int currentChannelId;
  final ValueChanged<int>? onClientTap;

  /// The currently selected channel's `needed_talk_power`. 0 (or null) =
  /// the channel does not restrict talking, so no talk-power icon is shown.
  final int channelNeededTalkPower;

  /// All server groups on this server (used to resolve a client's primary
  /// server-group identity by sort_id). Empty while the group list is
  /// unavailable — privileged badges then stay hidden.
  final List<TsServerGroup> serverGroups;

  const ClientList({
    super.key,
    required this.clients,
    required this.currentChannelId,
    this.onClientTap,
    this.channelNeededTalkPower = 0,
    this.serverGroups = const [],
  });

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    final channelClients = clients
        .where((c) => c.channelId == currentChannelId)
        .toList();

    if (channelClients.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          al.noUsersInChannel,
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
          trailing: _buildStatusIcons(context, client, al),
          onTap: () => onClientTap?.call(client.id),
        );
      },
    );
  }

  /// Right-side status badges. Identity-critical icons:
  /// - server query / server query admin (client_type based),
  /// - privileged server group (by name heuristic; the group's sort_id picks
  ///   the client's most privileged group),
  /// - channel commander / priority speaker / recording,
  /// - talk power: ONLY in channels that restrict talking (the server's
  ///   `client_is_talker` is meaningless in unrestricted channels).
  Widget _buildStatusIcons(
    BuildContext context,
    TsClient client,
    AppLocalizations al,
  ) {
    final icons = <Widget>[];
    void add(IconData icon, Color color, String tooltip) {
      icons.add(
        Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Icon(icon, size: 12, color: color),
          ),
        ),
      );
    }

    if (client.isQueryAdmin) {
      add(Icons.admin_panel_settings, Colors.redAccent, al.serverQueryAdmin);
    } else if (client.isQuery) {
      add(Icons.terminal, Colors.grey, al.serverQuery);
    }

    // Privileged server group → shield. Only shown when the group list is
    // known and the client is a member of a privileged group; the group's
    // name decides the tier (sort_id is usually 0 on real servers).
    final privilegedGroup = _primaryServerGroup(client);
    if (privilegedGroup != null) {
      final tier = privilegeTierOf([privilegedGroup.name]);
      if (tier != PrivilegeTier.none) {
        add(
          tier == PrivilegeTier.admin
              ? Icons.admin_panel_settings
              : Icons.security,
          Colors.redAccent,
          al.serverGroups(privilegedGroup.name),
        );
      }
    }

    if (client.isChannelCommander) {
      add(Icons.military_tech, Colors.green, al.channelCommander);
    }
    if (client.isPrioritySpeaker) {
      add(Icons.keyboard_voice, Colors.green, al.prioritySpeaker);
    }
    if (client.isRecording) {
      add(Icons.fiber_manual_record, Colors.redAccent, al.recording);
    }

    // Talk power only matters when the channel restricts talking, and only
    // the DENIED state is an exception worth showing (default: everyone has
    // talk power in an unrestricted channel → no icon).
    if (channelNeededTalkPower > 0 && !client.talkPowerGranted) {
      add(Icons.mic_off, Colors.amber, al.talkPowerDenied);
    }

    if (icons.isEmpty) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: icons);
  }

  /// The client's most privileged server group — by NAME TIER (sort_id is
  /// usually 0 on real servers, so it is intentionally not used as the
  /// identity source). Null when the group list is unknown or the client
  /// holds no privileged group.
  TsServerGroup? _primaryServerGroup(TsClient client) {
    if (serverGroups.isEmpty || client.serverGroupIds.isEmpty) return null;
    TsServerGroup? best;
    var bestTier = PrivilegeTier.none;
    for (final g in serverGroups) {
      if (!client.serverGroupIds.contains(g.id)) continue;
      final tier = privilegeTierOf([g.name]);
      if (tier.index > bestTier.index) {
        bestTier = tier;
        best = g;
      }
    }
    return best;
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
