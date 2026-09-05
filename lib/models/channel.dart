import 'client.dart';

class TsChannel {
  final int id;
  final String name;
  final int parentId;
  final String topic;
  final bool hasPassword;
  final int clientCount;
  final int order;

  /// The server's default channel. A channel kick moves its target here, so
  /// a client in the default channel cannot be kicked from their channel.
  final bool isDefault;

  /// Raw `ChannelPermissionHint` bits. 0 until the server pushes hints.
  final int permissionHints;

  /// i_channel_needed_talk_power (0 = no talk restriction).
  final int neededTalkPower;

  const TsChannel({
    required this.id,
    required this.name,
    required this.parentId,
    this.topic = '',
    this.hasPassword = false,
    this.clientCount = 0,
    this.order = 0,
    this.isDefault = false,
    this.permissionHints = 0,
    this.neededTalkPower = 0,
  });

  factory TsChannel.fromJson(Map<String, dynamic> json) => TsChannel(
    id: json['id'] as int,
    name: json['name'] as String,
    parentId: json['parent_id'] as int,
    topic: json['topic'] as String? ?? '',
    hasPassword: json['has_password'] as bool? ?? false,
    clientCount: json['client_count'] as int? ?? 0,
    order: json['order'] as int? ?? 0,
    isDefault: json['is_default'] as bool? ?? false,
    permissionHints: json['permission_hints'] as int? ?? 0,
    neededTalkPower: json['needed_talk_power'] as int? ?? 0,
  );

  // ─── Permission getters (what WE may do in this channel) ───────────
  bool get canJoin =>
      ChannelPermission.has(permissionHints, ChannelPermission.join);
  bool get canModify =>
      ChannelPermission.has(permissionHints, ChannelPermission.modify);
  bool get canDelete =>
      ChannelPermission.has(permissionHints, ChannelPermission.delete);
  bool get canFileBrowse =>
      ChannelPermission.has(permissionHints, ChannelPermission.fileBrowse);
  bool get canFileUpload =>
      ChannelPermission.has(permissionHints, ChannelPermission.fileUpload);
  bool get canFileDownload =>
      ChannelPermission.has(permissionHints, ChannelPermission.fileDownload);
  bool get canModifyPermissions => ChannelPermission.has(
    permissionHints,
    ChannelPermission.modifyPermissions,
  );

  List<TsChannel> children(List<TsChannel> all) {
    return all.where((c) => c.parentId == id).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }
}
