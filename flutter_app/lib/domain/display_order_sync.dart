import 'display_snapshot.dart';
import 'models.dart';

/// The three ordered groups that share one flat [AppConfig.displayOrder] list.
///
/// Adding a fourth kind of row means adding a case here and nothing else: the
/// sync below walks [values] and does not care how many groups there are.
enum DisplayOrderGroup {
  asset('asset:'),
  metric('metric:'),
  row('row:');

  const DisplayOrderGroup(this.prefix);

  /// Prefix used in [AppConfig.displayOrder] for this group's entries.
  final String prefix;

  List<String> idsOf(AppConfig config) => switch (this) {
    DisplayOrderGroup.asset => config.selectedAssetIds,
    DisplayOrderGroup.metric => config.selectedMetricIds,
    DisplayOrderGroup.row => [
      for (final row in config.displayRows) row.id,
    ],
  };
}

/// Keeps [AppConfig.displayOrder] in step with the selections it describes.
///
/// Adding, removing or reordering an item changes the id list but not the flat
/// order, so the order has to be reconciled here. Two cases are deliberately
/// left alone:
///
///  * an explicit change to `displayOrder` itself - that is the user dragging
///    rows on the panel, and rewriting it would undo their work;
///  * an empty `displayOrder` - a fresh config has nothing to reconcile yet.
///
/// This used to run inside the settings page's draft setter, which meant every
/// assignment anywhere in the page was a potential reorder. Pulling it out as a
/// pure function makes the trigger explicit and lets it be tested without a
/// widget tree.
AppConfig syncDisplayOrder(AppConfig before, AppConfig after) {
  if (after.displayOrder.isEmpty) return after;
  if (!_sameOrder(after.displayOrder, before.displayOrder)) return after;
  var updated = after;
  for (final group in DisplayOrderGroup.values) {
    final ids = group.idsOf(after);
    if (_sameOrder(ids, group.idsOf(before))) continue;
    updated = updated.copyWith(
      displayOrder: reorderDisplayGroup(updated.displayOrder, group.prefix, [
        for (final id in ids) '${group.prefix}$id',
      ]),
    );
  }
  return updated;
}

bool _sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
