export '../shared/shared.dart';
export 'domain/services/services.dart';
export '../repo/repo.dart';
export '../repo/domain/domain.dart';
export '../repo/mixins/mixins.dart';
export '../routing/routing.dart';
export '../telemetry/telemetry.dart';
export '../cache/cache.dart';
export '../persistence/persistence.dart';
export '../transactions/transactions.dart';
export '../presentation/presentation.dart';

import 'dart:async';

import 'package:get_it/get_it.dart' hide Disposable;
import 'package:get_it/get_it.dart' as di;
import 'package:grumpy/src/transactions/infra/services/services.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:grumpy/grumpy.dart';
import 'package:grumpy/src/cache/infra/services/default_cache_pipeline_service.dart';
import 'package:grumpy/src/module/infra/services/canonical_module_registry_service.dart';
import 'package:grumpy/src/persistence/infra/services/default_repo_bootstrap_service.dart';
import 'package:grumpy/src/persistence/infra/services/noop_repo_state_persistence_service.dart';
import 'package:grumpy/src/routing/infra/services/routing_kit_routing_service.dart';
import 'package:grumpy/src/telemetry/infra/services/noop_analytics_service.dart';
import 'package:grumpy/src/telemetry/infra/services/noop_telemetry_service.dart';
import 'package:grumpy/src/cache/infra/services/no_op_memory_cache_layer_service.dart';
import 'package:grumpy/src/cache/infra/services/no_op_file_cache_layer_service.dart';

/// {@template module_route_config_types}
/// `RouteType` is the presentation type returned by this module's routes, and
/// `Config` is the configuration object resolved from DI during binding.
/// {@endtemplate}
///
/// {@template module_lifecycle_notes}
/// Lifecycle-managed injectables must be singletons, repos are registered as
/// async lazy singletons and initialized before first use, and `destroy()`
/// tears down the module's DI scope.
/// {@endtemplate}
///
/// A modular unit of functionality within an application.
///
/// Defines one feature's DI scope, routes, lifecycle-managed dependencies, and
/// imported module graph.
///
/// Feature composition should live in one runtime boundary instead of being
/// scattered across app startup code.
///
/// [Module] creates a scoped `GetIt` container, binds external dependencies,
/// services, datasources, and repos, then activates or deactivates them in a
/// deterministic order.
///
/// {@macro module_lifecycle_notes}
///
/// {@macro module_route_config_types}
///
/// For example:
/// ```dart
/// class SettingsModule extends Module<Object, AppConfig> {
///   @override
///   List<Route<Object, AppConfig>> get routes => const [];
/// }
/// ```
///
/// {@category module}

abstract class Module<RouteType, Config extends Object>
    with LifecycleMixin, LogMixin, Disposable {
  GetIt get _di => GetIt.instance;

  bool _isActive = false;
  bool _isActivating = false;
  bool _isInitializing = false;

  @override
  String get group => 'Module';

  @override
  Level get logLevel => Level.FINEST;

  bool _disposed = false;
  bool _ownsScope = false;
  Future<void>? _initializeFuture, _destroyFuture;
  final List<Future<void> Function()> _releases = [];
  final Set<Object> _released = Set.identity();
  final List<(Object, StackTrace)> _disposalErrors = [];
  bool _superDestroyed = false;

  Future<void> _disposeValue(Object value) async {
    if (_released.add(value) && value is di.Disposable) await value.onDispose();
  }

  /// Registers an instance in this module's scope.
  ///
  /// Set [owned] to false for aliases or values owned by the host.
  @protected
  void bindInstance<T extends Object>(T value, {bool owned = true}) {
    if (!owned) {
      _di.registerFactory<T>(() => value);
      return;
    }
    _di.registerSingleton<T>(value);
    _releases.add(() async {
      await _di.unregister<T>(
        instance: value,
        disposingFunction: _disposeValue,
      );
    });
  }

  /// Registers application infrastructure before ordinary feature bindings.
  @protected
  void bindInfrastructure() {}

  final List<Future<Repo<dynamic>> Function()> _repoResolvers = [];
  final List<Future<LifecycleMixin?> Function()> _injectableResolvers = [];
  final List<Repo<dynamic>> _activeRepos = [];
  final Set<Repo<dynamic>> _activeRepoSet = {};
  final List<LifecycleMixin> _activeInjectables = [];
  final Set<LifecycleMixin> _activeInjectableSet = {};
  final Set<LifecycleMixin> _initializedInjectables = {};

  /// `true` if the module is active and ready to serve its functionality.
  bool get isActive => _isActive;

  /// `true` if the module is in the process of initializing.
  bool get isInitializing => _isInitializing;

  /// `true` if the module is in the process of activating.
  bool get isActivating => _isActivating;

  /// `true` if the module has been disposed and should no longer be used.
  bool get isDisposed => _disposed;

  /// `true` if the module is active and not in the process of initializing or activating.
  bool get isReady => isActive && !isInitializing && !isActivating;

  /// Override this getter to declare module dependencies.
  ///
  /// Dependency mounting and activation are orchestrated by
  /// [ModuleRegistryService].
  List<Module<RouteType, Config>> get imports => const [];

  /// Override this method to bind external dependencies, such as dio configurations,
  /// http clients, or other third-party services.
  ///
  /// Called first during module initialization.
  void bindExternalDeps(Bind<Object, Config> bind) {}

  /// Override this method to bind services specific to this module.
  ///
  /// Called after [bindExternalDeps] during module initialization.
  void bindServices(Bind<Service, Config> bind) {}

  /// Override this method to bind data sources specific to this module.
  ///
  /// Called after [bindServices] during module initialization.
  void bindDatasources(Bind<Datasource, Config> bind) {}

  /// Override this method to bind repositories specific to this module.
  ///
  /// Called after [bindDatasources] during module initialization.
  void bindRepos(Bind<Repo, Config> bind) {}

  void _bindInjectable<T extends Injectable>(
    InjectableFactory<T, Config> builder,
  ) {
    final probe = builder(_di.get<Config>(), _di.get);
    final lifecycleManaged = probe is LifecycleMixin;

    if (lifecycleManaged && !probe.singelton) {
      _releases.add(() => _disposeValue(probe));
      throw StateError(
        'Lifecycle-capable injectable ${probe.runtimeType} must be singleton. '
        'Set singelton => true or remove LifecycleMixin.',
      );
    }

    if (probe.singelton) {
      if (lifecycleManaged) {
        var resolved = false;
        _di.registerLazySingleton<T>(() {
          if (!_isActive && !_isActivating && !_isInitializing) {
            throw StateError(
              'Lifecycle-managed $T cannot be resolved before activation.',
            );
          }
          resolved = true;
          return probe;
        });
        _releases.add(() async {
          if (resolved) {
            await _di.unregister<T>(
              instance: probe,
              disposingFunction: _disposeValue,
            );
          } else {
            await _disposeValue(probe);
          }
        });
        _injectableResolvers.add(() async => _di.get<T>() as LifecycleMixin);
      } else {
        bindInstance<T>(probe);
      }
    } else {
      // A lifetime probe is not a DI-managed factory instance.
      _releases.add(() => _disposeValue(probe));
      _di.registerFactory<T>(() => builder(_di.get<Config>(), _di.get));
    }
  }

  @mustCallSuper
  @override
  FutureOr<void> activate() async {
    if (_isActive) return;

    _isActivating = true;
    try {
      for (final resolveInjectable in _injectableResolvers) {
        final injectable = await resolveInjectable();
        if (injectable == null) continue;
        if (_initializedInjectables.add(injectable)) {
          await injectable.initialize();
        }
        if (_activeInjectableSet.add(injectable)) {
          _activeInjectables.add(injectable);
          await injectable.activate();
        }
      }

      for (final resolveRepo in _repoResolvers) {
        final repo = await resolveRepo();
        if (_activeRepoSet.add(repo)) {
          _activeRepos.add(repo);
          await repo.activate();
        }
      }
      _isActive = true;
    } catch (e, s) {
      await _rollbackFailedActivation(e, s);
      rethrow;
    } finally {
      _isActivating = false;
    }
  }

  Future<void> _rollbackFailedActivation(Object error, StackTrace stack) async {
    log(
      'Activation failed. Rolling back activated dependencies.',
      error,
      stack,
    );

    for (final repo in _activeRepos.reversed) {
      try {
        await repo.deactivate();
      } catch (e, s) {
        log('Rollback deactivate failed for repo ${repo.runtimeType}', e, s);
      }
    }
    _activeRepos.clear();
    _activeRepoSet.clear();

    for (final injectable in _activeInjectables.reversed) {
      try {
        await injectable.deactivate();
      } catch (e, s) {
        log(
          'Rollback deactivate failed for injectable ${injectable.runtimeType}',
          e,
          s,
        );
      }
    }
    _activeInjectables.clear();
    _activeInjectableSet.clear();

    _isActive = false;
  }

  @mustCallSuper
  @override
  FutureOr<void> deactivate() async {
    Object? failure;
    StackTrace? stack;
    final values = <LifecycleMixin>[
      ..._activeRepos.reversed,
      ..._activeInjectables.reversed,
    ];
    _activeRepos.clear();
    _activeRepoSet.clear();
    _activeInjectables.clear();
    _activeInjectableSet.clear();
    _isActive = false;
    for (final value in values) {
      try {
        await value.deactivate();
      } catch (e, s) {
        failure ??= e;
        stack ??= s;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }

  @override
  FutureOr<void> dependenciesChanged() async {
    if (!_isActive) return;

    for (final injectable in _activeInjectables) {
      await injectable.dependenciesChanged();
    }

    for (final repo in _activeRepos) {
      await repo.dependenciesChanged();
    }
  }

  @mustCallSuper
  @override
  FutureOr<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    if (_disposed) throw StateError('Module has been disposed.');
    final scope = runtimeType.toString();
    if (_di.hasScope(scope)) throw StateError('Scope $scope is already owned.');
    _isInitializing = true;
    try {
      _di.pushNewScope(scopeName: scope, dispose: _disposeScope);
      _ownsScope = true;
      bindInfrastructure();
      bindExternalDeps(<T extends Object>(builder) {
        bindInstance<T>(builder(_di.get<Config>(), _di.get));
      });
      bindServices(<T extends Service>(builder) => _bindInjectable<T>(builder));
      bindDatasources(
        <T extends Datasource>(builder) => _bindInjectable<T>(builder),
      );
      bindRepos(<T extends Repo>(builder) {
        _di.registerLazySingletonAsync<T>(() async {
          final repo = builder(_di.get<Config>(), _di.get);
          try {
            await repo.initialize();
          } catch (_) {
            await _disposeValue(repo);
            rethrow;
          }
          _releases.add(() async {
            await _di.unregister<T>(
              instance: repo,
              disposingFunction: _disposeValue,
            );
          });
          return repo;
        }, dispose: (_) {});
        _repoResolvers.add(() => _di.getAsync<T>());
      });
    } catch (_) {
      // Do not dispatch to root shutdown while initialization is incomplete.
      try {
        await _destroyModule();
      } catch (_) {}
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _disposeScope() async {
    Object? failure;
    StackTrace? stack;
    _disposed = true;
    final releases = _releases.reversed.toList();
    _releases.clear();
    for (final release in releases) {
      try {
        await release();
      } catch (e, s) {
        failure ??= e;
        stack ??= s;
      }
    }
    if (failure != null) _disposalErrors.add((failure, stack!));
  }

  @override
  @mustCallSuper
  FutureOr<void> destroy() async {
    await _destroyModule();
    if (!_superDestroyed) {
      _superDestroyed = true;
      await super.destroy();
    }
  }

  Future<void> _destroyModule() => _destroyFuture ??= _destroyOwnedScope();

  Future<void> _destroyOwnedScope() async {
    Object? failure;
    StackTrace? stack;
    try {
      if (_isActive ||
          _activeRepos.isNotEmpty ||
          _activeInjectables.isNotEmpty) {
        await deactivate();
      }
    } catch (e, s) {
      failure = e;
      stack = s;
    }
    try {
      if (_ownsScope && _di.hasScope(runtimeType.toString())) {
        await _di.dropScope(runtimeType.toString());
      }
    } catch (e, s) {
      failure ??= e;
      stack ??= s;
    }
    _disposed = true;
    if (_disposalErrors.isNotEmpty) {
      failure ??= _disposalErrors.first.$1;
      stack ??= _disposalErrors.first.$2;
    }
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }

  /// The routes provided by this module.
  List<Route<RouteType, Config>> get routes;

  @override
  String toString() => '$logTag<$RouteType,$Config>';
}

/// Function signature used by module binding methods.
///
/// Describes how modules register services, datasources, or repos.
///
/// A single binding callback shape keeps `bindServices`, `bindDatasources`, and
/// related methods consistent.
///
/// The callback receives a typed [InjectableFactory] for the requested base
/// class.
///
/// The concrete DI lifetime still comes from the resolved type's
/// [Injectable.singelton] policy or repo-specific module behavior.
///
/// `Base` is the kind of thing being registered, and `Config` is the module
/// configuration available to the factory.
///
/// For example:
/// ```dart
/// void bindServices(Bind<Service, AppConfig> bind) {}
/// ```
///
/// {@category module}

typedef Bind<Base extends Object, Config extends Object> =
    void Function<T extends Base>(InjectableFactory<T, Config> builder);

/// Factory signature used to build module-managed objects.
///
/// Describes how a module constructs one injectable instance.
///
/// Builders need access to both the module config and already-registered
/// dependencies.
///
/// The function receives the active [Config] and a [Resolver] callback.
///
/// Factories should stay side-effect free except for object construction.
///
/// `T` is the type being created, and `Config` is the configuration object
/// passed to the builder.
///
/// For example:
/// ```dart
/// (cfg, resolve) => SettingsRepo(resolve<SettingsDatasource>())
/// ```
///
/// {@category module}

typedef InjectableFactory<T, Config extends Object> =
    T Function(Config cfg, Resolver resolve);

/// Typed dependency resolver passed into binding factories.
///
/// Resolves another DI-managed dependency during object construction.
///
/// Builders should depend on a narrow resolver abstraction rather than the full
/// container API.
///
/// The callback is generic and returns the requested type from the active DI
/// scope.
///
/// It is intended for use during factory execution, not as a general-purpose
/// service locator.
///
/// `T` is the dependency type to resolve.
///
/// For example:
/// ```dart
/// final analytics = resolve<AnalyticsService>();
/// ```
///
/// {@category module}

typedef Resolver = T Function<T extends Object>();

/// The root module of any Grumpy application.
///
/// Adds application-wide configuration and default builders for Grumpy's core
/// runtime services.
///
/// Every app needs one place to bind shared infrastructure such as routing,
/// telemetry, cache, persistence, and transaction support.
///
/// [RootModule] extends [Module] and exposes overridable builder getters for
/// each core service.
///
/// The defaults are intentionally safe no-op or baseline implementations. Real
/// apps usually override at least telemetry, analytics, and file-backed
/// persistence or cache services.
///
/// {@macro module_route_config_types}
///
/// For example:
/// ```dart
/// class AppModule extends RootModule<Object, AppConfig> {
///   AppModule(super.cfg);
/// }
/// ```
///
/// {@category module}

abstract class RootModule<RouteType, Config extends Object>
    extends Module<RouteType, Config> {
  /// Creates a new [RootModule] with the given [cfg].
  RootModule(this.cfg);

  /// The configuration to use throughout the application.
  final Config cfg;

  /// Creates the telemetry service instance.
  ///
  /// Override this method to enable telemetry.
  ///
  /// By default, it returns a no-op implementation.
  InjectableFactory<TelemetryService, Config> get telemetryServiceBuilder =>
      (cfg, _) => NoopTelemetryService();

  /// Creates the analytics service instance.
  ///
  /// Override this method to enable analytics.
  ///
  /// By default, it returns a no-op implementation.
  InjectableFactory<AnalyticsService, Config> get analyticsServiceBuilder =>
      (cfg, _) => NoopAnalyticsService();

  /// Creates the module registry service instance.
  ///
  /// Override this method to provide a custom module registry implementation.
  /// By default, it returns [CanonicalModuleRegistryService].
  InjectableFactory<ModuleRegistryService<RouteType, Config>, Config>
  get moduleRegistryServiceBuilder =>
      (cfg, _) => CanonicalModuleRegistryService<RouteType, Config>();

  /// Creates the routing service instance.
  ///
  /// Override this method to provide a custom routing service implementation.
  /// By default, it returns a [RoutingKitRoutingService] using the root
  /// module's routes and the registered [ModuleRegistryService].
  InjectableFactory<RoutingService<RouteType, Config>, Config>
  get routingServiceBuilder =>
      (cfg, resolve) => RoutingKitRoutingService<RouteType, Config>(
        this,
        moduleRegistry: resolve<ModuleRegistryService<RouteType, Config>>(),
      );

  /// Creates the in-memory cache layer service instance.
  InjectableFactory<MemoryCacheLayerService, Config>
  get memoryCacheLayerServiceBuilder =>
      (_, _) => const NoOpMemoryCacheLayerService();

  /// Creates the optional file cache layer service instance.
  InjectableFactory<FileCacheLayerService, Config>?
  get fileCacheLayerServiceBuilder =>
      (_, _) => const NoOpFileCacheLayerService();

  /// Creates the cache pipeline service instance.
  InjectableFactory<CachePipelineService, Config>
  get cachePipelineServiceBuilder =>
      (cfg, resolve) => DefaultCachePipelineService(
        memoryLayer: resolve<MemoryCacheLayerService>(),
        fileLayer: fileCacheLayerServiceBuilder == null
            ? null
            : resolve<FileCacheLayerService>(),
      );

  /// Creates the repo snapshot persistence service instance.
  InjectableFactory<RepoStatePersistenceService, Config>
  get repoStatePersistenceServiceBuilder =>
      (cfg, _) => NoopRepoStatePersistenceService();

  /// Creates the repo bootstrap orchestrator service instance.
  InjectableFactory<RepoBootstrapService, Config>
  get repoBootstrapServiceBuilder =>
      (cfg, resolve) => DefaultRepoBootstrapService(
        persistenceService: resolve<RepoStatePersistenceService>(),
      );

  /// Creates the transaction-engine factory service instance.
  ///
  /// Override this to customize engine selection/creation strategy.
  InjectableFactory<TxEngineFactoryService, Config>
  get txEngineFactoryServiceBuilder =>
      (cfg, _) => DefaultTxEngineFactoryService();

  ModuleRegistryService<RouteType, Config>? _registry;

  @override
  void bindInfrastructure() {
    bindInstance<Config>(cfg, owned: false);
    _bindInjectable<TelemetryService>(telemetryServiceBuilder);
    _bindInjectable<AnalyticsService>(analyticsServiceBuilder);
    _bindInjectable<ModuleRegistryService<RouteType, Config>>(
      (cfg, resolve) => _registry = moduleRegistryServiceBuilder(cfg, resolve),
    );
    _di.get<ModuleRegistryService<RouteType, Config>>();
    _bindInjectable<MemoryCacheLayerService>(memoryCacheLayerServiceBuilder);
    if (fileCacheLayerServiceBuilder != null) {
      _bindInjectable<FileCacheLayerService>(fileCacheLayerServiceBuilder!);
    }
    _bindInjectable<CachePipelineService>(cachePipelineServiceBuilder);
    _bindInjectable<RepoStatePersistenceService>(
      repoStatePersistenceServiceBuilder,
    );
    _bindInjectable<RepoBootstrapService>(repoBootstrapServiceBuilder);
    _bindInjectable<TxEngineFactoryService>(txEngineFactoryServiceBuilder);
    // Routing may depend on application bindings; construct it lazily.
    RoutingService<RouteType, Config>? router;
    _di.registerLazySingleton<RoutingService<RouteType, Config>>(() {
      final value = router = routingServiceBuilder(cfg, _di.get);
      _releases.add(() async {
        await _di.unregister<RoutingService<RouteType, Config>>(
          instance: value,
          disposingFunction: _disposeValue,
        );
      });
      return value;
    }, dispose: (_) {});
    _injectableResolvers.add(() async {
      final value = _di.get<RoutingService<RouteType, Config>>();
      return value is LifecycleMixin ? value as LifecycleMixin : null;
    });
    _di.registerFactory<DependencyReadiness>(
      () => router ?? _di.get<RoutingService<RouteType, Config>>(),
    );
  }

  /// The root route of this module.
  Route<RouteType, Config> get root => routes.root ?? Route.root(routes);

  Future<void>? _shutdownFuture;

  /// Awaits dependency-ordered shutdown and releases only this app's resources.
  ///
  /// Safe to call repeatedly, including after partial bootstrap failure.
  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    Object? failure;
    StackTrace? stack;
    try {
      await _registry?.shutdown();
    } catch (e, s) {
      failure = e;
      stack = s;
    }
    try {
      await super.destroy();
    } catch (e, s) {
      failure ??= e;
      stack ??= s;
    }
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }

  @override
  FutureOr<void> destroy() async {
    await shutdown();
    await super.destroy();
  }

  @override
  String get group => '${super.group}.RootModule';

  /// Retrieves the module configuration from the dependency injector.
  static T getConfig<T extends Object>() {
    return GetIt.instance.get<T>();
  }

  Future<void>? _bootstrapFuture;

  /// Initializes and activates the root module and its imported module graph.
  ///
  /// Use this once during application startup instead of calling [initialize]
  /// and [activate] directly. Concurrent and repeated calls share the same
  /// bootstrap operation.
  Future<void> bootstrap() {
    return _bootstrapFuture ??= _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await initialize();
      await ModuleRegistryService<RouteType, Config>().ensureActive(this);
    } catch (_) {
      try {
        await shutdown();
      } catch (_) {}
      rethrow;
    }
  }
}
