import 'package:grumpy/grumpy.dart';

/// Owns [Module] lifecycle orchestration across the app.
///
/// Tracks canonical module instances and keeps the mounted/active module graph
/// in sync with routing or other runtime demands.
///
/// Module activation has graph semantics, so the app needs one coordinator that
/// understands imports, aliases, and shared dependencies.
///
/// The registry canonicalizes modules by runtime type, computes dependency
/// graphs, and ensures modules are initialized, activated, deactivated, or
/// destroyed in the right order.
///
/// A module is considered mounted after [Module.initialize] and active after
/// [Module.activate]. Implementations must operate on canonical instances only.
///
/// - `T`: the presentation type used by registered modules.
/// - `Config`: the shared app configuration type.
///
/// For example:
/// ```dart
/// final registry = ModuleRegistryService<Object, AppConfig>();
/// await registry.ensureActive(settingsModule);
/// ```
///
/// {@category module}

abstract class ModuleRegistryService<T, Config extends Object> extends Service {
  /// Returns the DI-registered implementation of [ModuleRegistryService].
  ///
  /// Shorthand for [Service.get].
  factory ModuleRegistryService() {
    return Service.get<ModuleRegistryService<T, Config>>();
  }

  /// Internal constructor for subclasses.
  ModuleRegistryService.internal();

  @override
  String get group => '${super.group}.ModuleRegistryService';

  /// Returns the canonical instance for [module].
  ///
  /// If another instance with the same runtime type is already known by the
  /// registry, that existing instance must be returned.
  Module<T, Config> canonicalize(Module<T, Config> module);

  /// Returns the canonical module instance for [moduleType], if registered.
  Module<T, Config>? getByType(Type moduleType);

  /// All canonical module instances tracked by runtime type.
  Map<Type, Module<T, Config>> get modulesByType;

  /// Returns `true` when [module] is currently active.
  bool isActive(Module<T, Config> module);

  /// Currently active modules.
  Set<Module<T, Config>> get activeModules;

  /// Mounted module dependency graph.
  ///
  /// The key is a mounted module and the value is the set of modules it
  /// directly depends on (its direct imports).
  Map<Module<T, Config>, Set<Module<T, Config>>> get dependencyGraph;

  /// Pins [module] and all of its dependencies as mounted and active.
  ///
  /// Pinned modules remain required across [sync] calls until explicitly
  /// released with [ensureInactive]. Implementations must be idempotent and
  /// must operate on canonical module instances only.
  Future<void> ensureActive(Module<T, Config> module);

  /// Releases the pin held for [module].
  ///
  /// The module remains active when it is still required by [sync], another
  /// pinned module, or a shared dependency. Implementations must reconcile
  /// aliases to canonical instances first.
  Future<void> ensureInactive(Module<T, Config> module);

  /// Forcefully disposes [module], bypassing warm deactivation.
  ///
  /// This should be used only when a hard teardown is required.
  /// Implementations should call [Module.destroy] instead of only deactivating.
  Future<void> forceDispose(Module<T, Config> module);

  /// Computes the transitive dependency set for [modules].
  ///
  /// The returned set should contain [modules] and all imported modules needed
  /// to mount/activate them.
  Set<Module<T, Config>> resolveDependencies(
    Iterable<Module<T, Config>> modules,
  );

  /// Replaces the synchronized module set with [requiredModules].
  ///
  /// After completion, synchronized modules, pinned modules from [ensureActive],
  /// and all of their dependencies are active. Modules outside that combined
  /// graph are deactivated.
  Future<void> sync(Iterable<Module<T, Config>> requiredModules);

  /// Stops activation and releases mounted modules in reverse dependency order.
  ///
  /// Root scopes are released by their owning application's shutdown method.
  Future<void> shutdown();

  @override
  bool get singelton => true;
}
