import 'dart:convert';

import '../organization/organization.dart';
import '../library/favorites.dart';

/// Exact local recovery data, deliberately independent of public backup matching.
class PrivateSnapshot {
  PrivateSnapshot(this.organization, this.favorites) {
    for (final key in {
      ...organization.placements.keys,
      ...organization.albumOrders.values.expand((v) => v),
    }) {
      if (key.startsWith(pendingAlbumPrefix) &&
          organization.descriptors[key]?.pending != true) {
        throw StateError('Pending album description is missing');
      }
    }
    for (final p in favorites.pending) {
      if (p.albumKey != null &&
          !organization.descriptors.containsKey(p.albumKey)) {
        throw StateError('Pending favorite album description is missing');
      }
    }
  }
  final OrganizationSnapshot organization;
  final FavoriteSnapshot favorites;
  String encode() => jsonEncode({
    'folders': [
      for (final f in organization.folders.values) [f.id, f.parent, f.name],
    ],
    'placements': organization.placements,
    'folderOrders': organization.folderOrders,
    'albumOrders': organization.albumOrders,
    'descriptors': {
      for (final e in organization.descriptors.entries)
        e.key: descriptorData(e.value),
    },
    'confirmed': favorites.confirmed.toList()..sort(),
    'pending': favorites.pending.map(pendingData).toList(),
    if (favorites.migrationOutcomes.isNotEmpty)
      'migrationOutcomes': favorites.migrationOutcomes,
    if (favorites.sources.isNotEmpty) 'sources': favorites.sources,
  });
  static PrivateSnapshot decode(String value) {
    final m = jsonDecode(value) as Map<String, dynamic>;
    if (m.length < 7 || m.length > 9) {
      throw const FormatException('Invalid recovery snapshot');
    }
    Map<String, List<String>> orders(String key) =>
        (m[key] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as List).cast<String>()),
        );
    final decoded = PrivateSnapshot(
      OrganizationSnapshot(
        (m['folders'] as List).map(
          (f) => AlbumFolder(f[0] as String, f[1] as String, f[2] as String),
        ),
        (m['placements'] as Map).cast<String, String>(),
        folderOrders: orders('folderOrders'),
        albumOrders: orders('albumOrders'),
        descriptors: (m['descriptors'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, descriptorFrom(v)),
        ),
      ),
      FavoriteSnapshot(
        (m['confirmed'] as List).cast<String>(),
        (m['pending'] as List).map(pendingFrom),
        m['migrationOutcomes'] == null
            ? const {}
            : (m['migrationOutcomes'] as Map).cast<String, String>(),
        m['sources'] == null
            ? const {}
            : (m['sources'] as Map).cast<String, String>(),
      ),
    );
    // Journal values are written only by encode(). Reject ambiguous JSON,
    // extra tuple fields, duplicate keys/identities and lossy conversions.
    if (decoded.encode() != value) {
      throw const FormatException('Non-canonical recovery snapshot');
    }
    return decoded;
  }

  bool same(PrivateSnapshot other) {
    // Map order is irrelevant; list order (including optional empty orders) is not.
    Object? canonical(Object? o) {
      if (o is Map) {
        final keys = o.keys.cast<String>().toList()..sort();
        return {for (final k in keys) k: canonical(o[k])};
      }
      if (o is List) return o.map(canonical).toList();
      return o;
    }

    Map<String, dynamic> data(PrivateSnapshot s) {
      final d = jsonDecode(s.encode()) as Map<String, dynamic>;
      (d['folders'] as List).sort(
        (a, b) => (a[0] as String).compareTo(b[0] as String),
      );
      (d['pending'] as List).sort(
        (a, b) => (a['identity'] as String).compareTo(b['identity'] as String),
      );
      return d;
    }

    return jsonEncode(canonical(data(this))) ==
        jsonEncode(canonical(data(other)));
  }
}
