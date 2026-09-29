import 'package:get_it/get_it.dart' hide Disposable;
import 'package:grumpy/grumpy.dart';
import 'package:test/test.dart';

class Settings {}

class OwnedService extends Service with LifecycleMixin {
  OwnedService(this.events, {this.fail = false});
  final List<String> events;
  final bool fail;
  @override
  bool get singelton => true;
  @override
  String get logTag => 'OwnedService';
  @override
  Future<void> initialize() async {
    events.add('initialize');
  }

  @override
  Future<void> activate() async {
    events.add('activate');
    if (fail) throw StateError('startup');
  }

  @override
  Future<void> deactivate() async {
    events.add('deactivate');
  }

  @override
  Future<void> dependenciesChanged() async {}
  @override
  Future<void> destroy() async {
    events.add('destroy');
    await super.destroy();
  }
}

class Feature extends Module<Object, Settings> {
  Feature(this.events, {this.fail = false});
  final List<String> events;
  final bool fail;
  @override
  String get logTag => 'Feature';
  @override
  List<Route<Object, Settings>> get routes => [];
  @override
  void bindServices(Bind<Service, Settings> bind) =>
      bind<OwnedService>((_, _) => OwnedService(events, fail: fail));
}

class Application extends RootModule<Object, Settings> {
  Application(this.feature) : super(Settings());
  final Feature feature;
  @override
  String get logTag => 'Application';
  @override
  List<Module<Object, Settings>> get imports => [feature];
  @override
  List<Route<Object, Settings>> get routes => [];
}

void main() {
  tearDown(() => GetIt.I.reset());
  test(
    'shutdown owns root registrations and preserves unrelated scopes',
    () async {
      GetIt.I.registerSingleton<String>('host');
      final events = <String>[];
      final app = Application(Feature(events));
      await app.bootstrap();
      GetIt.I.pushNewScope(scopeName: 'foreign');
      GetIt.I.registerSingleton<int>(42);
      await app.shutdown();
      await app.shutdown();
      expect(events, ['initialize', 'activate', 'deactivate', 'destroy']);
      expect(GetIt.I<String>(), 'host');
      expect(GetIt.I<int>(), 42);
      expect(GetIt.I.isRegistered<Settings>(), false);
      expect(GetIt.I.isRegistered<OwnedService>(), false);
    },
  );
  test('failed startup releases partially activated resources', () async {
    final events = <String>[];
    final app = Application(Feature(events, fail: true));
    await expectLater(app.bootstrap(), throwsStateError);
    expect(events, ['initialize', 'activate', 'deactivate', 'destroy']);
    expect(GetIt.I.currentScopeName, 'baseScope');
    final next = Application(Feature([]));
    await next.bootstrap();
    await next.shutdown();
  });
}
