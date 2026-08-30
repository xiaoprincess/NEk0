import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/channel.dart';

class ChannelTree extends StatefulWidget {
  final List<TsChannel> channels;
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

  const ChannelTree({
    super.key,
    required this.channels,
    this.selectedChannelId,
    required this.onChannelTap,
    this.onChannelMenu,
    this.sessionPasswordKnown,
  });

  @override
  State<ChannelTree> createState() => _ChannelTreeState();
}

class _ChannelTreeState extends State<ChannelTree> {
  final Set<int> _expanded = {};

  List<TsChannel> get _roots =>
      widget.channels.where((c) => c.parentId == 0).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

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
    final children = channel.children(widget.channels);
    final isSelected = channel.id == widget.selectedChannelId;
    final hasChildren = children.isNotEmpty;
    final isExpanded = _expanded.contains(channel.id);

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
              widget.onChannelTap(channel);
              // Auto-expand parent when selecting a channel
              if (hasChildren && !_expanded.contains(channel.id)) {
                setState(() => _expanded.add(channel.id));
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
                  // Expand/collapse arrow for channels with children
                  if (hasChildren)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          if (_expanded.contains(channel.id)) {
                            _expanded.remove(channel.id);
                          } else {
                            _expanded.add(channel.id);
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
                  // Client count badge
                  if (channel.clientCount > 0)
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
              ),
            ),
          ),
        ),
        // Children (only if expanded)
        if (hasChildren && isExpanded)
          ...children.map((ch) => _buildTile(ch, depth + 1)),
      ],
    );
  }
}
