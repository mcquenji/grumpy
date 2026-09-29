import 'package:grumpy/grumpy.dart';

class LifecycleTarget with Disposable, LifecycleMixin {
  LifecycleTarget() {
    initialize();
  }
  int initializeCalls = 0;
  int activateCalls = 0;
  int deactivateCalls = 0;
  int dependenciesChangedCalls = 0;
  bool disposed = false;

  @override
  Future<void> activate() async {
    activateCalls++;
  }

  @override
  Future<void> deactivate() async {
    deactivateCalls++;
  }

  @override
  Future<void> dependenciesChanged() async {
    dependenciesChangedCalls++;
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<void> destroy() async {
    await super.destroy();
    disposed = true;
  }
}

class HookedLifecycle
    with Disposable, LogMixin, LifecycleMixin, LifecycleHooksMixin {
  HookedLifecycle() {
    initialize();
  }
  bool disposed = false;

  @override
  void log(Object message, [Object? error, StackTrace? stackTrace]) {
    // No-op logger for tests.
  }

  @override
  Future<void> destroy() async {
    await super.destroy();
    disposed = true;
  }

  @override
  String get logTag => 'HookedLifecycle';
}

class HookedRepo extends Repo<int>
    with RepoLifecycleMixin<int>, RepoLifecycleHooksMixin<int> {
  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> dependenciesChanged() async {}

  @override
  Future<void> destroy() async {
    await super.destroy();
  }

  @override
  Future<void> initialize() async {
    await super.initialize();
  }

  @override
  String get logTag => 'HookedRepo';
}
