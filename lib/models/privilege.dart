/// Privilege tier inferred from server-group NAMES (heuristic — TeamSpeak
/// has no standard admin flag and the default sort_id of 0 on real servers
/// makes it an unreliable identity source, so the group name is used).
enum PrivilegeTier {
  /// No privileged server group (e.g. Guest).
  none,

  /// operator / moderator / supervisor / staff / controller / guard.
  moderator,

  /// admin / root / owner / administrator.
  admin,
}

const List<String> _adminKeywords = ['admin', 'root', 'owner', 'administrator'];
const List<String> _modKeywords = [
  'operator',
  'moderator',
  'supervisor',
  'staff',
  'controller',
  'guard',
];

/// Highest privilege tier matched by any of [groupNames], by keyword.
/// Always returns at least [PrivilegeTier.none] for an empty input.
PrivilegeTier privilegeTierOf(Iterable<String> groupNames) {
  var tier = PrivilegeTier.none;
  for (final name in groupNames) {
    final lower = name.toLowerCase();
    if (_adminKeywords.any(lower.contains)) {
      return PrivilegeTier.admin;
    }
    if (_modKeywords.any(lower.contains) &&
        tier.index < PrivilegeTier.moderator.index) {
      tier = PrivilegeTier.moderator;
    }
  }
  return tier;
}
