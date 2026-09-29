import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:grumpy_annotations/grumpy_annotations.dart';
import 'package:meta/meta.dart';
import 'package:grumpy/grumpy.dart';

/// Access helpers passed into [UseRepoMixin.onDependenciesReady].
///
/// Exposes helper functions for reading dependent repos and external change
/// signals while building derived state.
///
/// Derived repos need one structured way to declare the dependencies they want
/// to watch.
///
/// [repo] resolves and subscribes to another repo, [externalStream] subscribes
/// to an invalidation stream and reads the current value from a synchronous
/// snapshot callback, and [payloadStream] subscribes to a stream whose emitted
/// payloads are the current value.
///
/// Calling [repo] may throw [NoRepoDataError] until the dependency has emitted
/// data.
///
/// - [repo]: watches another repo and returns its current data plus the repo.
/// - [externalStream]: watches a non-repo signal keyed by a stable identity.
/// - [payloadStream]: watches a non-repo payload stream keyed by a stable identity.
///
/// For example:
/// ```dart
/// final (user, repo) = await use.repo<User, UserRepo>();
/// ```
///
/// {@category repo}
class UseHooks {
  /// Provides use hooks for watching and accessing data within [UseRepoMixin.onDependenciesReady].
  const UseHooks({
    required this.repo,
    required this.externalStream,
    required this.payloadStream,
  });

  /// {@template UseHooks.repo}
  /// Watches a [Repo] of type `R` managing data of type `S` and
  /// returns a tuple containing the data from the repo and the repo itself.
  ///
  /// Example usage:
  /// ```dart
  /// final (counter, counterRepo) = use.repo<int, CounterRepo>();
  /// ```
  ///
  /// If the repo does not contain data yet, [UseRepoMixin.onDependenciesReady] is aborted and [UseRepoMixin.onDependenciesLoading] or [UseRepoMixin.onDependencyError] is called instead.
  ///
  /// {@endtemplate}
  final Future<(S, R)> Function<S, R extends Repo<S>>() repo;

  /// {@template UseHooks.externalStream}
  /// Watches an external change signal while reading the current
  /// value synchronously via a syncSnapshot callback.
  ///
  /// Example usage:
  /// ```dart
  /// final isOnline = use.externalStream<bool>(
  ///   'onlineStatus',
  ///   changeSignal: connectivityService.onConnectivityChanged,
  ///   syncSnapshot: () => connectivityService.isOnline,
  /// );
  /// ```
  ///
  /// The changeSignal is treated as invalidation-only. Emitted values are
  /// ignored and only used to trigger recomputation.
  ///
  /// If the changeSignal emits an error or syncSnapshot throws, the error will be handled by [UseRepoMixin.onDependencyError].
  /// {@endtemplate}
  final T Function<T>(
    Object key, {

    required Stream changeSignal,
    required T Function() syncSnapshot,
  })
  externalStream;

  /// Watches a payload-bearing stream and returns its latest emitted value.
  ///
  /// [key] identifies the dependency slot across rebuilds. [sourceKey]
  /// identifies the stream source within that slot. The [createStream] factory
  /// runs when the slot is first used, its source key changes, or the active
  /// stream closes, so callers do not need to cache stream instances
  /// themselves.
  ///
  /// ```dart
  /// final profile = use.payloadStream<UserProfile>(
  ///   'profile',
  ///   sourceKey: userId,
  ///   createStream: api.watchProfile,
  /// );
  /// ```
  ///
  /// The hook reports loading until the active stream emits its first payload.
  /// Later payloads trigger recomputation and are returned synchronously. When
  /// [sourceKey] changes, the previous subscription and payload are discarded.
  /// If the active stream closes, the subscription is recreated and the hook
  /// reports loading until the replacement stream emits.
  ///
  /// If the stream emits an error, the error will be handled by
  /// [UseRepoMixin.onDependencyError]. The dependency recovers when the stream
  /// emits another payload.
  final T Function<T>(
    Object key, {
    required Object sourceKey,
    required Stream<T> Function() createStream,
  })
  payloadStream;
}

final class _WatchedExternalDependency {
  _WatchedExternalDependency({
    required this.changeSignal,
    required this.subscription,
    required this.valueType,
  });

  Stream changeSignal;
  StreamSubscription subscription;
  final Type valueType;
  Object? lastError;
  StackTrace? lastStackTrace;

  bool get hasError => lastError != null;

  void clearError() {
    lastError = null;
    lastStackTrace = null;
  }

  void setError(Object error, StackTrace stackTrace) {
    lastError = error;
    lastStackTrace = stackTrace;
  }
}

final Object _missingPayload = Object();

final class _UseRepoDisposed implements Exception {
  const _UseRepoDisposed();
}

final class _UseRepoDebugTracker {
  UseRepoDebugTriggerInfo? latestTrigger;
  var activeRebuildCount = 0;
  var totalRebuildCount = 0;
  var supersededRebuildCount = 0;
  var disposed = false;
}

final class _WatchedPayloadStreamDependency<T> {
  _WatchedPayloadStreamDependency({
    required this.sourceKey,
    required this.payloadType,
    required this.streamType,
  });

  final Object sourceKey;
  final Type payloadType;
  final Type streamType;
  late StreamSubscription<T> subscription;
  Object? _latestValue = _missingPayload;
  Object? lastError;
  StackTrace? lastStackTrace;
  bool isClosed = false;

  bool get hasValue => !identical(_latestValue, _missingPayload);

  T get value => _latestValue as T;

  bool get hasError => lastError != null;

  void clearError() {
    lastError = null;
    lastStackTrace = null;
  }

  void setError(Object error, StackTrace stackTrace) {
    lastError = error;
    lastStackTrace = stackTrace;
  }

  void setValue(T value) {
    _latestValue = value;
    clearError();
  }
}

/// Type alias for a common UseRepoMixin configuration where the derived state is a RepoState.
typedef UseRepoStateMixin<T> =
    UseRepoMixin<RepoDataState<T>, RepoErrorState<T>, RepoLoadingState<T>>;

/// Derived-state mixin for watching other repos and external signals.
///
/// Tracks dependent repos and external invalidation sources, then rebuilds a
/// derived state machine whenever those dependencies change.
///
/// Some repos are projections of other repos and should not have to manually
/// manage subscription, loading, and error fan-in logic.
///
/// The mixin discovers dependencies while [onDependenciesReady] runs, subscribes
/// to them, and routes changes through [onDependenciesReady],
/// [onDependencyError], and [onDependenciesLoading].
///
/// - Call [installUseRepoHooks] in the constructor.
/// - Dependency discovery is lazy and happens from the first build pass.
/// - Non-repo consumers wait for [DependencyReadiness] before first resolving
///   each repo. Derived repos wait only for missing registrations to avoid
///   waiting on the runtime that is initializing them.
/// - External streams are invalidation-only; emitted payloads are ignored.
///
/// - `D`: derived data payload when dependencies are ready.
/// - `E`: derived error payload.
/// - `L`: derived loading payload.
///
/// For example:
/// ```dart
/// class ProfileRepo with UseRepoMixin<UserProfile, Object, void> {}
/// ```
///
/// {@category repo}
mixin UseRepoMixin<D, E, L> on LifecycleMixin, LifecycleHooksMixin {
  final _subs = <StreamSubscription>[];
  final _watchedRepos = <Type, Repo>{};
  final _pendingRepoResolutions = <Type, Future<Repo<dynamic>>>{};
  final _watchedExternalDependencies = <Object, _WatchedExternalDependency>{};
  final _watchedPayloadStreamDependencies =
      <Object, _WatchedPayloadStreamDependency<dynamic>>{};

  bool _installed = false;
  bool _useRepoDisposed = false;
  int _stateChangeVersion = 0;

  D? _lastData;
  E? _lastError;
  L? _lastLoading;

  _UseRepoDebugTracker? _useRepoDebugTracker;

  /// Returns a metadata-only snapshot of the current dependency graph.
  ///
  /// The snapshot is available only when assertions are enabled. It is
  /// intended for diagnostics integrations and must not be used to control
  /// application behavior. Dependency keys, payloads, errors, and stack traces
  /// are never included.
  @protected
  UseRepoDebugSnapshot? get useRepoDebugSnapshot {
    UseRepoDebugSnapshot? snapshot;
    assert(() {
      final tracker = _useRepoDebugTracker;
      if (tracker == null) return true;

      final dependencies = <UseRepoDependencyDebugInfo>[
        for (final repo in _watchedRepos.values)
          UseRepoRepoDependencyDebugInfo(
            repoType: repo.runtimeType,
            state: repo.state.hasError
                ? UseRepoDependencyDebugState.error
                : repo.state.isLoading
                ? UseRepoDependencyDebugState.loading
                : UseRepoDependencyDebugState.data,
            errorType: repo.state.hasError
                ? repo.state.asError.error.runtimeType
                : null,
          ),
        for (final entry in _watchedExternalDependencies.entries)
          UseRepoExternalDependencyDebugInfo(
            keyType: entry.key.runtimeType,
            valueType: entry.value.valueType,
            streamType: entry.value.changeSignal.runtimeType,
            state: entry.value.hasError
                ? UseRepoDependencyDebugState.error
                : UseRepoDependencyDebugState.data,
            errorType: entry.value.lastError?.runtimeType,
          ),
        for (final entry in _watchedPayloadStreamDependencies.entries)
          UseRepoPayloadDependencyDebugInfo(
            keyType: entry.key.runtimeType,
            sourceKeyType: entry.value.sourceKey.runtimeType,
            payloadType: entry.value.payloadType,
            streamType: entry.value.streamType,
            state: entry.value.hasError
                ? UseRepoDependencyDebugState.error
                : entry.value.isClosed
                ? UseRepoDependencyDebugState.closed
                : entry.value.hasValue
                ? UseRepoDependencyDebugState.data
                : UseRepoDependencyDebugState.pending,
            errorType: entry.value.lastError?.runtimeType,
          ),
      ];

      snapshot = UseRepoDebugSnapshot(
        state: tracker.disposed
            ? UseRepoDebugState.disposed
            : _lastError != null
            ? UseRepoDebugState.error
            : _lastData != null
            ? UseRepoDebugState.data
            : UseRepoDebugState.loading,
        latestTrigger: tracker.latestTrigger,
        dependencies: dependencies,
        pendingRepoTypes: _pendingRepoResolutions.keys.toList(),
        subscriptionCount: _subs.length,
        stateChangeVersion: _stateChangeVersion,
        activeRebuildCount: tracker.activeRebuildCount,
        totalRebuildCount: tracker.totalRebuildCount,
        supersededRebuildCount: tracker.supersededRebuildCount,
      );
      return true;
    }());
    return snapshot;
  }

  bool _recordUseRepoDebugTrigger(
    UseRepoDebugTriggerKind kind, [
    Type? sourceType,
  ]) {
    _useRepoDebugTracker?.latestTrigger = UseRepoDebugTriggerInfo(
      kind,
      sourceType: sourceType,
    );
    return true;
  }

  bool _startUseRepoDebugRebuild() {
    final tracker = _useRepoDebugTracker;
    if (tracker != null) {
      tracker.activeRebuildCount++;
      tracker.totalRebuildCount++;
    }
    return true;
  }

  bool _finishUseRepoDebugRebuild() {
    final tracker = _useRepoDebugTracker;
    if (tracker != null && tracker.activeRebuildCount > 0) {
      tracker.activeRebuildCount--;
    }
    return true;
  }

  bool _recordSupersededUseRepoDebugRebuild() {
    _useRepoDebugTracker?.supersededRebuildCount++;
    return true;
  }

  Future<void> _onWatchedRepoStateChange(Repo changedRepo) async {
    if (_useRepoDisposed) return;

    assert(
      _recordUseRepoDebugTrigger(
        UseRepoDebugTriggerKind.repoChange,
        changedRepo.runtimeType,
      ),
    );

    log(
      'Detected state change in dependencies (${changedRepo.runtimeType}). Re-evaluating...',
    );
    final version = ++_stateChangeVersion;
    await _rebuildDependencyState(version);
  }

  Future<void> _rebuildDependencyState(int version) async {
    if (_useRepoDisposed) return;

    assert(_startUseRepoDebugRebuild());

    try {
      var anyLoading = false;
      Object? firstError;
      StackTrace? firstErrorStackTrace;

      D? nextData = _lastData;
      E? nextError = _lastError;
      L? nextLoading = _lastLoading;

      for (final repo in _watchedRepos.values) {
        if (repo.state.hasError) {
          log(
            'Dependency of type ${repo.runtimeType} has error. Rebuilding error state...',
          );
          final repoError = repo.state.asError;
          firstError = repoError.error;
          firstErrorStackTrace = repoError.stackTrace;
          break;
        }
        if (repo.state.isLoading) {
          log(
            'Dependency of type ${repo.runtimeType} is loading. Rebuilding loading state...',
          );
          anyLoading = true;
        }
      }

      if (firstError == null) {
        for (final entry in _watchedExternalDependencies.entries) {
          final dependency = entry.value;
          if (!dependency.hasError) continue;

          log(
            'External dependency with key ${entry.key.runtimeType} has error. Rebuilding error state...',
          );
          firstError = dependency.lastError;
          firstErrorStackTrace = dependency.lastStackTrace;
          break;
        }
      }

      final allDataReady = !anyLoading && firstError == null;

      try {
        if (firstError != null) {
          nextError = await onDependencyError(firstError, firstErrorStackTrace);
          nextLoading = null;
          nextData = null;
        } else if (anyLoading) {
          nextError = null;
          nextLoading = onDependenciesLoading();
          nextData = null;
        } else if (allDataReady) {
          log('All dependencies are ready. Rebuilding data...');
          nextError = null;
          nextLoading = null;
          nextData = await _onDependenciesReady();
          log('Dependencies ready, obtained new data.');
        }
      } on _UseRepoDisposed {
        return;
      } on NoRepoDataError catch (e, st) {
        if (e.state.isLoading) {
          nextError = null;
          nextLoading = onDependenciesLoading();
          nextData = null;
        } else {
          nextError = await onDependencyError(e, st);
          nextLoading = null;
          nextData = null;
        }
      } catch (e, st) {
        nextError = await onDependencyError(e, st);
        nextLoading = null;
        nextData = null;
      }

      if (_useRepoDisposed) return;
      if (version != _stateChangeVersion) {
        assert(_recordSupersededUseRepoDebugRebuild());
        return;
      }

      _lastData = nextData;
      _lastError = nextError;
      _lastLoading = nextLoading;

      log('State rebuilt, notifying listeners...');
      await dependenciesChanged();
    } finally {
      assert(_finishUseRepoDebugRebuild());
    }
  }

  Future<void> _discover() async {
    log('Discovering dependencies...');
    await _refreshDependenciesWithTrigger(
      UseRepoDebugTriggerKind.initialization,
    );
    log(
      'Dependency discovery complete. Currently watching ${_watchedRepos.length} repos.',
    );
  }

  /// Re-evaluates the derived state from the current dependencies.
  ///
  /// Use this when an external lifecycle event invalidates the computation
  /// performed by [onDependenciesReady] without emitting a dependency change.
  /// For example, Flutter consumers can call this during hot reload so edits to
  /// query logic take effect while preserving the surrounding widget state.
  ///
  /// The latest refresh wins when multiple refreshes overlap. Dependency
  /// subscriptions are reused and any newly accessed dependencies are
  /// discovered in the normal way.
  @protected
  Future<void> refreshDependencies() =>
      _refreshDependenciesWithTrigger(UseRepoDebugTriggerKind.explicitRefresh);

  Future<void> _refreshDependenciesWithTrigger(
    UseRepoDebugTriggerKind trigger,
  ) async {
    if (!_installed) {
      throw StateError(
        'UseRepoMixin not installed. Call installUseRepoHooks in the constructor.',
      );
    }

    assert(_recordUseRepoDebugTrigger(trigger));
    final version = ++_stateChangeVersion;
    await _rebuildDependencyState(version);
  }

  /// Installs the necessary lifecycle hooks for the [UseRepoMixin].
  /// Should be called in the constructor of the class using this mixin.
  @mustCallInConstructor
  void installUseRepoHooks() {
    if (_installed) return;
    _installed = true;

    assert(() {
      _useRepoDebugTracker = _UseRepoDebugTracker();
      return true;
    }());

    /// Set to loading state initially.
    _lastLoading = onDependenciesLoading();

    onInitialize(_discover);

    onActivate(() {
      for (final sub in _subs) {
        sub.resume();
      }
    });

    onDeactivate(() {
      for (final sub in _subs) {
        sub.pause();
      }
    });

    onDisposed(() {
      _useRepoDisposed = true;
      assert(() {
        _useRepoDebugTracker?.disposed = true;
        return true;
      }());
    });
    onDisposed(() async {
      for (final sub in _subs) {
        await sub.cancel();
      }
      _subs.clear();
    });
    onDisposed(_watchedRepos.clear);
    onDisposed(_pendingRepoResolutions.clear);
    onDisposed(_watchedExternalDependencies.clear);
    onDisposed(_watchedPayloadStreamDependencies.clear);
  }

  /// Watches a [Repo] of type [R] managing data of type [S] and
  /// returns a tuple containing the data from the repo and the repo itself.
  ///
  /// Throws a [NoRepoDataError] if the repo's state does not contain data.
  @Deprecated('Use the provided use arg in onDependenciesReady instead')
  @visibleForTesting
  Future<(S, R)> useRepo<S, R extends Repo<S>>() => _useRepo<S, R>();

  /// Watches an external [changeSignal] while reading the latest value
  /// synchronously from [syncSnapshot].
  ///
  /// The [changeSignal] is treated as invalidation-only. Emitted values are
  /// ignored. Use [key] as the stable identity for this dependency across
  /// rebuilds.
  @Deprecated('Use the provided use arg in onDependenciesReady instead')
  @visibleForTesting
  T watchExternal<T>(
    Object key, {
    required Stream changeSignal,
    required T Function() syncSnapshot,
  }) => _watchExternal(
    key,
    changeSignal: changeSignal,
    syncSnapshot: syncSnapshot,
  );

  Future<(S, R)> _useRepo<S, R extends Repo<S>>() async {
    if (!_installed) {
      throw StateError(
        'UseRepoMixin not installed. Call installUseRepoHooks in the constructor.',
      );
    }
    if (_useRepoDisposed) throw const _UseRepoDisposed();

    if (_watchedRepos.containsKey(R)) {
      final repo = _watchedRepos[R] as R;
      return (repo.state.requireData, repo);
    }

    final pending = _pendingRepoResolutions[R];
    if (pending != null) {
      final repo = await pending as R;
      return (repo.state.requireData, repo);
    }

    final resolveAndWatch = (() async {
      final repoIsRegistered = GetIt.I.isRegistered<R>();
      final shouldWaitForRuntime = this is! Repo || !repoIsRegistered;
      if (shouldWaitForRuntime && GetIt.I.isRegistered<DependencyReadiness>()) {
        log('Waiting for pending runtime work before resolving $R...');
        await GetIt.I<DependencyReadiness>().waitForPendingDependencies();
      }

      if (_useRepoDisposed) throw const _UseRepoDisposed();

      final repo = await GetIt.I.getAsync<R>();
      if (_useRepoDisposed) throw const _UseRepoDisposed();
      if (_watchedRepos.containsKey(R)) {
        return _watchedRepos[R] as R;
      }

      log('Discovered new dependency. Now watching ${repo.logTag}');
      _watchedRepos[R] = repo;
      assert(
        _recordUseRepoDebugTrigger(
          UseRepoDebugTriggerKind.repoResolved,
          repo.runtimeType,
        ),
      );

      final stateAtSubscription = repo.state;
      var awaitingInitialReplay = true;
      final sub = repo.stream.listen((state) async {
        if (awaitingInitialReplay && identical(state, stateAtSubscription)) {
          awaitingInitialReplay = false;
          return;
        }
        awaitingInitialReplay = false;
        await _onWatchedRepoStateChange(repo);
      });

      _subs.add(sub);
      return repo;
    })();

    _pendingRepoResolutions[R] = resolveAndWatch;
    late final R repo;
    try {
      repo = await resolveAndWatch;
    } finally {
      await _pendingRepoResolutions.remove(R);
    }

    return (repo.state.requireData, repo);
  }

  T _watchExternal<T>(
    Object key, {
    required Stream changeSignal,
    required T Function() syncSnapshot,
  }) {
    if (!_installed) {
      throw StateError(
        'UseRepoMixin not installed. Call installUseRepoHooks in the constructor.',
      );
    }
    if (_useRepoDisposed) throw const _UseRepoDisposed();

    final watchedDependency = _watchedExternalDependencies[key];
    if (watchedDependency == null) {
      _watchedExternalDependencies[key] = _subscribeToExternalDependency<T>(
        key,
        changeSignal,
      );
    } else if (!identical(watchedDependency.changeSignal, changeSignal)) {
      _replaceExternalDependency<T>(
        key,
        watchedDependency: watchedDependency,
        changeSignal: changeSignal,
      );
    }

    return syncSnapshot();
  }

  T _watchPayloadStream<T>(
    Object key, {
    required Object sourceKey,
    required Stream<T> Function() createStream,
  }) {
    if (!_installed) {
      throw StateError(
        'UseRepoMixin not installed. Call installUseRepoHooks in the constructor.',
      );
    }
    if (_useRepoDisposed) throw const _UseRepoDisposed();

    final watchedDependency = _watchedPayloadStreamDependencies[key];
    if (watchedDependency == null) {
      _subscribeToPayloadStreamDependency<T>(
        key,
        sourceKey: sourceKey,
        stream: createStream(),
      );
    } else if (watchedDependency.sourceKey != sourceKey ||
        watchedDependency.isClosed) {
      _replacePayloadStreamDependency<T>(
        key,
        watchedDependency: watchedDependency,
        sourceKey: sourceKey,
        stream: createStream(),
      );
    }

    final dependency = _watchedPayloadStreamDependencies[key]!;
    if (dependency.hasError) {
      Error.throwWithStackTrace(
        dependency.lastError!,
        dependency.lastStackTrace ?? StackTrace.current,
      );
    }
    if (!dependency.hasValue) {
      throw NoRepoDataError(RepoState<T>.loading());
    }

    return dependency.value as T;
  }

  _WatchedExternalDependency _subscribeToExternalDependency<T>(
    Object key,
    Stream changeSignal,
  ) {
    late final _WatchedExternalDependency watchedDependency;
    final sub = changeSignal.listen(
      (_) async {
        if (!identical(_watchedExternalDependencies[key], watchedDependency)) {
          return;
        }
        watchedDependency.clearError();
        assert(
          _recordUseRepoDebugTrigger(
            UseRepoDebugTriggerKind.externalSignal,
            key.runtimeType,
          ),
        );
        final version = ++_stateChangeVersion;
        await _rebuildDependencyState(version);
      },
      onError: (Object error, StackTrace stackTrace) async {
        if (!identical(_watchedExternalDependencies[key], watchedDependency)) {
          return;
        }
        watchedDependency.setError(error, stackTrace);
        assert(
          _recordUseRepoDebugTrigger(
            UseRepoDebugTriggerKind.externalError,
            key.runtimeType,
          ),
        );
        final version = ++_stateChangeVersion;
        await _rebuildDependencyState(version);
      },
    );

    watchedDependency = _WatchedExternalDependency(
      changeSignal: changeSignal,
      subscription: sub,
      valueType: T,
    );
    _subs.add(sub);

    return watchedDependency;
  }

  void _replaceExternalDependency<T>(
    Object key, {
    required _WatchedExternalDependency watchedDependency,
    required Stream changeSignal,
  }) {
    _subs.remove(watchedDependency.subscription);
    unawaited(watchedDependency.subscription.cancel());
    _watchedExternalDependencies[key] = _subscribeToExternalDependency<T>(
      key,
      changeSignal,
    );
  }

  void _subscribeToPayloadStreamDependency<T>(
    Object key, {
    required Object sourceKey,
    required Stream<T> stream,
  }) {
    final watchedDependency = _WatchedPayloadStreamDependency<T>(
      sourceKey: sourceKey,
      payloadType: T,
      streamType: stream.runtimeType,
    );

    _watchedPayloadStreamDependencies[key] = watchedDependency;

    final sub = stream.listen(
      (value) async {
        if (!identical(
          _watchedPayloadStreamDependencies[key],
          watchedDependency,
        )) {
          return;
        }
        watchedDependency.setValue(value);
        assert(
          _recordUseRepoDebugTrigger(
            UseRepoDebugTriggerKind.payloadValue,
            key.runtimeType,
          ),
        );
        final version = ++_stateChangeVersion;
        await _rebuildDependencyState(version);
      },
      onError: (Object error, StackTrace stackTrace) async {
        if (!identical(
          _watchedPayloadStreamDependencies[key],
          watchedDependency,
        )) {
          return;
        }
        watchedDependency.setError(error, stackTrace);
        assert(
          _recordUseRepoDebugTrigger(
            UseRepoDebugTriggerKind.payloadError,
            key.runtimeType,
          ),
        );
        final version = ++_stateChangeVersion;
        await _rebuildDependencyState(version);
      },
      onDone: () {
        if (_useRepoDisposed ||
            !identical(
              _watchedPayloadStreamDependencies[key],
              watchedDependency,
            )) {
          return;
        }
        watchedDependency.isClosed = true;
        assert(
          _recordUseRepoDebugTrigger(
            UseRepoDebugTriggerKind.payloadClosed,
            key.runtimeType,
          ),
        );

        scheduleMicrotask(() {
          if (_useRepoDisposed ||
              !identical(
                _watchedPayloadStreamDependencies[key],
                watchedDependency,
              )) {
            return;
          }

          final version = ++_stateChangeVersion;
          unawaited(_rebuildDependencyState(version));
        });
      },
    );

    watchedDependency.subscription = sub;
    _subs.add(sub);
  }

  void _replacePayloadStreamDependency<T>(
    Object key, {
    required _WatchedPayloadStreamDependency<dynamic> watchedDependency,
    required Object sourceKey,
    required Stream<T> stream,
  }) {
    _subs.remove(watchedDependency.subscription);
    unawaited(watchedDependency.subscription.cancel());
    _subscribeToPayloadStreamDependency<T>(
      key,
      sourceKey: sourceKey,
      stream: stream,
    );
  }

  FutureOr<D> _onDependenciesReady() => onDependenciesReady(
    UseHooks(
      repo: _useRepo,
      externalStream: _watchExternal,
      payloadStream: _watchPayloadStream,
    ),
  );

  /// A callback function that is called when all watched repositories are ready.
  /// Call [UseHooks.repo] within this function to access repositories required to build the value.
  ///
  /// Called whenever any of the watched repositories emit a new state and *all* watched
  /// repositories have a state of [RepoDataState].
  ///
  /// If this function throws an exception, the error will be handled by [onDependencyError].
  FutureOr<D> onDependenciesReady(UseHooks use);

  /// A callback function that is called when any of the watched repositories emit an error state
  /// or when an exception is thrown during the execution of [_onDependenciesReady].
  ///
  /// Takes precedence over [onDependenciesLoading].
  FutureOr<E> onDependencyError(Object error, StackTrace? stackTrace);

  /// A callback function that is called when any of the watched repositories emit a loading state.
  L onDependenciesLoading();

  /// A pattern matching function that executes the appropriate callback
  /// based on the last known state of the watched repositories.
  R when<R>({
    required R Function(D data) data,
    required R Function(E error) error,
    required R Function(L loading) loading,
  }) {
    if (_lastError != null) {
      return error(_lastError as E);
    } else if (_lastLoading != null) {
      return loading(_lastLoading as L);
    } else if (_lastData != null) {
      return data(_lastData as D);
    } else {
      throw StateError('No state available to handle.');
    }
  }

  /// An asynchronous pattern matching function that executes the appropriate callback
  /// based on the last known state of the watched repositories.
  Future<R> whenAsync<R>({
    required FutureOr<R> Function(D data) data,
    required FutureOr<R> Function(E error) error,
    required FutureOr<R> Function(L loading) loading,
  }) async {
    if (_lastError != null) {
      return await error(_lastError as E);
    } else if (_lastLoading != null) {
      return await loading(_lastLoading as L);
    } else if (_lastData != null) {
      return await data(_lastData as D);
    } else {
      throw StateError('No state available to handle.');
    }
  }
}

/// Convenience adapter for repos that fully derive their state from other repos.
///
/// Bridges [UseRepoMixin] into a normal [Repo] by mapping dependency-ready,
/// dependency-loading, and dependency-error callbacks to repo emissions.
///
/// Many projection repos want the default behavior of "build data when ready,
/// otherwise emit loading or error" without rewriting the adapter logic.
///
/// [DeferredRepoMixin] implements [UseRepoMixin]'s callbacks and forwards the
/// result of [build] into [data], [loading], or [error].
///
/// Dependencies are still discovered lazily through [UseRepoMixin].
///
/// - `T`: the repo's derived data type.
///
/// For example:
/// ```dart
/// class DashboardRepo extends Repo<DashboardState>
///     with
///         RepoLifecycleMixin<DashboardState>,
///         RepoLifecycleHooksMixin<DashboardState>,
///         UseRepoMixin<void, void, void>,
///         DeferredRepoMixin<DashboardState> {}
/// ```
///
/// {@category repo}

mixin DeferredRepoMixin<T>
    on
        Repo<T>,
        UseRepoMixin<RepoDataState<T>, RepoErrorState<T>, RepoLoadingState<T>> {
  /// Installs the necessary lifecycle hooks for the [DeferredRepoMixin].
  ///
  /// Should be called in the constructor of the class using this mixin, after calling [installUseRepoHooks].
  @mustCallInConstructor
  void installDeferredRepoHooks() {
    onDependenciesChanged(() {
      when(data: setState, error: setState, loading: setState);
    });
  }

  @mustCallSuper
  @override
  FutureOr<RepoErrorState<T>> onDependencyError(
    Object error,
    StackTrace? stackTrace,
  ) {
    return RepoErrorState<T>(error, stackTrace);
  }

  @nonVirtual
  @override
  RepoLoadingState<T> onDependenciesLoading() {
    return RepoLoadingState<T>(DateTime.now());
  }

  @nonVirtual
  @override
  FutureOr<RepoDataState<T>> onDependenciesReady(UseHooks use) async {
    return RepoDataState(await build(use));
  }

  /// A builder function that constructs the state of this repo of type [T].
  ///
  /// When implementing this method, you can call [UseHooks.repo] to access other repositories
  /// that this repository depends on.
  FutureOr<T> build(UseHooks use);
}
