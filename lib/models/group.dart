/// A server group as announced by `servergrouplist` (requested on connect).
class TsServerGroup {
  final int id;
  final String name;
  final bool isPermanent;
  final int neededMemberAddPower;
  final int? neededMemberRemovePower;

  /// Group sort priority (server-defined; higher = more privileged).
  final int sortId;

  const TsServerGroup({
    required this.id,
    required this.name,
    this.isPermanent = false,
    this.neededMemberAddPower = 0,
    this.neededMemberRemovePower,
    this.sortId = 0,
  });

  factory TsServerGroup.fromJson(Map<String, dynamic> json) => TsServerGroup(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String? ?? '',
    isPermanent: json['is_permanent'] as bool? ?? false,
    neededMemberAddPower: json['needed_member_add_power'] as int? ?? 0,
    neededMemberRemovePower: json['needed_member_remove_power'] as int?,
    sortId: json['sort_id'] as int? ?? 0,
  );
}

/// A channel group as announced by `channelgrouplist` (requested on connect).
class TsChannelGroup {
  final int id;
  final String name;
  final bool isPermanent;
  final int neededMemberAddPower;
  final int? neededMemberRemovePower;

  /// Group sort priority (server-defined; higher = more privileged).
  final int sortId;

  const TsChannelGroup({
    required this.id,
    required this.name,
    this.isPermanent = false,
    this.neededMemberAddPower = 0,
    this.neededMemberRemovePower,
    this.sortId = 0,
  });

  factory TsChannelGroup.fromJson(Map<String, dynamic> json) => TsChannelGroup(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String? ?? '',
    isPermanent: json['is_permanent'] as bool? ?? false,
    neededMemberAddPower: json['needed_member_add_power'] as int? ?? 0,
    neededMemberRemovePower: json['needed_member_remove_power'] as int?,
    sortId: json['sort_id'] as int? ?? 0,
  );
}
