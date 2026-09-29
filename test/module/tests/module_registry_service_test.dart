// irrelevant for testing purposes
// ignore_for_file: missing_override_of_must_be_overridden, must_call_super, unused_element_parameter
import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:grumpy/grumpy.dart';
import 'package:grumpy/src/module/infra/services/canonical_module_registry_service.dart';
import 'package:test/test.dart';
import '../harness/module_registry_service_test_harness.dart';

void main() {
  group('CanonicalModuleRegistryService', () {
    test('canonicalize keeps one instance per runtime type', () {
      final events = <String>[];
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final first = FeatureModule('first', events: events);
      final second = FeatureModule('second', events: events);

      final canonicalFirst = registry.canonicalize(first);
      final canonicalSecond = registry.canonicalize(second);

      expect(canonicalFirst, same(first));
      expect(canonicalSecond, same(first));
      expect(registry.modulesByType.length, 1);
      expect(registry.getByType(FeatureModule), same(first));
      expect(registry.dependencyGraph[first], isEmpty);
    });

    test('canonicalize recursively canonicalizes imported modules', () {
      final events = <String>[];
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final depA = DependencyModule('dep-a', events: events);
      final depB = DependencyModule('dep-b', events: events);
      final featureA = FeatureModule('feature-a', events: events, deps: [depA]);
      final featureB = FeatureModule('feature-b', events: events, deps: [depB]);

      final canonicalFeature = registry.canonicalize(featureA);
      registry.canonicalize(featureB);

      final canonicalDep = registry.getByType(DependencyModule);
      expect(canonicalFeature, same(featureA));
      expect(canonicalDep, same(depA));
      expect(registry.modulesByType.length, 2);
      expect(registry.dependencyGraph[featureA], equals({depA}));
    });

    test(
      'sync activates in dependency order and deactivates in reverse order',
      () async {
        final events = <String>[];
        final registry = CanonicalModuleRegistryService<int, Cfg>();
        final dep = DependencyModule('dep', events: events);
        final feature = FeatureModule('feature', events: events, deps: [dep]);

        await registry.sync([feature]);
        await registry.sync(const <Module<int, Cfg>>[]);

        expect(
          events,
          equals([
            'initialize:dep',
            'activate:dep',
            'initialize:feature',
            'activate:feature',
            'deactivate:feature',
            'deactivate:dep',
          ]),
        );
      },
    );

    test('sync is idempotent for already-active module set', () async {
      final events = <String>[];
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final dep = DependencyModule('dep', events: events);
      final feature = FeatureModule('feature', events: events, deps: [dep]);

      await registry.sync([feature]);
      await registry.sync([feature]);

      expect(dep.initializeCalls, 1);
      expect(dep.activateCalls, 1);
      expect(feature.initializeCalls, 1);
      expect(feature.activateCalls, 1);
      expect(dep.deactivateCalls, 0);
      expect(feature.deactivateCalls, 0);
    });

    test(
      'ensureActive and ensureInactive preserve shared dependencies',
      () async {
        final events = <String>[];
        final registry = CanonicalModuleRegistryService<int, Cfg>();
        final shared = SharedModule('shared', events: events);
        final featureA = FeatureModule(
          'feature-a',
          events: events,
          deps: [shared],
        );
        final settings = SettingsModule(
          'settings',
          events: events,
          deps: [shared],
        );

        await registry.ensureActive(featureA);
        await registry.ensureActive(settings);
        await registry.ensureInactive(featureA);

        expect(registry.isActive(settings), isTrue);
        expect(registry.isActive(shared), isTrue);
        expect(registry.isActive(featureA), isFalse);
        expect(shared.deactivateCalls, 0);

        await registry.ensureInactive(settings);

        expect(registry.activeModules, isEmpty);
        expect(shared.deactivateCalls, 1);
      },
    );

    test('sync preserves modules pinned by ensureActive', () async {
      final events = <String>[];
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final appDependency = DependencyModule('app-dependency', events: events);
      final app = FeatureModule('app', events: events, deps: [appDependency]);
      final dashboard = SettingsModule('dashboard', events: events);

      await registry.ensureActive(app);
      await registry.sync([dashboard]);

      expect(
        registry.activeModules,
        containsAll([appDependency, app, dashboard]),
      );

      await registry.sync(const <Module<int, Cfg>>[]);

      expect(registry.activeModules, equals({appDependency, app}));
      expect(app.deactivateCalls, 0);
      expect(appDependency.deactivateCalls, 0);
      expect(dashboard.deactivateCalls, 1);

      await registry.ensureInactive(app);

      expect(registry.activeModules, isEmpty);
      expect(app.deactivateCalls, 1);
      expect(appDependency.deactivateCalls, 1);
    });

    test('isActive resolves aliases via canonical instance', () async {
      final events = <String>[];
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final first = FeatureModule('first', events: events);
      final second = FeatureModule('second', events: events);

      await registry.ensureActive(first);

      expect(registry.isActive(second), isTrue);
      expect(first.activateCalls, 1);
      expect(second.activateCalls, 0);
    });

    test('resolveDependencies returns transitive canonicalized modules', () {
      final events = <String>[];
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final leafA = LeafModule('leaf-a', events: events);
      final leafB = LeafModule('leaf-b', events: events);
      final depA = DependencyModule('dep-a', events: events, deps: [leafA]);
      final depB = DependencyModule('dep-b', events: events, deps: [leafB]);
      final featureA = FeatureModule('feature-a', events: events, deps: [depA]);
      final featureB = FeatureModule('feature-b', events: events, deps: [depB]);

      final resolved = registry.resolveDependencies([featureA, featureB]);

      expect(resolved.length, 3);
      expect(resolved, contains(featureA));
      expect(resolved, contains(depA));
      expect(resolved, contains(leafA));
      expect(registry.getByType(FeatureModule), same(featureA));
      expect(registry.getByType(DependencyModule), same(depA));
      expect(registry.getByType(LeafModule), same(leafA));
    });

    test('sync throws for circular imports', () async {
      final events = <String>[];
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final cycleA = CycleAModule('a', events: events);
      final cycleB = CycleBModule('b', events: events);
      cycleA.setDeps([cycleB]);
      cycleB.setDeps([cycleA]);

      expect(() => registry.sync([cycleA]), throwsA(isA<StateError>()));
    });

    test(
      'registry recovers after failed sync and can process new work',
      () async {
        final events = <String>[];
        final registry = CanonicalModuleRegistryService<int, Cfg>();
        final cycleA = CycleAModule('a', events: events);
        final cycleB = CycleBModule('b', events: events);
        cycleA.setDeps([cycleB]);
        cycleB.setDeps([cycleA]);

        expect(() => registry.sync([cycleA]), throwsA(isA<StateError>()));

        final feature = FeatureModule('feature', events: events);
        await registry.sync([feature]);

        expect(registry.activeModules, equals({feature}));
        expect(feature.initializeCalls, 1);
        expect(feature.activateCalls, 1);
      },
    );

    test(
      'queued ensureActive calls are serialized and keep final union',
      () async {
        final events = <String>[];
        final registry = CanonicalModuleRegistryService<int, Cfg>();
        final shared = SharedModule(
          'shared',
          events: events,
          activateDelay: const Duration(milliseconds: 30),
        );
        final feature = FeatureModule(
          'feature',
          events: events,
          deps: [shared],
        );
        final settings = SettingsModule(
          'settings',
          events: events,
          deps: [shared],
        );

        await Future.wait([
          registry.ensureActive(feature),
          registry.ensureActive(settings),
        ]);

        expect(registry.activeModules.length, 3);
        expect(registry.activeModules, contains(shared));
        expect(registry.activeModules, contains(feature));
        expect(registry.activeModules, contains(settings));
        expect(shared.initializeCalls, 1);
        expect(shared.activateCalls, 1);
      },
    );

    test('free deactivates all active modules', () async {
      final events = <String>[];
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final dep = DependencyModule('dep', events: events);
      final feature = FeatureModule('feature', events: events, deps: [dep]);

      await registry.sync([feature]);
      await registry.destroy();

      expect(registry.activeModules, isEmpty);
      expect(feature.deactivateCalls, 1);
      expect(dep.deactivateCalls, 1);
    });

    test(
      'sync adopts already-mounted modules without reinitializing DI scope',
      () async {
        final di = GetIt.instance;
        await di.reset(dispose: false);

        final registry = CanonicalModuleRegistryService<int, Cfg>();
        final module = ScopedMountedModule();

        await module.initialize();
        await module.activate();

        expect(di.hasScope(module.runtimeType.toString()), isTrue);
        expect(module.initializeCalls, 1);
        expect(module.activateCalls, 1);

        await registry.sync([module]);

        expect(module.initializeCalls, 1);
        expect(module.activateCalls, 1);
        expect(registry.isActive(module), isTrue);

        await registry.sync(const <Module<int, Cfg>>[]);
        expect(module.deactivateCalls, 1);
      },
    );

    test('sync activates externally mounted but inactive module', () async {
      final di = GetIt.instance;
      await di.reset(dispose: false);

      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final module = ScopedMountedModule();

      await module.initialize();
      expect(module.initializeCalls, 1);
      expect(module.activateCalls, 0);

      await registry.sync([module]);

      expect(module.initializeCalls, 1);
      expect(module.activateCalls, 1);
      expect(registry.isActive(module), isTrue);
    });

    test('forceDispose deactivates then disposes the module', () async {
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final module = ScopedMountedModule();

      await registry.sync([module]);
      expect(module.activateCalls, 1);

      await registry.forceDispose(module);

      expect(module.freeCalls, 1);
      expect(module.deactivateCalls, 1);
      expect(registry.isActive(module), isFalse);
      expect(registry.getByType(ScopedMountedModule), isNull);
    });

    test('sync warm-deactivates and reactivates without cold start', () async {
      await GetIt.instance.reset(dispose: false);
      final registry = CanonicalModuleRegistryService<int, Cfg>();
      final module = ScopedMountedModule();

      await registry.sync([module]);
      await registry.sync(const <Module<int, Cfg>>[]);
      await registry.sync([module]);

      expect(module.initializeCalls, 1);
      expect(module.activateCalls, 2);
      expect(module.deactivateCalls, 1);
      expect(module.freeCalls, 0);
      expect(registry.isActive(module), isTrue);
    });
  });
}
