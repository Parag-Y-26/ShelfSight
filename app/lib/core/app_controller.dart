import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'api_client.dart';
import 'cache.dart';
import 'configuration.dart';
import 'ai_credentials.dart';
import 'ai_provider_router.dart';
import 'autonomous_decision_engine.dart';
import 'laya_decision_service.dart';
import 'strings.dart';
export 'api_client.dart' show ApiClient, ApiFailure, friendlyError;

final appControllerProvider = ChangeNotifierProvider<AppController>(
  (ref) => AppController(),
);

class AppController extends ChangeNotifier {
  AppController({
    ApiClient? api,
    OwnerCache? cache,
    SupabaseClient? auth,
    DeviceSettingsStore? settingsStore,
    AiCredentials? aiCredentials,
    AiProviderRouter? aiRouter,
  }) : api = api ?? ApiClient(),
       cache = cache ?? OwnerCache(),
       settingsStore = settingsStore ?? DeviceSettingsStore(),
       aiCredentials = aiCredentials ?? AiCredentials(),
       _aiRouter = aiRouter,
       _injectedAiRouter = aiRouter != null,
       _auth = auth {
    this.api.onUnauthorized = _sessionExpired;
    unawaited(_bootstrap());
  }
  @visibleForTesting
  AppController.forTesting({
    required this.api,
    OwnerCache? cache,
    DeviceSettingsStore? settingsStore,
    AiCredentials? aiCredentials,
    AiProviderRouter? aiRouter,
    this.config = const {},
    this.store,
    this.stores = const [],
    this.floors = const [],
    this.shelves = const [],
    this.products = const [],
    this.items = const [],
    this.calibrations = const [],
    bool signedIn = true,
    this.supabaseConfigured = false,
  }) : cache = cache ?? OwnerCache(),
       settingsStore = settingsStore ?? DeviceSettingsStore(),
       aiCredentials = aiCredentials ?? AiCredentials(),
       _aiRouter = aiRouter,
       _injectedAiRouter = aiRouter != null,
       _authenticated = signedIn,
       initialized = true {
    AppStrings.setResourceOverlay(config['strings']);
  }

  final ApiClient api;
  final OwnerCache cache;
  final DeviceSettingsStore settingsStore;
  final AiCredentials aiCredentials;
  AiProviderRouter? _aiRouter;
  final bool _injectedAiRouter;
  AiProviderRouter get aiRouter =>
      _aiRouter ??= AiProviderRouter(config, credentials: aiCredentials);

  Future<AutonomousActionPlan> recommendations() async {
    final generation = _generation;
    final selected = store;
    if (selected == null) throw const ApiFailure('invalidInput');
    final id = selected['id'].toString();
    if (paired && !isOffline) {
      try {
        final response = await api.get('/stores/$id/events');
        if (!_current(generation) || store?['id'] != id) {
          throw const ApiFailure('sessionExpired');
        }
        await cache.recordEvents(
          id,
          _list(response is Map ? response['items'] : null),
        );
      } catch (_) {
        if (!_current(generation)) rethrow;
      }
    }
    final events = await cache.readEvents(
      id,
      limit: (config['ai']['limits']['max_decision_events'] as num).toInt(),
    );
    if (!_current(generation) || store?['id'] != id) {
      throw const ApiFailure('sessionExpired');
    }
    final engine = AutonomousDecisionEngine(
      LayaDecisionService(config),
      aiRouter,
    );
    final plan = await engine.decide(
      events,
      shelves
          .map(
            (shelf) => {
              ...shelf,
              'known_item_ids':
                  items
                      .where((item) => item['shelf_id'] == shelf['id'])
                      .map((item) => item['id'].toString())
                      .toList(),
              'settings': settingsOverrides(shelfId: shelf['id'].toString()),
            },
          )
          .toList(),
      store: {...selected, 'settings': settingsOverrides()},
      deviceDefaults: deviceOverrides,
      preferred: effectiveSettings()['active_ai_provider'].toString(),
    );
    if (!_current(generation) || store?['id'] != id) {
      throw const ApiFailure('sessionExpired');
    }
    return plan;
  }

  bool settingsSyncPending = false;
  Map<String, dynamic> _preferences = {};
  RuntimeConfiguration get runtimeConfiguration => RuntimeConfiguration(config);
  Map<String, dynamic> get deviceOverrides =>
      Map<String, dynamic>.from(_preferences['global'] as Map? ?? {});
  Map<String, dynamic> get globalSettings =>
      runtimeConfiguration.resolve(device: deviceOverrides);
  String _scopeKey(String id, {String? shelfId}) =>
      jsonEncode([_identityUid, api.serverIdentity, id, shelfId]);
  Map<String, dynamic> settingsOverrides({String? shelfId}) {
    if (store == null) return deviceOverrides;
    final target =
        shelfId == null
            ? store
            : shelves.where((s) => s['id'] == shelfId).firstOrNull;
    final saved =
        (_preferences['scopes'] as Map?)?[_scopeKey(
          store!['id'].toString(),
          shelfId: shelfId,
        )];
    return runtimeConfiguration.normalize(
      Map<String, dynamic>.from(
        saved is Map ? saved : target?['settings'] as Map? ?? {},
      ),
    );
  }

  Map<String, dynamic> effectiveSettings([
    Map<String, dynamic>? shelf,
  ]) => runtimeConfiguration.resolve(
    device: deviceOverrides,
    store: store == null ? null : {'settings': settingsOverrides()},
    shelf:
        shelf == null
            ? null
            : {'settings': settingsOverrides(shelfId: shelf['id'].toString())},
  );

  bool canUseRemoteMonitoring(Iterable<String> shelfIds) =>
      shelfIds.every((id) {
        final shelf = shelves.where((s) => s['id'] == id).firstOrNull;
        return shelf != null &&
            effectiveSettings(shelf)['execution_mode'] == 'remote_server';
      });

  Future<void> restoreSettings() async {
    final values = await settingsStore.read();
    runtimeConfiguration.validate(
      Map<String, dynamic>.from(values['global'] as Map? ?? {}),
    );
    _preferences = values;
    notifyListeners();
  }

  Future<void> saveSettings(
    Map<String, dynamic> values, {
    bool global = false,
    String? shelfId,
  }) async {
    final validated = runtimeConfiguration.validate(values);
    final generation = _generation;
    final selectedId = store?['id']?.toString();
    final next = Map<String, dynamic>.from(_preferences);
    if (global || selectedId == null) {
      next['global'] = validated;
    } else {
      final scopes = Map<String, dynamic>.from(next['scopes'] as Map? ?? {});
      scopes[_scopeKey(selectedId, shelfId: shelfId)] = validated;
      next['scopes'] = scopes;
    }
    await settingsStore.write(next);
    if (!_current(generation)) return;
    _preferences = next;
    settingsSyncPending = !global && selectedId != null;
    notifyListeners();
    if (!global && selectedId != null && paired && !isOffline) {
      try {
        await api.patch(
          shelfId == null ? '/stores/$selectedId' : '/shelves/$shelfId',
          {'settings': validated},
        );
        if (!_current(generation)) return;
        settingsSyncPending = false;
      } catch (_) {
        // Locally saved overrides travel with subsequent monitoring requests.
        // The Settings screen explains that server synchronization is pending.
      }
      if (_current(generation)) notifyListeners();
    }
  }

  Map<String, dynamic> get monitoringSettings => {
    'settings': globalSettings,
    'store_settings': store == null ? <String, dynamic>{} : settingsOverrides(),
    'shelf_settings': {
      for (final shelf in shelves)
        shelf['id'].toString(): settingsOverrides(
          shelfId: shelf['id'].toString(),
        ),
    },
  };
  SupabaseClient? _auth;
  StreamSubscription<AuthState>? _authSubscription;
  Future<void>? _googleInitialization;
  Timer? _expiryTimer;
  String? _identityUid;
  int _generation = 0;
  int _selectionGeneration = 0;
  int get identityGeneration => _generation;
  bool _current(int generation) => generation == _generation;
  bool _authenticated = false;
  bool initialized = false;
  bool supabaseConfigured = false;
  bool passwordRecoveryPending = false;
  bool busy = false;
  bool isOffline = false;
  bool monitoringActive = false;
  String? error;
  String? bootstrapError;
  DateTime? cacheTimestamp;
  String? localeTag;
  Map<String, dynamic> _defaultConfig = {};
  Map<String, dynamic> config = {};
  Map<String, dynamic>? store;
  List<Map<String, dynamic>> stores = [];
  List<Map<String, dynamic>> floors = [];
  List<Map<String, dynamic>> shelves = [];
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> items = [];
  List<Map<String, dynamic>> calibrations = [];
  bool get authenticated => _authenticated;
  bool get paired => api.paired;
  List<String> get supportedLocaleTags {
    final configured = config['locales'];
    return {
      'en',
      if (configured is List)
        ...configured.whereType<String>().where(
          (s) => RegExp(r'^en(?:_[A-Z]{2})?$').hasMatch(s),
        ),
    }.toList();
  }

  String get effectiveLocaleTag {
    if (supportedLocaleTags.contains(localeTag)) return localeTag!;
    final country = PlatformDispatcher.instance.locale.countryCode;
    final device = country == null ? 'en' : 'en_$country';
    return supportedLocaleTags.contains(device) ? device : 'en';
  }

  void _setConfig(Map<String, dynamic> value) {
    if (!_injectedAiRouter) {
      _aiRouter?.dispose();
      _aiRouter = null;
    }
    config = {
      ..._defaultConfig,
      ...value,
      for (final key in [
        'settings',
        'setting_rules',
        'legacy_settings',
        'platform_defaults',
      ])
        if (!value.containsKey(key) && _defaultConfig.containsKey(key))
          key: _defaultConfig[key],
    };
    AppStrings.setResourceOverlay(config['strings']);
  }

  Future<void> setLocaleTag(String value) async {
    if (!supportedLocaleTags.contains(value)) {
      throw const ApiFailure('invalidInput');
    }
    localeTag = value;
    await cache.put('locale', value);
    notifyListeners();
  }

  String get displayName {
    final user = _auth?.auth.currentUser;
    final metadataName =
        user?.userMetadata?['display_name'] ??
        user?.userMetadata?['full_name'] ??
        user?.userMetadata?['name'];
    if (metadataName is String && metadataName.trim().isNotEmpty) {
      return metadataName.trim();
    }
    return user?.email?.split('@').first ?? '';
  }

  Future<void> _bootstrap() async {
    try {
      _defaultConfig = Map<String, dynamic>.from(
        jsonDecode(await rootBundle.loadString('assets/defaults.json')) as Map,
      );
      _setConfig(Map<String, dynamic>.from(_defaultConfig));
      await restoreSettings();
      const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
      const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
      supabaseConfigured = supabaseUrl.isNotEmpty && publishableKey.isNotEmpty;
      if (supabaseConfigured) {
        await Supabase.initialize(
          url: supabaseUrl,
          publishableKey: publishableKey,
        );
        _auth ??= Supabase.instance.client;
        _authSubscription = _auth!.auth.onAuthStateChange.listen((state) {
          if (state.event == AuthChangeEvent.passwordRecovery) {
            passwordRecoveryPending = true;
            unawaited(_userChanged(null));
            return;
          }
          final user = state.session?.user;
          if (user?.id != _identityUid) unawaited(_userChanged(user));
        });
        await _userChanged(_auth!.auth.currentUser);
      }
    } catch (_) {
      bootstrapError = 'configurationFailed';
      supabaseConfigured = false;
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> _userChanged(User? user) async {
    if (passwordRecoveryPending && user != null) {
      await _userChanged(null);
      return;
    }
    final generation = ++_generation;
    _expiryTimer?.cancel();
    _identityUid = user?.id;
    localeTag = null;
    _setConfig(Map<String, dynamic>.from(_defaultConfig));
    _authenticated = user != null;
    _clearBusinessState();
    if (user == null) {
      await api.clear();
      await cache.close();
    } else {
      try {
        await api.restore(user.id);
        if (!_current(generation)) return;
        if (!api.paired && api.hasApiAddress && !api.localMode) {
          final token = _auth!.auth.currentSession?.accessToken;
          if (!_current(generation)) return;
          if (token == null) throw const ApiFailure('sessionExpired');
          await api.connectCloud(idToken: token, uid: user.id);
          if (!_current(generation)) return;
        }
        if (api.paired) {
          _armExpiry();
          await cache.open(user.id, server: api.serverIdentity);
          if (!_current(generation)) return;
          await _restoreCache();
          if (!_current(generation)) return;
          try {
            await refresh();
          } catch (_) {
            /* cached state remains visible */
          }
        }
      } catch (e) {
        if (!_current(generation)) return;
        // A corrupt local cache or unavailable keystore must not impersonate a
        // successful API connection. The user can establish a fresh session.
        await api.clear();
        await cache.close();
        _clearBusinessState();
        error = friendlyError(e);
      }
    }
    notifyListeners();
  }

  static const _authRedirect = 'com.shelfsight.app://auth-callback';

  Future<void> login(String email, String password) async {
    await _auth!.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<bool> register(String name, String email, String password) async {
    final result = await _auth!.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'display_name': name.trim()},
      emailRedirectTo: _authRedirect,
    );
    return result.session != null;
  }

  Future<void> resetPassword(String email) => _auth!.auth.resetPasswordForEmail(
    email.trim(),
    redirectTo: _authRedirect,
  );

  Future<void> updatePassword(String password) async {
    await _auth!.auth.updateUser(UserAttributes(password: password));
    passwordRecoveryPending = false;
    await _userChanged(_auth!.auth.currentUser);
  }

  Future<void> googleLogin() async {
    if (kIsWeb) {
      throw const ApiFailure('googleUnsupported');
    }
    final signIn = GoogleSignIn.instance;
    const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
    _googleInitialization ??= signIn.initialize(
      serverClientId: webClientId.isEmpty ? null : webClientId,
    );
    await _googleInitialization;
    if (!signIn.supportsAuthenticate()) {
      throw const ApiFailure('googleUnsupported');
    }
    final account = await signIn.authenticate();
    final token = account.authentication.idToken;
    if (token == null) throw const ApiFailure('googleUnavailable');
    await _auth!.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: token,
    );
  }

  Future<void> reconnectCloud({String? address}) async {
    if (address != null) await api.setApiAddress(address);
    await saveSettings({
      ...deviceOverrides,
      'execution_mode': 'remote_server',
    }, global: true);
    await _userChanged(_auth?.auth.currentUser);
  }

  Future<void> pair({
    required String address,
    required String fingerprint,
    required String secret,
    required String deviceName,
  }) async {
    final generation = ++_generation;
    final user = _auth?.auth.currentUser;
    final idToken = _auth?.auth.currentSession?.accessToken;
    if (user == null || idToken == null) {
      throw const ApiFailure('sessionExpired');
    }
    await api.pair(
      address: address,
      fingerprint: fingerprint,
      secret: secret,
      idToken: idToken,
      uid: user.id,
      deviceName: deviceName,
    );
    if (!_current(generation)) return;
    await saveSettings({
      ...deviceOverrides,
      'execution_mode': 'remote_server',
    }, global: true);
    await _userChanged(user);
  }

  static List<Map<String, dynamic>> _list(dynamic value) =>
      value is List
          ? value
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : [];
  Future<void> loadStores() async {
    final generation = _generation;
    final result = await api.get('/stores');
    if (!_current(generation)) return;
    stores = _list(result is Map ? result['items'] : null);
    await cache.put('stores', stores);
    notifyListeners();
  }

  Future<void> selectStore(String id) async {
    final generation = _generation;
    final selection = ++_selectionGeneration;
    final data = await api.get('/stores/$id/snapshot');
    if (!_current(generation) || selection != _selectionGeneration) return;
    if (data is! Map || data['store'] is! Map) {
      throw const ApiFailure('invalidResponse');
    }
    _applySnapshot(Map<String, dynamic>.from(data));
    await cache.put('snapshot', data);
    cacheTimestamp = DateTime.now().toUtc();
    isOffline = false;
    notifyListeners();
  }

  void _applySnapshot(Map<String, dynamic> data) {
    store =
        data['store'] is Map
            ? Map<String, dynamic>.from(data['store'] as Map)
            : null;
    floors = _list(data['floors']);
    shelves = _list(data['shelves']);
    products = _list(data['products']);
    items = _list(data['items']);
    calibrations = _list(data['calibrations']);
  }

  Future<void> _restoreCache() async {
    final generation = _generation;
    final cachedConfig = await cache.read('config');
    if (!_current(generation)) return;
    if (cachedConfig?['value'] is Map) {
      _setConfig(Map<String, dynamic>.from(cachedConfig!['value'] as Map));
    }
    final preference = await cache.read('locale');
    if (!_current(generation)) return;
    if (preference?['value'] is String) {
      localeTag = preference!['value'] as String;
    }
    final cachedStores = await cache.read('stores');
    if (!_current(generation)) return;
    stores = _list(cachedStores?['value']);
    final snapshot = await cache.read('snapshot');
    if (!_current(generation)) return;
    if (snapshot?['value'] is Map) {
      _applySnapshot(Map<String, dynamic>.from(snapshot!['value'] as Map));
      cacheTimestamp = DateTime.tryParse(snapshot['updated_at'].toString());
      isOffline = true;
    }
  }

  Future<void> refresh() async {
    final generation = _generation;
    if (!paired) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final data = await api.get('/config');
      if (!_current(generation)) return;
      if (data is Map) {
        _setConfig(Map<String, dynamic>.from(data));
        await cache.put('config', config);
      }
      final id = store?['id']?.toString();
      await loadStores();
      if (!_current(generation)) return;
      final selected =
          stores.where((s) => s['id'].toString() == id).firstOrNull;
      if (selected != null || stores.isNotEmpty) {
        await selectStore((selected ?? stores.first)['id'].toString());
      } else {
        _clearBusinessState(clearStores: false);
      }
      if (!_current(generation)) return;
      isOffline = false;
    } catch (e) {
      if (!_current(generation)) return;
      error = friendlyError(e);
      isOffline = true;
      monitoringActive = false;
      rethrow;
    } finally {
      if (_current(generation)) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<Map<String, dynamic>?> readCached(String key) => cache.read(key);
  Future<void> cacheValue(String key, dynamic value) => cache.put(key, value);
  Future<void> deleteSelectedStore() async {
    final id = store?['id'];
    if (id == null) return;
    await api.delete('/stores/$id');
    await cache.erase();
    _clearBusinessState();
    await refresh();
  }

  Future<void> disconnect() async {
    ++_generation;
    _clearBusinessState();
    _expiryTimer?.cancel();
    try {
      await api.revoke();
    } catch (_) {
      await api.clear();
    }
    await cache.erase();
    await cache.close();
    _clearBusinessState();
    localeTag = null;
    _setConfig(Map<String, dynamic>.from(_defaultConfig));
    notifyListeners();
  }

  void markMonitoringActive(bool active) {
    monitoringActive = active;
    notifyListeners();
  }

  void _sessionExpired() {
    ++_generation;
    _expiryTimer?.cancel();
    error = 'sessionExpired';
    _clearBusinessState();
    notifyListeners();
  }

  void _armExpiry() {
    _expiryTimer?.cancel();
    final expires = api.expiresAt;
    if (expires == null) return;
    final remaining = expires.difference(DateTime.now().toUtc());
    _expiryTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      unawaited(api.clear().catchError((Object _) {}));
      _sessionExpired();
    });
  }

  void _clearBusinessState({bool clearStores = true}) {
    ++_selectionGeneration;
    store = null;
    if (clearStores) stores = [];
    floors = [];
    shelves = [];
    products = [];
    items = [];
    calibrations = [];
    monitoringActive = false;
    cacheTimestamp = null;
  }

  Future<void> logout() async {
    ++_generation;
    _authenticated = false;
    _clearBusinessState();
    _expiryTimer?.cancel();
    try {
      await api.revoke();
    } catch (_) {
      await api.clear();
    }
    await cache.erase();
    await cache.close();
    _clearBusinessState();
    localeTag = null;
    _setConfig(Map<String, dynamic>.from(_defaultConfig));
    await _auth?.auth.signOut();
    _authenticated = false;
    try {
      if (_googleInitialization != null) await GoogleSignIn.instance.signOut();
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    ++_generation;
    _aiRouter?.dispose();
    _expiryTimer?.cancel();
    _authSubscription?.cancel();
    unawaited(cache.close());
    super.dispose();
  }
}
