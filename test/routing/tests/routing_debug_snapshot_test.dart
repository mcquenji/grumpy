import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:grumpy/grumpy.dart';
import 'package:test/test.dart';

import '../harness/routing_test_harness.dart';

void main() {
  late GetIt di;
  late RootTestModule root;
  late RoutingService<String, Cfg> routing;
  late RoutingDebugInfoProvider diagnostics;

  setUp(() async {
    di = GetIt.instance;
    await di.reset(dispose: false);
    root = RootTestModule(const Cfg('cfg'));
    await root.initialize();
    await root.activate();
    routing = di.get<RoutingService<String, Cfg>>();
    diagnostics = routing as RoutingDebugInfoProvider;
  });

  tearDown(() async {
    await di.reset(dispose: false);
  });

  test('reports route shape and parameter names without values', () async {
    final uri = Uri.parse('/courses/$_secret?id=$_secret#$_secret');

    await routing.navigate(uri.toString());

    final snapshot = diagnostics.debugSnapshotFor(uri)!;
    expect(snapshot.phase, RoutingDebugPhase.completed);
    expect(snapshot.routePattern, '/courses/:id');
    expect(snapshot.pathSegmentCount, 2);
    expect(snapshot.pathParameterNames, ['id']);
    expect(snapshot.queryParameterNames, ['id']);
    expect(snapshot.hasFragment, isTrue);
    expect(snapshot.lineage.last.leafType, ParamLeaf);
    expect(snapshot.elapsed, isNot(Duration.zero));
    expect(snapshot.failureType, isNull);
    expect(_describe(snapshot), isNot(contains(_secret)));
  });

  test('reports complete module and middleware lineage', () async {
    final uri = Uri.parse('/feature/child');

    await routing.navigate(uri.toString());

    final snapshot = diagnostics.debugSnapshotFor(uri)!;
    expect(snapshot.routePattern, '/feature/child');
    expect(snapshot.moduleTypes, contains(FeatureModule));
    expect(snapshot.lineage, hasLength(3));
    expect(
      snapshot.lineage
          .singleWhere((entry) => entry.moduleType != null)
          .moduleType,
      FeatureModule,
    );
    expect(snapshot.lineage.last.leafType, TestLeaf2);
    expect(snapshot.middleware, hasLength(2));
    expect(
      snapshot.middleware.map((entry) => entry.state),
      everyElement(RoutingDebugStepState.succeeded),
    );
  });

  test('reports middleware rejection and skipped descendants', () async {
    final uri = Uri.parse('/blocked-parent/child');

    await routing.navigate(uri.toString());

    final snapshot = diagnostics.debugSnapshotFor(uri)!;
    expect(snapshot.phase, RoutingDebugPhase.rejected);
    expect(snapshot.failureType, StateError);
    expect(snapshot.middleware, hasLength(2));
    expect(snapshot.middleware.first.state, RoutingDebugStepState.failed);
    expect(snapshot.middleware.last.state, RoutingDebugStepState.skipped);
    expect(routing.currentContext, isNull);
  });

  test('coalesces callers into the active request tracker', () async {
    final uri = Uri.parse('/slow-pending');
    final first = routing.navigate(uri.toString());
    await root.slowPendingMiddleware.started;

    var snapshot = diagnostics.debugSnapshotFor(uri)!;
    expect(snapshot.phase, RoutingDebugPhase.runningMiddleware);
    expect(snapshot.middleware.single.state, RoutingDebugStepState.running);

    final second = routing.navigate(uri.toString());
    await Future<void>.delayed(Duration.zero);
    snapshot = diagnostics.debugSnapshotFor(uri)!;
    expect(snapshot.coalescedNavigationCount, 1);

    root.slowPendingMiddleware.release();
    await Future.wait([first, second]);

    snapshot = diagnostics.debugSnapshotFor(uri)!;
    expect(snapshot.phase, RoutingDebugPhase.completed);
    expect(snapshot.coalescedNavigationCount, 1);
    expect(snapshot.middleware.single.state, RoutingDebugStepState.succeeded);
  });

  test('reports uncaught route-matching failures by type', () async {
    final uri = Uri.parse('/missing/$_secret');

    await expectLater(
      routing.navigate(uri.toString()),
      throwsA(isA<ArgumentError>()),
    );

    final snapshot = diagnostics.debugSnapshotFor(uri)!;
    expect(snapshot.phase, RoutingDebugPhase.failed);
    expect(snapshot.failureType, ArgumentError);
    expect(snapshot.routePattern, isNull);
    expect(_describe(snapshot), isNot(contains(_secret)));
  });
}

const _secret = 'GRUMPY_ROUTE_SENTINEL';

String _describe(RoutingDebugSnapshot snapshot) => <Object?>[
  snapshot.phase,
  snapshot.routePattern,
  snapshot.lineage.map(
    (entry) => <Object?>[
      entry.routeType,
      entry.declaredPath,
      entry.moduleType,
      entry.leafType,
      ...entry.middlewareTypes,
    ],
  ),
  snapshot.moduleTypes,
  snapshot.middleware.map(
    (entry) => <Object?>[entry.middlewareType, entry.state],
  ),
  snapshot.pathSegmentCount,
  snapshot.pathParameterNames,
  snapshot.queryParameterNames,
  snapshot.hasFragment,
  snapshot.failureType,
].toString();
