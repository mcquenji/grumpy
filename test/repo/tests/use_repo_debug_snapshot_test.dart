import 'dart:async';

import 'package:get_it/get_it.dart' hide Disposable;
import 'package:grumpy/grumpy.dart';
import 'package:test/test.dart';

import '../harness/use_repo_mixin_test_harness.dart';

void main() {
  final di = GetIt.instance;

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(di.reset);
  tearDown(di.reset);

  test(
    'reports repository lifecycle, counters, refresh, and disposal',
    () async {
      final intRepo = IntRepo();
      final stringRepo = StringRepo();
      di
        ..registerSingletonAsync<IntRepo>(() async => intRepo)
        ..registerSingletonAsync<StringRepo>(() async => stringRepo);

      final consumer = UseRepoConsumer();
      await consumer.initialize();
      await settle();

      var snapshot = consumer.debugSnapshot!;
      expect(snapshot.state, UseRepoDebugState.loading);
      expect(snapshot.dependencies, hasLength(1));
      expect(snapshot.subscriptionCount, 1);

      intRepo.setData(1);
      await settle();
      snapshot = consumer.debugSnapshot!;
      expect(snapshot.dependencies, hasLength(2));
      expect(snapshot.subscriptionCount, 2);
      expect(
        snapshot.dependencies.whereType<UseRepoRepoDependencyDebugInfo>().map(
          (entry) => entry.repoType,
        ),
        unorderedEquals(<Type>[IntRepo, StringRepo]),
      );

      stringRepo.setData('safe');
      await settle();

      snapshot = consumer.debugSnapshot!;
      expect(snapshot.state, UseRepoDebugState.data);
      expect(snapshot.latestTrigger?.kind, UseRepoDebugTriggerKind.repoChange);
      expect(snapshot.totalRebuildCount, greaterThanOrEqualTo(3));
      expect(snapshot.activeRebuildCount, 0);

      final versionBeforeRefresh = snapshot.stateChangeVersion;
      await consumer.refresh();
      snapshot = consumer.debugSnapshot!;
      expect(
        snapshot.latestTrigger?.kind,
        UseRepoDebugTriggerKind.explicitRefresh,
      );
      expect(snapshot.stateChangeVersion, greaterThan(versionBeforeRefresh));

      final secretError = _SecretError();
      stringRepo.setError(secretError, StackTrace.current);
      await settle();
      snapshot = consumer.debugSnapshot!;
      expect(snapshot.state, UseRepoDebugState.error);
      expect(
        snapshot.dependencies
            .whereType<UseRepoRepoDependencyDebugInfo>()
            .singleWhere((entry) => entry.repoType == StringRepo)
            .errorType,
        _SecretError,
      );
      expect(snapshot.toString(), isNot(contains(_secret)));

      await consumer.destroy();
      snapshot = consumer.debugSnapshot!;
      expect(snapshot.state, UseRepoDebugState.disposed);
      expect(snapshot.subscriptionCount, 0);
    },
  );

  test(
    'reports pending repository resolution without retaining values',
    () async {
      final readiness = ControlledDependencyReadiness();
      di.registerSingleton<DependencyReadiness>(readiness);
      final consumer = UseRepoConsumer();
      await settle();

      expect(consumer.debugSnapshot!.pendingRepoTypes, contains(IntRepo));

      di
        ..registerSingletonAsync<IntRepo>(() async => IntRepo()..setData(4))
        ..registerSingletonAsync<StringRepo>(
          () async => StringRepo()..setData(_secret),
        );
      readiness.complete();
      await settle();

      final snapshot = consumer.debugSnapshot!;
      expect(snapshot.pendingRepoTypes, isEmpty);
      expect(snapshot.state, UseRepoDebugState.data);
      expect(snapshot.toString(), isNot(contains(_secret)));
      await consumer.destroy();
    },
  );

  test('reports external and payload stream metadata and triggers', () async {
    final externalController = StreamController<void>.broadcast();
    final external = ExternalSignalConsumer(
      key: _SecretValue(),
      changeSignal: externalController.stream,
      syncSnapshot: () => _secret,
    );
    await settle();

    var snapshot = external.debugSnapshot!;
    final externalEntry = snapshot.dependencies
        .whereType<UseRepoExternalDependencyDebugInfo>()
        .single;
    expect(externalEntry.keyType, _SecretValue);
    expect(externalEntry.valueType, String);
    expect(externalEntry.state, UseRepoDependencyDebugState.data);

    externalController.add(null);
    await settle();
    expect(
      external.debugSnapshot!.latestTrigger?.kind,
      UseRepoDebugTriggerKind.externalSignal,
    );

    externalController.addError(_SecretError(), StackTrace.current);
    await settle();
    snapshot = external.debugSnapshot!;
    expect(snapshot.state, UseRepoDebugState.error);
    expect(
      snapshot.dependencies
          .whereType<UseRepoExternalDependencyDebugInfo>()
          .single
          .errorType,
      _SecretError,
    );
    expect(snapshot.latestTrigger?.kind, UseRepoDebugTriggerKind.externalError);
    expect(snapshot.toString(), isNot(contains(_secret)));

    final payloadController = StreamController<String>.broadcast();
    final replacementPayloadController = StreamController<String>.broadcast();
    final payload = PayloadStreamConsumer(
      key: _SecretValue(),
      sourceKey: _SecretValue(),
      stream: payloadController.stream,
    );
    await settle();

    snapshot = payload.debugSnapshot!;
    var payloadEntry = snapshot.dependencies
        .whereType<UseRepoPayloadDependencyDebugInfo>()
        .single;
    expect(payloadEntry.state, UseRepoDependencyDebugState.pending);
    expect(payloadEntry.keyType, _SecretValue);
    expect(payloadEntry.payloadType, String);
    expect(payloadEntry.streamType, isNotNull);

    payloadController.add(_secret);
    await settle();
    snapshot = payload.debugSnapshot!;
    payloadEntry = snapshot.dependencies
        .whereType<UseRepoPayloadDependencyDebugInfo>()
        .single;
    expect(payloadEntry.state, UseRepoDependencyDebugState.data);
    expect(snapshot.latestTrigger?.kind, UseRepoDebugTriggerKind.payloadValue);
    expect(snapshot.toString(), isNot(contains(_secret)));

    payloadController.addError(_SecretError(), StackTrace.current);
    await settle();
    snapshot = payload.debugSnapshot!;
    payloadEntry = snapshot.dependencies
        .whereType<UseRepoPayloadDependencyDebugInfo>()
        .single;
    expect(payloadEntry.state, UseRepoDependencyDebugState.error);
    expect(payloadEntry.errorType, _SecretError);
    expect(snapshot.latestTrigger?.kind, UseRepoDebugTriggerKind.payloadError);

    payload.stream = replacementPayloadController.stream;
    await payloadController.close();
    await settle();
    expect(
      payload.debugSnapshot!.latestTrigger?.kind,
      UseRepoDebugTriggerKind.payloadClosed,
    );

    await external.destroy();
    await payload.destroy();
    await externalController.close();
    await replacementPayloadController.close();
  });

  test('counts evaluations superseded by newer dependency state', () async {
    final intRepo = IntRepo()..setData(1);
    di.registerSingletonAsync<IntRepo>(() async => intRepo);
    final consumer = ControlledInitialBuildConsumer();

    await consumer.firstSnapshotCaptured.future;
    intRepo.setData(2);
    await settle();
    consumer.releaseFirstBuild.complete();
    await settle();

    final snapshot = consumer.debugSnapshot!;
    expect(snapshot.state, UseRepoDebugState.data);
    expect(snapshot.totalRebuildCount, 2);
    expect(snapshot.supersededRebuildCount, 1);
    expect(snapshot.activeRebuildCount, 0);
    await consumer.destroy();
  });
}

const _secret = 'GRUMPY_DIAGNOSTIC_SENTINEL';

final class _SecretValue {
  @override
  String toString() => _secret;
}

final class _SecretError implements Exception {
  @override
  String toString() => _secret;
}
