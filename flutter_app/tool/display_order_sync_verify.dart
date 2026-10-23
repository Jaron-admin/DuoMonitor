// Verification for the extracted display-order reconciliation.
// Run with: dart run tool/display_order_sync_verify.dart
//
// flutter_test cannot start in this environment (flutter_tester refuses the
// websocket), but display_order_sync.dart has no Flutter dependency, so the
// same assertions run straight from the Dart VM.
import 'dart:io';

import 'package:cryptofloat/domain/display_order_sync.dart';
import 'package:cryptofloat/domain/models.dart';

int failures = 0;

void check(String name, Object? actual, Object? expected) {
  final a = '$actual';
  final e = '$expected';
  if (a == e) {
    stdout.writeln('  ok    $name');
  } else {
    failures++;
    stdout.writeln('  FAIL  $name');
    stdout.writeln('        expected $e');
    stdout.writeln('        actual   $a');
  }
}

AppConfig config({
  List<String> assets = const ['A', 'B'],
  List<String> metrics = const ['cpu'],
  List<DisplayRow> rows = const [],
  List<String> order = const ['asset:A', 'asset:B', 'metric:cpu'],
}) => AppConfig.defaults.copyWith(
  selectedAssetIds: assets,
  selectedMetricIds: metrics,
  displayRows: rows,
  displayOrder: order,
);

DisplayRow row(String id) => DisplayRow(id: id, segments: const []);

void main() {
  stdout.writeln('display order sync');

  final before = config();

  check(
    'unchanged selection leaves the order alone',
    syncDisplayOrder(before, config()).displayOrder,
    ['asset:A', 'asset:B', 'metric:cpu'],
  );

  check(
    'adding an asset appends it to the group',
    syncDisplayOrder(
      before,
      config(assets: ['A', 'B', 'C']),
    ).displayOrder,
    ['asset:A', 'asset:B', 'metric:cpu', 'asset:C'],
  );

  check(
    'removing an asset drops its slot',
    syncDisplayOrder(before, config(assets: ['A'])).displayOrder,
    ['asset:A', 'metric:cpu'],
  );

  check(
    'reordering assets follows the new selection order',
    syncDisplayOrder(before, config(assets: ['B', 'A'])).displayOrder,
    ['asset:B', 'asset:A', 'metric:cpu'],
  );

  check(
    'an explicit order edit wins over reconciliation',
    syncDisplayOrder(
      before,
      config(
        assets: ['B', 'A'],
        order: ['metric:cpu', 'asset:A', 'asset:B'],
      ),
    ).displayOrder,
    ['metric:cpu', 'asset:A', 'asset:B'],
  );

  check(
    'an empty order has nothing to reconcile',
    syncDisplayOrder(
      AppConfig.defaults,
      AppConfig.defaults.copyWith(selectedAssetIds: ['A', 'B', 'C']),
    ).displayOrder,
    <String>[],
  );

  check(
    'adding a row appends it to the row group',
    syncDisplayOrder(
      config(rows: [row('r1')], order: ['row:r1', 'asset:A']),
      config(rows: [row('r1'), row('r2')], order: ['row:r1', 'asset:A']),
    ).displayOrder,
    ['row:r1', 'asset:A', 'row:r2'],
  );

  check(
    'two groups can change in one edit',
    syncDisplayOrder(
      before,
      config(assets: ['B', 'A'], metrics: ['cpu', 'gpu']),
    ).displayOrder,
    ['asset:B', 'asset:A', 'metric:cpu', 'metric:gpu'],
  );

  check(
    'ids from other groups are untouched',
    syncDisplayOrder(
      config(order: ['asset:A', 'metric:cpu', 'asset:B', 'metric:mem']),
      config(
        assets: ['A', 'B', 'C'],
        metrics: ['cpu', 'mem'],
        order: ['asset:A', 'metric:cpu', 'asset:B', 'metric:mem'],
      ),
    ).displayOrder,
    ['asset:A', 'metric:cpu', 'asset:B', 'metric:mem', 'asset:C'],
  );

  if (failures == 0) {
    stdout.writeln('all checks passed');
  } else {
    stdout.writeln('$failures check(s) failed');
    exitCode = 1;
  }
}
