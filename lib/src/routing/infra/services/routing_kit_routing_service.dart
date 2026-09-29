import 'dart:async';

import 'package:routingkit/routingkit.dart';
import 'package:grumpy/grumpy.dart';
import 'package:rxdart/rxdart.dart';

final class _RoutingMiddlewareDebugTracker {
  _RoutingMiddlewareDebugTracker(this.middlewareType);

  final Type middlewareType;
  var state = RoutingDebugStepState.pending;
}

final class _RoutingDebugTracker {
  _RoutingDebugTracker(Uri uri)
    : requestKey = _routingDebugRequestKey(uri),
      pathSegmentCount = uri.pathSegments.length,
      queryParameterNames = uri.queryParametersAll.keys.toList()..sort(),
      hasFragment = uri.fragment.isNotEmpty,
      stopwatch = Stopwatch()..start();

  final (int, int) requestKey;
  final int pathSegmentCount;
  final List<String> queryParameterNames;
  final bool hasFragment;
  final Stopwatch stopwatch;
  var phase = RoutingDebugPhase.matching;
  String? routePattern;
  List<RouteDebugInfo> lineage = const [];
  List<Type> moduleTypes = const [];
  List<_RoutingMiddlewareDebugTracker> middleware = const [];
  List<String> pathParameterNames = const [];
  Type? failureType;
  var coalescedNavigationCount = 0;

  RoutingDebugSnapshot snapshot() => RoutingDebugSnapshot(
    phase: phase,
    routePattern: routePattern,
    lineage: lineage,
    moduleTypes: moduleTypes,
    middleware: [
      for (final entry in middleware)
        RoutingMiddlewareDebugInfo(
          middlewareType: entry.middlewareType,
          state: entry.state,
        ),
    ],
    pathSegmentCount: pathSegmentCount,
    pathParameterNames: pathParameterNames,
    queryParameterNames: queryParameterNames,
    hasFragment: hasFragment,
    elapsed: stopwatch.elapsed,
    coalescedNavigationCount: coalescedNavigationCount,
    failureType: failureType,
  );
}

(int, int) _routingDebugRequestKey(Uri uri) =>
    (uri.hashCode, uri.toString().length);

/// [RoutingService] impementation that uses RoutingKit for route parsing and matching.
///
/// {@category routing}

class RoutingKitRoutingService<T, Config extends Object>
    extends RoutingService<T, Config>
    with LifecycleMixin
    implements RoutingDebugInfoProvider {
  /// [RoutingService] impementation that uses RoutingKit for route parsing and matching.
  RoutingKitRoutingService(
    this.rootModule, {
    ModuleRegistryService<T, Config>? moduleRegistry,
    this.caseSensitive = false,
  }) : moduleRegistry = moduleRegistry ?? ModuleRegistryService<T, Config>(),
       super.internal();

  /// Centralized module lifecycle manager.
  final ModuleRegistryService<T, Config> moduleRegistry;

  Future<void> _currentNavigation = Future.value();

  RouteContext? _context;

  final Map<Uri, (Future<bool>, LeafRoute<T, Config>, RouteContext)>
  _pendingNavigations = {};

  /// The root module of the application.
  final RootModule<T, Config> rootModule;

  final List<void Function(Route<T, Config>)> _listeners = [];

  /// The underlying RoutingKit router instance.
  late final Router<Route<T, Config>> _kit;

  /// Whether route matching should be case-sensitive.
  final bool caseSensitive;
  final Map<String, Set<Module<T, Config>>> _moduleCache = {};
  final Map<Route<T, Config>, List<Route<T, Config>>> _routeLineages = {};

  final _viewChangeController = BehaviorSubject<ViewChangedEvent<T, Config>>();
  ViewChangedEvent<T, Config>? _activeViewChange;

  final Map<(int, int), _RoutingDebugTracker> _activeRoutingDebugTrackers = {};
  _RoutingDebugTracker? _latestRoutingDebugTracker;

  @override
  RoutingDebugSnapshot? debugSnapshotFor(Uri uri) {
    RoutingDebugSnapshot? snapshot;
    assert(() {
      final tracker =
          _activeRoutingDebugTrackers[_routingDebugRequestKey(uri)] ??
          (_latestRoutingDebugTracker?.requestKey ==
                  _routingDebugRequestKey(uri)
              ? _latestRoutingDebugTracker
              : null);
      snapshot = tracker?.snapshot();
      return true;
    }());
    return snapshot;
  }

  bool _startRoutingDebug(Uri uri) {
    _activeRoutingDebugTrackers[_routingDebugRequestKey(uri)] =
        _RoutingDebugTracker(uri);
    return true;
  }

  bool _coalesceRoutingDebug(Uri uri) {
    _activeRoutingDebugTrackers[_routingDebugRequestKey(uri)]
        ?.coalescedNavigationCount++;
    return true;
  }

  bool _configureRoutingDebug(
    Uri uri,
    List<Route<T, Config>> lineage,
    RouteContext context,
    Set<Module<T, Config>> modules,
  ) {
    final tracker = _activeRoutingDebugTrackers[_routingDebugRequestKey(uri)];
    if (tracker == null) return true;

    tracker
      ..routePattern = _declaredRoutePattern(lineage)
      ..lineage = [
        for (final route in lineage)
          RouteDebugInfo(
            routeType: route.runtimeType,
            declaredPath: route.path,
            moduleType: route is ModuleRoute<T, Config>
                ? route.module.runtimeType
                : null,
            leafType: route is LeafRoute<T, Config>
                ? route.view.runtimeType
                : null,
            middlewareTypes: [
              for (final item in route.middleware) item.runtimeType,
            ],
          ),
      ]
      ..moduleTypes = [for (final module in modules) module.runtimeType]
      ..middleware = [
        for (final route in lineage)
          for (final item in route.middleware)
            _RoutingMiddlewareDebugTracker(item.runtimeType),
      ]
      ..pathParameterNames = (context.pathParams.keys.toList()..sort());
    return true;
  }

  String _declaredRoutePattern(List<Route<T, Config>> lineage) {
    final segments = <String>[];
    for (final route in lineage) {
      final path = route.path;
      if (path.isEmpty || path == '/') continue;
      segments.addAll(path.split('/').where((segment) => segment.isNotEmpty));
    }
    return segments.isEmpty ? '/' : '/${segments.join('/')}';
  }

  bool _setRoutingDebugPhase(Uri uri, RoutingDebugPhase phase) {
    final tracker = _activeRoutingDebugTrackers[_routingDebugRequestKey(uri)];
    if (tracker != null) tracker.phase = phase;
    return true;
  }

  bool _setMiddlewareDebugState(
    Uri uri,
    int index,
    RoutingDebugStepState state,
  ) {
    final tracker = _activeRoutingDebugTrackers[_routingDebugRequestKey(uri)];
    if (tracker != null && index < tracker.middleware.length) {
      tracker.middleware[index].state = state;
    }
    return true;
  }

  bool _finishRemainingMiddlewareDebugSteps(Uri uri, int startIndex) {
    final tracker = _activeRoutingDebugTrackers[_routingDebugRequestKey(uri)];
    if (tracker == null) return true;
    for (var i = startIndex; i < tracker.middleware.length; i++) {
      tracker.middleware[i].state = RoutingDebugStepState.skipped;
    }
    return true;
  }

  bool _failRoutingDebug(Uri uri, RoutingDebugPhase phase, Type failureType) {
    final tracker = _activeRoutingDebugTrackers[_routingDebugRequestKey(uri)];
    if (tracker != null) {
      tracker
        ..phase = phase
        ..failureType = failureType;
    }
    return true;
  }

  bool _completeRoutingDebug(Uri uri) {
    final tracker = _activeRoutingDebugTrackers.remove(
      _routingDebugRequestKey(uri),
    );
    if (tracker != null) {
      tracker.stopwatch.stop();
      _latestRoutingDebugTracker = tracker;
    }
    return true;
  }

  @override
  RouteContext? get currentContext => _context;

  @override
  FutureOr<void> destroy() async {
    await super.destroy();
    _listeners.clear();
    _routeLineages.clear();
    _pendingNavigations.clear();
    assert(() {
      _activeRoutingDebugTrackers.clear();
      _latestRoutingDebugTracker = null;
      return true;
    }());
    if (!_viewChangeController.isClosed) {
      await _viewChangeController.close();
    }
  }

  @override
  bool isActive(String path, {bool exact = true, bool ignoreParams = false}) {
    final context = _context;
    if (context == null) return false;

    final currentUri = context.uri;
    final targetUri = Uri.parse(path);

    final current = ignoreParams ? currentUri.path : currentUri.toString();
    final target = ignoreParams ? targetUri.path : targetUri.toString();

    return exact ? current == target : _isPartialActiveMatch(current, target);
  }

  bool _isPartialActiveMatch(String current, String target) {
    if (current == target) return true;

    final boundaryTarget = target.endsWith('/') ? target : '$target/';

    return current.startsWith(boundaryTarget) ||
        current.startsWith('$target?') ||
        current.startsWith('$target#');
  }

  @override
  Route<T, Config> get root => rootModule.root;

  @override
  void addListener(void Function(Route<T, Config> route) listener) =>
      _listeners.add(listener);

  @override
  void removeListener(void Function(Route<T, Config> route) listener) =>
      _listeners.remove(listener);

  @override
  FutureOr<void> activate() {}

  @override
  FutureOr<void> deactivate() async {
    _context = null;
    _activeViewChange = null;
    _pendingNavigations.clear();
    assert(() {
      _activeRoutingDebugTrackers.clear();
      _latestRoutingDebugTracker = null;
      return true;
    }());
    await moduleRegistry.sync(<Module<T, Config>>[]);
  }

  @override
  FutureOr<void> dependenciesChanged() {}

  @override
  FutureOr<void> initialize() {
    _kit = createRouter(caseSensitive: caseSensitive);
    _routeLineages.clear();
    assert(() {
      _activeRoutingDebugTrackers.clear();
      _latestRoutingDebugTracker = null;
      return true;
    }());

    _addRoute(root, '/');

    log('Registered routes:\n${root.toTree()}');
  }

  void _addRoute(
    Route<T, Config> route,
    String parentPath, [
    List<Route<T, Config>> ancestors = const [],
  ]) {
    final fullPath = '$parentPath/${route.path}'.replaceAll('//', '/');
    final lineage = List<Route<T, Config>>.unmodifiable([...ancestors, route]);

    _routeLineages[route] = lineage;
    _kit.add(null, fullPath, route);

    if (route is ModuleRoute<T, Config>) {
      for (final child in route.module.routes) {
        _addRoute(child, fullPath, lineage);
      }
    }

    for (final child in route.children) {
      _addRoute(child, fullPath, lineage);
    }
  }

  ({LeafRoute<T, Config> leaf, List<Route<T, Config>> lineage})
  _resolveLeafRoute(Route<T, Config> matchedRoute, String path) {
    if (matchedRoute is LeafRoute<T, Config>) {
      return (
        leaf: matchedRoute,
        lineage: _routeLineages[matchedRoute] ?? [matchedRoute],
      );
    }

    if (matchedRoute is! ModuleRoute<T, Config>) {
      throw ArgumentError.value(path, 'path', 'Resolved route is not a leaf!');
    }

    final rootLeaf =
        matchedRoute.root ??
        matchedRoute.module.routes.root ??
        (throw ArgumentError.value(
          path,
          'path',
          'Resolved ModuleRoute does not have a root LeafRoute defined!',
        ));

    final lineage = <Route<T, Config>>[
      ...(_routeLineages[matchedRoute] ?? [matchedRoute]),
      rootLeaf,
    ];

    return (leaf: rootLeaf, lineage: lineage);
  }

  List<Middleware<T, Config>> _collectMiddleware(
    List<Route<T, Config>> lineage,
  ) => [for (final route in lineage) ...route.middleware];

  /// Returns a list of modules that need to be activated for the given [path].
  ///
  /// This method uses a cache to optimize repeated lookups for the same path.
  Set<Module<T, Config>> getDependencies(String path) {
    if (path.isEmpty) return {};

    if (path == '/') return {};

    if (_moduleCache.containsKey(path)) {
      return _moduleCache[path]!;
    }

    final modules = _collectModulesForPath(path);

    _moduleCache[path] = modules;

    return modules;
  }

  Set<Module<T, Config>> _collectModulesForPath(String path) {
    final modules = <Module<T, Config>>{};
    final pathSegments = _normalizePath(path);

    for (final child in root.children) {
      _collectMatchingModules(child, pathSegments, 0, modules);
    }

    return modules;
  }

  void _collectMatchingModules(
    Route<T, Config> route,
    List<String> pathSegments,
    int startIndex,
    Set<Module<T, Config>> modules,
  ) {
    final routeSegments = _normalizePath(route.path);
    if (!_matchesAt(pathSegments, startIndex, routeSegments)) return;

    final nextIndex = startIndex + routeSegments.length;

    if (route is ModuleRoute<T, Config>) {
      modules.add(route.module);
      for (final moduleChild in route.module.routes) {
        _collectMatchingModules(moduleChild, pathSegments, nextIndex, modules);
      }
    }

    for (final child in route.children) {
      _collectMatchingModules(child, pathSegments, nextIndex, modules);
    }
  }

  bool _matchesAt(
    List<String> fullPathSegments,
    int startIndex,
    List<String> routeSegments,
  ) {
    if (startIndex + routeSegments.length > fullPathSegments.length) {
      return false;
    }

    for (var i = 0; i < routeSegments.length; i++) {
      if (fullPathSegments[startIndex + i] != routeSegments[i]) {
        return false;
      }
    }

    return true;
  }

  List<String> _normalizePath(String path) {
    if (path.isEmpty || path == '/') return const [];
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse(normalized).pathSegments;
  }

  RouteContext _createContext(Uri uri, Map<String, String> pathParams) {
    return RouteContext(
      fullPath: uri.toString(),
      pathParams: pathParams,
      queryParams: uri.queryParameters,
      queryParamsAll: uri.queryParametersAll,
      fragment: uri.fragment,
    );
  }

  @override
  Future<void> navigate(
    String path, {
    bool skipPreview = false,
    void Function(T, bool) callback = RoutingService.noopCallback,
  }) async {
    void emitToStream(T view, bool isPreview) {
      log('View changed: isPreview=$isPreview, view=$view for path: $path');

      final event = (
        view: view,
        isPreview: isPreview,
        context: currentContext,
        config: RootModule.getConfig<Config>(),
      );

      if (!isPreview) {
        _activeViewChange = event;
      }

      _viewChangeController.add(event);
    }

    void handler(T view, bool isPreview) {
      emitToStream(view, isPreview);
      callback(view, isPreview);
    }

    final uri = Uri.parse(path);

    if (_pendingNavigations.containsKey(uri)) {
      assert(_coalesceRoutingDebug(uri));
      log('Navigation to $path is already in progress, forwarding callback.');

      final (future, leaf, context) = _pendingNavigations[uri]!;

      if (!skipPreview) {
        callback(leaf.view.preview(context), true);
      }

      log('Waiting for pending navigation to $path to complete.');

      final success = await future;

      if (!success) {
        log(
          'Pending navigation to $path failed, not invoking content callback.',
        );
        return;
      }

      log('Pending navigation to $path completed, invoking content callback.');

      callback(await leaf.view.content(context), false);

      return;
    }

    if (uri == currentContext?.uri) {
      log(
        'Already at path: $path, skipping navigation and emitting current view.',
      );

      final current = _activeViewChange;
      if (current != null) {
        callback(current.view, current.isPreview);
      }

      return;
    }

    assert(_startRoutingDebug(uri));

    try {
      final cleanPath = uri.path;

      // find the route
      final match = _kit.find(null, cleanPath);

      if (match == null) {
        throw ArgumentError.value(
          path,
          'path',
          'No route found for the given path!',
        );
      }

      final matchedRoute = match.data;

      if (matchedRoute is ModuleRoute<T, Config>) {
        log(
          'Detected module route at path: $path, looking for root leaf in module ${matchedRoute.module}...',
        );

        final rootLeaf = matchedRoute.root ?? matchedRoute.module.routes.root;
        log('Found module root: $rootLeaf');
      }

      final (:leaf, :lineage) = _resolveLeafRoute(matchedRoute, path);
      final context = _createContext(uri, match.params);
      final dependencies = getDependencies(uri.path);
      assert(_configureRoutingDebug(uri, lineage, context, dependencies));

      final future = _navigate(context, leaf, lineage, skipPreview, handler);

      _pendingNavigations[uri] = (future, leaf, context);
      _currentNavigation = future;
      await future;
    } catch (e, s) {
      assert(_failRoutingDebug(uri, RoutingDebugPhase.failed, e.runtimeType));
      log('Navigation to $path failed with error', e, s);
      rethrow;
    } finally {
      _pendingNavigations.remove(uri);
      assert(_completeRoutingDebug(uri));
    }
  }

  Future<bool> _navigate(
    RouteContext initialContext,
    LeafRoute<T, Config> leaf,
    List<Route<T, Config>> lineage,
    bool skipPreview,
    void Function(T, bool) callback,
  ) async {
    var context = initialContext;
    final debugUri = initialContext.uri;
    final previousContext = _context;
    final cleanPath = context.uri.path;
    final middleware = _collectMiddleware(lineage);

    log('Navigating to $cleanPath with context: $context');

    if (!skipPreview) {
      assert(_setRoutingDebugPhase(debugUri, RoutingDebugPhase.preview));
      callback(leaf.view.preview(context), true);
    }

    _context = context;

    // activate required modules
    final dependencies = getDependencies(cleanPath);

    assert(
      _setRoutingDebugPhase(debugUri, RoutingDebugPhase.activatingModules),
    );
    await moduleRegistry.sync(dependencies);

    // run middlewares (if any)
    try {
      assert(
        _setRoutingDebugPhase(debugUri, RoutingDebugPhase.runningMiddleware),
      );
      for (var i = 0; i < middleware.length; i++) {
        final currentMiddleware = middleware[i];
        assert(
          _setMiddlewareDebugState(debugUri, i, RoutingDebugStepState.running),
        );
        log(
          'Executing middleware ${i + 1}/${middleware.length}: ${currentMiddleware.logTag}',
        );
        context = await currentMiddleware(context);
        _context = context;
        assert(
          _setMiddlewareDebugState(
            debugUri,
            i,
            RoutingDebugStepState.succeeded,
          ),
        );
      }
      log(
        'All ${middleware.length} middlewares executed successfully for $cleanPath',
      );
    } catch (e, s) {
      assert(() {
        final tracker =
            _activeRoutingDebugTrackers[_routingDebugRequestKey(debugUri)];
        final failedIndex = tracker?.middleware.indexWhere(
          (item) => item.state == RoutingDebugStepState.running,
        );
        if (failedIndex != null && failedIndex >= 0) {
          _setMiddlewareDebugState(
            debugUri,
            failedIndex,
            RoutingDebugStepState.failed,
          );
          _finishRemainingMiddlewareDebugSteps(debugUri, failedIndex + 1);
        }
        return _failRoutingDebug(
          debugUri,
          RoutingDebugPhase.rejected,
          e.runtimeType,
        );
      }());
      _context = previousContext;
      log(
        'A middleware threw an exception during navigation to $cleanPath',
        e,
        s,
      );
      return false;
    }

    _context = context;

    assert(_setRoutingDebugPhase(debugUri, RoutingDebugPhase.buildingContent));
    final content = await leaf.view.content(context);
    assert(_setRoutingDebugPhase(debugUri, RoutingDebugPhase.completed));
    callback(content, false);

    log('Activated route at $cleanPath');

    // notify listeners
    for (final listener in _listeners) {
      listener(leaf);
    }

    return true;
  }

  @override
  String get logTag => 'RoutingKitRoutingService';

  @override
  StreamSubscription<ViewChangedEvent<T, Config>> onViewChanged(
    void Function(ViewChangedEvent<T, Config>) callback,
  ) => _viewChangeController.stream.listen(callback);

  @override
  Stream<ViewChangedEvent<T, Config>> get viewStream =>
      _viewChangeController.stream;

  @override
  Future<void> get currentNavigation => _currentNavigation;
}
