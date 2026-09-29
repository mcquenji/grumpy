import 'dart:async';
import 'package:grumpy/grumpy.dart';

class ControlledDependencyReadiness implements DependencyReadiness {
  final Completer<void> _ready = Completer<void>();

  int waitCalls = 0;

  void complete() {
    if (!_ready.isCompleted) _ready.complete();
  }

  @override
  Future<void> waitForPendingDependencies() {
    waitCalls++;
    return _ready.future;
  }
}

class UseRepoConsumer
    with
        Disposable,
        LogMixin,
        LifecycleMixin,
        LifecycleHooksMixin,
        UseRepoMixin<String, String, String> {
  UseRepoConsumer() {
    installUseRepoHooks();
    onDependenciesChanged(() => dependenciesChangedCalls++);
    initialize();
  }

  int dependenciesChangedCalls = 0;
  int errorCalls = 0;
  Object? lastError;

  /// Exposes the metadata-only dependency snapshot for diagnostics tests.
  UseRepoDebugSnapshot? get debugSnapshot => useRepoDebugSnapshot;

  /// Forces the consumer to recompute its derived dependency state.
  Future<void> refresh() => refreshDependencies();

  @override
  FutureOr<String> onDependenciesReady(UseHooks use) async {
    final (count, _) = await use.repo<int, IntRepo>();
    final (label, _) = await use.repo<String, StringRepo>();
    return '$count-$label';
  }

  @override
  FutureOr<String> onDependencyError(Object error, StackTrace? _) {
    errorCalls++;
    lastError = error;
    return 'error:${error.toString()}';
  }

  @override
  String onDependenciesLoading() {
    return 'loading';
  }

  @override
  String get logTag => 'UseRepoConsumer';
}

class SlowSnapshotUseRepoConsumer
    with
        Disposable,
        LogMixin,
        LifecycleMixin,
        LifecycleHooksMixin,
        UseRepoMixin<String, String, String> {
  SlowSnapshotUseRepoConsumer({this.delay = const Duration(milliseconds: 30)}) {
    installUseRepoHooks();
    initialize();
  }

  final Duration delay;
  int readyCalls = 0;
  String? lastSnapshot;
  final Completer<void> firstSnapshotCaptured = Completer<void>();

  /// Exposes the metadata-only dependency snapshot for diagnostics tests.
  UseRepoDebugSnapshot? get debugSnapshot => useRepoDebugSnapshot;

  @override
  FutureOr<String> onDependenciesReady(UseHooks use) async {
    readyCalls++;
    final (count, _) = await use.repo<int, IntRepo>();
    final (label, _) = await use.repo<String, StringRepo>();
    final snapshot = '$count-$label';
    lastSnapshot = snapshot;
    if (!firstSnapshotCaptured.isCompleted) {
      firstSnapshotCaptured.complete();
    }
    await Future<void>.delayed(delay);
    return snapshot;
  }

  @override
  FutureOr<String> onDependencyError(Object error, StackTrace? _) =>
      'error:${error.toString()}';

  @override
  String onDependenciesLoading() => 'loading';

  @override
  String get logTag => 'SlowSnapshotUseRepoConsumer';
}

class ControlledInitialBuildConsumer
    with
        Disposable,
        LogMixin,
        LifecycleMixin,
        LifecycleHooksMixin,
        UseRepoMixin<int, Object, void> {
  ControlledInitialBuildConsumer() {
    installUseRepoHooks();
    initialize();
  }

  final firstSnapshotCaptured = Completer<void>();
  final releaseFirstBuild = Completer<void>();
  int readyCalls = 0;

  /// Exposes the metadata-only dependency snapshot for diagnostics tests.
  UseRepoDebugSnapshot? get debugSnapshot => useRepoDebugSnapshot;

  @override
  Future<int> onDependenciesReady(UseHooks use) async {
    final (value, _) = await use.repo<int, IntRepo>();
    readyCalls++;
    if (readyCalls == 1) {
      firstSnapshotCaptured.complete();
      await releaseFirstBuild.future;
    }
    return value;
  }

  @override
  Object onDependencyError(Object error, StackTrace? _) => error;

  @override
  void onDependenciesLoading() {}

  @override
  String get logTag => 'ControlledInitialBuildConsumer';
}

class ExternalSignalConsumer
    with
        Disposable,
        LogMixin,
        LifecycleMixin,
        LifecycleHooksMixin,
        UseRepoMixin<String, String, String> {
  ExternalSignalConsumer({
    required this.key,
    required this.changeSignal,
    required this.syncSnapshot,
  }) {
    installUseRepoHooks();
    onDependenciesChanged(() => dependenciesChangedCalls++);
    initialize();
  }

  final Object key;
  Stream changeSignal;
  String Function() syncSnapshot;

  int dependenciesChangedCalls = 0;
  int readyCalls = 0;
  int errorCalls = 0;
  Object? lastError;

  /// Exposes the metadata-only dependency snapshot for diagnostics tests.
  UseRepoDebugSnapshot? get debugSnapshot => useRepoDebugSnapshot;

  @override
  FutureOr<String> onDependenciesReady(UseHooks use) {
    readyCalls++;
    return use.externalStream<String>(
      key,
      changeSignal: changeSignal,
      syncSnapshot: syncSnapshot,
    );
  }

  @override
  FutureOr<String> onDependencyError(Object error, StackTrace? _) {
    errorCalls++;
    lastError = error;
    return 'error:${error.toString()}';
  }

  @override
  String onDependenciesLoading() => 'loading';

  @override
  String get logTag => 'ExternalSignalConsumer';
}

class PayloadStreamConsumer
    with
        Disposable,
        LogMixin,
        LifecycleMixin,
        LifecycleHooksMixin,
        UseRepoMixin<String, String, String> {
  PayloadStreamConsumer({
    required this.key,
    required this.sourceKey,
    required this.stream,
  }) {
    installUseRepoHooks();
    onDependenciesChanged(() => dependenciesChangedCalls++);
    initialize();
  }

  final Object key;
  Object sourceKey;
  Stream<String> stream;

  int dependenciesChangedCalls = 0;
  int streamFactoryCalls = 0;
  int readyCalls = 0;
  int errorCalls = 0;
  Object? lastError;

  /// Exposes the metadata-only dependency snapshot for diagnostics tests.
  UseRepoDebugSnapshot? get debugSnapshot => useRepoDebugSnapshot;

  @override
  FutureOr<String> onDependenciesReady(UseHooks use) {
    readyCalls++;
    return use.payloadStream<String>(
      key,
      sourceKey: sourceKey,
      createStream: () {
        streamFactoryCalls++;
        return stream;
      },
    );
  }

  @override
  FutureOr<String> onDependencyError(Object error, StackTrace? _) {
    errorCalls++;
    lastError = error;
    return 'error:${error.toString()}';
  }

  @override
  String onDependenciesLoading() => 'loading';

  @override
  String get logTag => 'PayloadStreamConsumer';
}

// for testing uninitialized usage
// ignore: missing_required_constructor_call
class UninitializedConsumer
    with
        Disposable,
        LogMixin,
        LifecycleMixin,
        LifecycleHooksMixin,
        UseRepoMixin<void, void, void> {
  @override
  FutureOr<void> onDependenciesReady(UseHooks use) {
    use.repo<int, IntRepo>();
    use.externalStream<void>(
      Object(),
      changeSignal: const Stream<void>.empty(),
      syncSnapshot: () {},
    );
  }

  @override
  FutureOr<void> onDependencyError(Object _, StackTrace? _) {}

  @override
  void onDependenciesLoading() {}
  @override
  String get logTag => 'UninitializedConsumer';
}

class IntRepo extends Repo<int> {
  void setData(int value) => data(value);
  @override
  String get logTag => 'IntRepo';
}

class DeferredCombinedRepo extends Repo<String>
    with UseRepoStateMixin<String>, DeferredRepoMixin<String> {
  DeferredCombinedRepo() {
    installUseRepoHooks();
    installDeferredRepoHooks();
  }

  @override
  FutureOr<String> build(UseHooks use) async {
    final (count, _) = await use.repo<int, IntRepo>();
    final (label, _) = await use.repo<String, StringRepo>();
    return '$count-$label';
  }

  @override
  String get logTag => 'DeferredCombinedRepo';
}

class ExternalSignalDeferredRepo extends Repo<String>
    with UseRepoStateMixin<String>, DeferredRepoMixin<String> {
  ExternalSignalDeferredRepo({
    required this.key,
    required this.changeSignal,
    required this.syncSnapshot,
  }) {
    installUseRepoHooks();
    installDeferredRepoHooks();
  }

  final Object key;
  Stream changeSignal;
  String Function() syncSnapshot;

  @override
  FutureOr<String> build(UseHooks use) {
    return use.externalStream<String>(
      key,
      changeSignal: changeSignal,
      syncSnapshot: syncSnapshot,
    );
  }

  @override
  String get logTag => 'ExternalSignalDeferredRepo';
}

class PayloadStreamDeferredRepo extends Repo<String>
    with UseRepoStateMixin<String>, DeferredRepoMixin<String> {
  PayloadStreamDeferredRepo({required this.key, required this.payloads}) {
    installUseRepoHooks();
    installDeferredRepoHooks();
  }

  final Object key;
  Stream<String> payloads;

  @override
  FutureOr<String> build(UseHooks use) {
    return use.payloadStream<String>(
      key,
      sourceKey: key,
      createStream: () => payloads,
    );
  }

  @override
  String get logTag => 'PayloadStreamDeferredRepo';
}

class StringRepo extends Repo<String> {
  void setData(String value) => data(value);
  void setError(Object error, [StackTrace? stackTrace]) =>
      super.error(error, stackTrace);
  @override
  String get logTag => 'StringRepo';
}
