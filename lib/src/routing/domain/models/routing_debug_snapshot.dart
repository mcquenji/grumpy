/// The current phase of a routing operation exposed to diagnostics tools.
enum RoutingDebugPhase {
  /// The router is matching the requested URI to its route tree.
  matching,

  /// The route preview has been emitted.
  preview,

  /// Required modules are being activated or deactivated.
  activatingModules,

  /// Route middleware is being evaluated.
  runningMiddleware,

  /// The final route content is being built.
  buildingContent,

  /// Navigation completed and final content was emitted.
  completed,

  /// Middleware rejected the navigation.
  rejected,

  /// Route matching, activation, or content building failed unexpectedly.
  failed,
}

/// The diagnostic execution state of one routing step.
enum RoutingDebugStepState {
  /// The step has not started.
  pending,

  /// The step is currently executing.
  running,

  /// The step completed successfully.
  succeeded,

  /// The step failed or rejected navigation.
  failed,

  /// The step was not executed because an earlier step ended navigation.
  skipped,
}

/// Safe metadata for one route in the matched route lineage.
final class RouteDebugInfo {
  /// Creates route-lineage metadata.
  RouteDebugInfo({
    required this.routeType,
    required this.declaredPath,
    required this.moduleType,
    required this.leafType,
    required List<Type> middlewareTypes,
  }) : middlewareTypes = List.unmodifiable(middlewareTypes);

  /// The runtime type of the route declaration.
  final Type routeType;

  /// The declared route pattern segment, never a resolved path value.
  final String declaredPath;

  /// The module type introduced by this route, when applicable.
  final Type? moduleType;

  /// The leaf presentation type resolved at this route, when applicable.
  final Type? leafType;

  /// Middleware types declared directly on this route.
  final List<Type> middlewareTypes;
}

/// Safe execution metadata for one middleware in a routing operation.
final class RoutingMiddlewareDebugInfo {
  /// Creates middleware execution metadata.
  const RoutingMiddlewareDebugInfo({
    required this.middlewareType,
    required this.state,
  });

  /// The concrete middleware runtime type.
  final Type middlewareType;

  /// The latest execution state of the middleware.
  final RoutingDebugStepState state;
}

/// An immutable, metadata-only snapshot of one navigation request.
///
/// URI values, parameter values, errors, and stack traces are deliberately
/// excluded. This object is intended for debug tooling and not application
/// control flow.
final class RoutingDebugSnapshot {
  /// Creates routing diagnostics metadata.
  RoutingDebugSnapshot({
    required this.phase,
    required this.routePattern,
    required List<RouteDebugInfo> lineage,
    required List<Type> moduleTypes,
    required List<RoutingMiddlewareDebugInfo> middleware,
    required this.pathSegmentCount,
    required List<String> pathParameterNames,
    required List<String> queryParameterNames,
    required this.hasFragment,
    required this.elapsed,
    required this.coalescedNavigationCount,
    required this.failureType,
  }) : lineage = List.unmodifiable(lineage),
       moduleTypes = List.unmodifiable(moduleTypes),
       middleware = List.unmodifiable(middleware),
       pathParameterNames = List.unmodifiable(pathParameterNames),
       queryParameterNames = List.unmodifiable(queryParameterNames);

  /// The current or final navigation phase.
  final RoutingDebugPhase phase;

  /// The matched declared route pattern, without resolved values.
  final String? routePattern;

  /// The complete matched route lineage.
  final List<RouteDebugInfo> lineage;

  /// Module types required by the matched route.
  final List<Type> moduleTypes;

  /// Middleware execution metadata in evaluation order.
  final List<RoutingMiddlewareDebugInfo> middleware;

  /// The number of path segments in the requested URI.
  final int pathSegmentCount;

  /// Names of resolved path parameters, without their values.
  final List<String> pathParameterNames;

  /// Names of supplied query parameters, without their values.
  final List<String> queryParameterNames;

  /// Whether the requested URI contains a fragment.
  final bool hasFragment;

  /// Time elapsed since navigation diagnostics tracking began.
  final Duration elapsed;

  /// Additional callers coalesced into the same pending navigation.
  final int coalescedNavigationCount;

  /// The runtime type of the failure, without message or stack information.
  final Type? failureType;
}

/// Optional provider for metadata-only routing diagnostics.
///
/// Routing implementations may implement this interface without changing the
/// `RoutingService` contract. Implementations return `null` when assertions are
/// disabled or when [uri] is neither active nor the latest completed request.
abstract interface class RoutingDebugInfoProvider {
  /// Returns the current or latest debug snapshot for [uri].
  RoutingDebugSnapshot? debugSnapshotFor(Uri uri);
}
