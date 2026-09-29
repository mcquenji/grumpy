/// The derived state currently retained by `UseRepoMixin` for diagnostics.
///
/// Consumers can use this to distinguish loading, data, error, and disposed
/// dependency graphs without inspecting any application payloads.
enum UseRepoDebugState {
  /// Dependencies are still resolving or at least one dependency is loading.
  loading,

  /// The latest dependency evaluation produced data.
  data,

  /// The latest dependency evaluation produced an error.
  error,

  /// The dependency graph has been permanently disposed.
  disposed,
}

/// The event that most recently invalidated or changed a dependency graph.
///
/// These values describe causality using framework metadata only. They never
/// identify dependency keys or emitted values.
enum UseRepoDebugTriggerKind {
  /// Initial dependency discovery started the evaluation.
  initialization,

  /// A caller explicitly requested a dependency refresh.
  explicitRefresh,

  /// A repository emitted a new state.
  repoChange,

  /// A repository was resolved and added to the watched graph.
  repoResolved,

  /// An external invalidation stream emitted a signal.
  externalSignal,

  /// An external invalidation stream emitted an error.
  externalError,

  /// A payload stream emitted a value.
  payloadValue,

  /// A payload stream emitted an error.
  payloadError,

  /// A payload stream closed and scheduled recreation.
  payloadClosed,
}

/// The safe metadata retained for the latest dependency trigger.
///
/// [sourceType] is the runtime type of the repository, stream key, or source
/// involved. The source value itself is deliberately not retained.
final class UseRepoDebugTriggerInfo {
  /// Creates trigger metadata for [kind] and its optional [sourceType].
  const UseRepoDebugTriggerInfo(this.kind, {this.sourceType});

  /// The category of event that caused the latest dependency change.
  final UseRepoDebugTriggerKind kind;

  /// The safe runtime type associated with the trigger, when one exists.
  final Type? sourceType;
}

/// The state of one watched dependency in a debug snapshot.
enum UseRepoDependencyDebugState {
  /// The dependency is being resolved or is waiting for its first value.
  pending,

  /// The dependency currently reports loading.
  loading,

  /// The dependency currently has usable data.
  data,

  /// The dependency currently reports an error.
  error,

  /// The payload stream closed and will be recreated when evaluated again.
  closed,
}

/// Safe metadata shared by all dependency entries.
///
/// Implementations expose types and states only. No dependency keys, payloads,
/// errors, or stack traces are stored in these objects.
sealed class UseRepoDependencyDebugInfo {
  /// Creates dependency metadata with [state] and an optional [errorType].
  const UseRepoDependencyDebugInfo({required this.state, this.errorType});

  /// The current state of the dependency.
  final UseRepoDependencyDebugState state;

  /// The runtime type of the current error, without its message or stack.
  final Type? errorType;
}

/// Safe metadata for a watched repository.
final class UseRepoRepoDependencyDebugInfo extends UseRepoDependencyDebugInfo {
  /// Creates repository dependency metadata.
  const UseRepoRepoDependencyDebugInfo({
    required this.repoType,
    required super.state,
    super.errorType,
  });

  /// The concrete runtime type of the watched repository.
  final Type repoType;
}

/// Safe metadata for an external invalidation stream.
final class UseRepoExternalDependencyDebugInfo
    extends UseRepoDependencyDebugInfo {
  /// Creates external-stream dependency metadata.
  const UseRepoExternalDependencyDebugInfo({
    required this.keyType,
    required this.valueType,
    required this.streamType,
    required super.state,
    super.errorType,
  });

  /// The runtime type of the stable dependency key, not its value.
  final Type keyType;

  /// The declared type returned by the synchronous snapshot callback.
  final Type valueType;

  /// The runtime type of the invalidation stream.
  final Type streamType;
}

/// Safe metadata for a payload-bearing stream.
final class UseRepoPayloadDependencyDebugInfo
    extends UseRepoDependencyDebugInfo {
  /// Creates payload-stream dependency metadata.
  const UseRepoPayloadDependencyDebugInfo({
    required this.keyType,
    required this.sourceKeyType,
    required this.payloadType,
    required this.streamType,
    required super.state,
    super.errorType,
  });

  /// The runtime type of the stable dependency key, not its value.
  final Type keyType;

  /// The runtime type of the stream source key, not its value.
  final Type sourceKeyType;

  /// The declared payload type emitted by the stream.
  final Type payloadType;

  /// The concrete runtime type of the payload stream.
  final Type streamType;
}

/// An immutable, metadata-only snapshot of a `UseRepoMixin` dependency graph.
///
/// This is intended for diagnostics integrations such as Flutter's Widget
/// Inspector. It is available only when assertions are enabled and must not be
/// used for application behavior.
final class UseRepoDebugSnapshot {
  /// Creates a dependency graph snapshot.
  UseRepoDebugSnapshot({
    required this.state,
    required this.latestTrigger,
    required List<UseRepoDependencyDebugInfo> dependencies,
    required List<Type> pendingRepoTypes,
    required this.subscriptionCount,
    required this.stateChangeVersion,
    required this.activeRebuildCount,
    required this.totalRebuildCount,
    required this.supersededRebuildCount,
  }) : dependencies = List.unmodifiable(dependencies),
       pendingRepoTypes = List.unmodifiable(pendingRepoTypes);

  /// The latest derived state of the dependency graph.
  final UseRepoDebugState state;

  /// The latest event that changed or invalidated the graph.
  final UseRepoDebugTriggerInfo? latestTrigger;

  /// Safe metadata for all resolved watched dependencies.
  final List<UseRepoDependencyDebugInfo> dependencies;

  /// Repository types that are currently being resolved.
  final List<Type> pendingRepoTypes;

  /// The number of active subscriptions owned by the mixin.
  final int subscriptionCount;

  /// The latest generation used by the latest-wins state engine.
  final int stateChangeVersion;

  /// The number of dependency rebuilds currently executing.
  final int activeRebuildCount;

  /// The total number of dependency rebuilds started.
  final int totalRebuildCount;

  /// The number of completed rebuilds discarded by a newer generation.
  final int supersededRebuildCount;
}
