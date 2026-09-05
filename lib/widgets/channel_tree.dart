import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/channel.dart';
import '../models/client.dart';
import '../models/group.dart';
import 'client_row.dart';

class ChannelTree extends StatefulWidget {
  final List<TsChannel> channels;

  /// Every client on the server; those whose [TsClient.channelId] matches a
  /// channel are rendered nested under that channel's row (TS3 style).
  final List<TsClient> clients;
  final int? selectedChannelId;
  // Receives the whole channel (not just the id) so the caller can decide
  // e.g. to prompt for a password before joining.
  final ValueChanged<TsChannel> onChannelTap;

  /// Invoked on a long press — the caller decides what that means (usually:
  /// open the per-channel menu). Swap semantics with [onChannelTap] come
  /// from the settings' gesture option, not from this widget.
  final ValueChanged<TsChannel>? onChannelMenu;

  /// Whether a password was already entered for this channel during the
  /// session (rendered as an open lock). Null = never ask/known state,
  /// e.g. while disconnected.
  final bool Function(int channelId)? sessionPasswordKnown;

  /// Our own talk power, used to decide whether a channel's
  /// needed-talk-power bars us from speaking there.
  final int ownTalkPower;

  /// Invoked when a client row is tapped — the caller dispatches self
  /// (voice settings) vs. others (per-client action sheet).
  final ValueChanged<int>? onClientTap;

  /// Server groups for the privileged-identity badges on client rows.
  final List<TsServerGroup> serverGroups;

  const ChannelTree({
    super.key,
    required this.channels,
    this.clients = const [],
    this.selectedChannelId,
    required this.onChannelTap,
    this.onChannelMenu,
    this.sessionPasswordKnown,
    this.ownTalkPower = 0,
    this.onClientTap,
    this.serverGroups = const [],
  });

  @override
  State<ChannelTree> createState() => _ChannelTreeState();
}

class _ChannelTreeState extends State<ChannelTree> {
  /// Manual expansion of channels WITHOUT clients (they default to
  /// collapsed).
  final Set<int> _expanded = {};

  /// Manual collapse of channels WITH clients (they default to expanded, so
  /// members of other channels are reachable without extra taps).
  final Set<int> _collapsed = {};

  List<TsChannel> get _roots =>
      widget.channels.where((c) => c.parentId == 0).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

  /// Clients grouped by their channel id, in roster order.
  Map<int, List<TsClient>> get _clientsByChannel {
    final map = <int, List<TsClient>>{};
    for (final c in widget.clients) {
      map.putIfAbsent(c.channelId, () => []).add(c);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.channels.isEmpty) {
      return Center(
        child: Text(
          AppLocalizations.of(context).noChannels,
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _roots.length,
      itemBuilder: (context, index) => _buildTile(_roots[index], 0),
    );
  }

  Widget _buildTile(TsChannel channel, int depth) {
    final al = AppLocalizations.of(context);
    final children = channel.children(widget.channels);
    final clientsInChannel = _clientsByChannel[channel.id] ?? const [];
    final isSelected = channel.id == widget.selectedChannelId;
    final hasChildren = children.isNotEmpty;
    final hasClients = clientsInChannel.isNotEmpty;
    // A channel can be folded when it has sub-channels or members.
    final canCollapse = hasChildren || hasClients;
    final isExpanded = hasClients
        ? !_collapsed.contains(channel.id)
        : _expanded.contains(channel.id);
    // Permission hints arrive shortly after connect (the server pushes them
    // on subscribe). Until then `permissionHints == 0` means "unknown", not
    // "denied" — only gate once the server explicitly denies joining.
    final hintsKnown = channel.permissionHints != 0;
    final mayJoin = !hintsKnown || channel.canJoin || isSelected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Channel row
        Material(
          color: isSelected
              ? Colors.blue.withValues(alpha: 0.15)
              : Colors.transparent,
          child: InkWell(
            onTap: () {
              // Permission gate: a channel we cannot join shows a hint
              // instead of attempting the move (skip when we are already in
              // it — the hints may lag behind the optimistic selection).
              if (!mayJoin) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(al.channelsNoJoinPermission),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                return;
              }
              widget.onChannelTap(channel);
              // Auto-expand the channel when joining it (also clears a
              // manual collapse so the member we "joined to meet" shows).
              if (canCollapse && !isExpanded) {
                setState(() {
                  _expanded.add(channel.id);
                  _collapsed.remove(channel.id);
                });
              }
            },
            onLongPress: widget.onChannelMenu == null
                ? null
                : () => widget.onChannelMenu!(channel),
            child: Padding(
              padding: EdgeInsets.only(
                left: 8.0 + depth * 20.0,
                top: 10,
                bottom: 10,
                right: 8,
              ),
              child: Row(
                children: [
                  // Expand/collapse arrow for foldable channels
                  if (canCollapse)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          if (isExpanded) {
                            // Remember the collapse against whichever
                            // default currently applies to the channel.
                            if (hasClients) {
                              _collapsed.add(channel.id);
                            } else {
                              _expanded.remove(channel.id);
                            }
                          } else {
                            if (hasClients) {
                              _collapsed.remove(channel.id);
                            } else {
                              _expanded.add(channel.id);
                            }
                          }
                        });
                      },
                      child: Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 18,
                        color: Colors.grey,
                      ),
                    )
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 4),
                  // Channel icon
                  Icon(
                    hasChildren ? Icons.folder : Icons.tag,
                    size: 16,
                    color: isSelected ? Colors.blue : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  // Channel name with a trailing lock badge: closed = needs
                  // a password, open = already entered in this session.
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            channel.name,
                            style: TextStyle(
                              color: isSelected ? Colors.blue : Colors.white,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (channel.hasPassword) ...[
                          const SizedBox(width: 4),
                          Icon(
                            (widget.sessionPasswordKnown?.call(channel.id) ??
                                    false)
                                ? Icons.lock_open
                                : Icons.lock,
                            size: 12,
                            color: Colors.grey.withValues(alpha: 0.8),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Permission indicators: cannot join at all (only shown once the
                  // server has actually denied it), or our talk power is too
                  // low to speak in the channel.
                  if (hintsKnown && !channel.canJoin && !isSelected) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: al.channelsNoJoinPermission,
                      child: Icon(
                        Icons.block,
                        size: 13,
                        color: Colors.redAccent,
                      ),
                    ),
                  ],
                  if (channel.neededTalkPower > widget.ownTalkPower &&
                      !isSelected) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: al.channelTalkPowerNeeded(
                        channel.neededTalkPower,
                      ),
                      child: Icon(Icons.mic_off, size: 12, color: Colors.amber),
                    ),
                  ],
                  // Client count badge — redundant while the members are
                  // visible, so only shown on a folded channel.
                  if (channel.clientCount > 0 &&
                      !(isExpanded && hasClients)) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${channel.clientCount}',
                        style: TextStyle(
                          color: isSelected ? Colors.blue : Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        // Members nested under their channel (TS3 order: clients above
        // sub-channels), then the sub-channels — only while expanded.
        if (isExpanded) ...[
          for (final client in clientsInChannel)
            ClientRow(
              client: client,
              // Talk power is per channel: use THIS channel's restriction.
              channelNeededTalkPower: channel.neededTalkPower,
              serverGroups: widget.serverGroups,
              // Align roughly with the channel icon of this depth.
              indent: 30.0 + depth * 20.0,
              onTap: widget.onClientTap == null
                  ? null
                  : () => widget.onClientTap!(client.id),
            ),
          ...children.map((ch) => _buildTile(ch, depth + 1)),
        ],
      ],
    );
  }
}
