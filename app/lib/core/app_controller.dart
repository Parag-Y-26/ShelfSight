import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'api_client.dart';
import 'cache.dart';
import 'strings.dart';
export 'api_client.dart' show ApiClient, ApiFailure, friendlyError;

final appControllerProvider = ChangeNotifierProvider<AppController>(
  (ref) => AppController(),
);

class AppController extends ChangeNotifier {
  AppController({ApiClient? api, OwnerCache? cache, FirebaseAuth? auth})
    : api = api ?? ApiClient(),
      cache = cache ?? OwnerCache(),
      _auth = auth {
    this.api.onUnauthorized = _sessionExpired;
    unawaited(_bootstrap());
  }
  @visibleForTesting
  AppController.forTesting({
    required this.api,
    OwnerCache? cache,
    this.config = const {},
    this.store,
    this.stores = const [],
    this.floors = const [],
    this.shelves = const [],
    this.products = const [],
    this.items = const [],
    this.calibrations = const [],
    bool signedIn = true,
  }) : cache = cache ?? OwnerCache(),
       _authenticated = signedIn,
       initialized = true,
       firebaseConfigured = false {
    AppStrings.setResourceOverlay(config['strings']);
  }

  final ApiClient api;
  final OwnerCache cache;
  FirebaseAuth? _auth;
  StreamSubscription<User?>? _authSubscription;
  Future<void>? _googleInitialization;
  Timer? _expiryTimer;
  String? _identityUid;
  int _generation = 0;
  int get identityGeneration => _generation;
  bool _current(int generation) => generation == _generation;
  bool _authenticated = false;
  bool initialized = false;
  bool firebaseConfigured = false;
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
    config = value;
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

  String get displayName =>
      _auth?.currentUser?.displayName?.trim().isNotEmpty == true
          ? _auth!.currentUser!.displayName!
          : (_auth?.currentUser?.email?.split('@').first ?? '');

  Future<void> _bootstrap() async {
    try {
      _defaultConfig = Map<String, dynamic>.from(
        jsonDecode(await rootBundle.loadString('assets/defaults.json')) as Map,
      );
      _setConfig(Map<String, dynamic>.from(_defaultConfig));
      const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
      const appId = String.fromEnvironment('FIREBASE_APP_ID');
      const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
      const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
      firebaseConfigured = [
        apiKey,
        appId,
        projectId,
        senderId,
      ].every((v) => v.isNotEmpty);
      if (firebaseConfigured) {
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp(
            options: const FirebaseOptions(
              apiKey: apiKey,
              appId: appId,
              projectId: projectId,
              messagingSenderId: senderId,
              authDomain: String.fromEnvironment('FIREBASE_AUTH_DOMAIN'),
              storageBucket: String.fromEnvironment('FIREBASE_STORAGE_BUCKET'),
            ),
          );
        }
        _auth ??= FirebaseAuth.instance;
        await _userChanged(_auth!.currentUser);
        _authSubscription = _auth!.authStateChanges().listen((user) {
          // Initial identity was restored above; only handle actual changes.
          if (user?.uid != _identityUid) unawaited(_userChanged(user));
        });
      }
    } catch (_) {
      bootstrapError = 'configurationFailed';
      firebaseConfigured = false;
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> _userChanged(User? user) async {
    final generation = ++_generation;
    _expiryTimer?.cancel();
    _identityUid = user?.uid;
    localeTag = null;
    _setConfig(Map<String, dynamic>.from(_defaultConfig));
    _authenticated = user != null;
    _clearBusinessState();
    if (user == null) {
      await api.clear();
      await cache.close();
    } else {
      try {
        await api.restore(user.uid);
        if (!_current(generation)) return;
        if (api.paired) {
          _armExpiry();
          await cache.open(user.uid, server: api.serverIdentity);
          if (!_current(generation)) return;
          await _restoreCache();
          if (!_current(generation)) return;
          try {
            await refresh();
          } catch (_) {
            /* cached state remains visible */
          }
        }
      } catch (_) {
        if (!_current(generation)) return;
        // A corrupt local cache or unavailable keystore must not impersonate a
        // successful pairing. The user can establish a new session explicitly.
        await api.clear();
        await cache.close();
        _clearBusinessState();
        error = 'localStorageUnavailable';
      }
    }
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    await _auth!.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> register(String name, String email, String password) async {
    final result = await _auth!.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await result.user?.updateDisplayName(name.trim());
    notifyListeners();
  }

  Future<void> resetPassword(String email) =>
      _auth!.sendPasswordResetEmail(email: email.trim());
  Future<void> googleLogin() async {
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
    await _auth!.signInWithCredential(
      GoogleAuthProvider.credential(idToken: token),
    );
  }

  Future<void> pair({
    required String address,
    required String fingerprint,
    required String secret,
    required String deviceName,
  }) async {
    final generation = ++_generation;
    final user = _auth?.currentUser;
    final idToken = await user?.getIdToken();
    if (!_current(generation)) return;
    if (user == null || idToken == null) {
      throw const ApiFailure('sessionExpired');
    }
    await api.pair(
      address: address,
      fingerprint: fingerprint,
      secret: secret,
      idToken: idToken,
      uid: user.uid,
      deviceName: deviceName,
    );
    if (!_current(generation)) return;
    _armExpiry();
    await cache.open(user.uid, server: api.serverIdentity);
    if (!_current(generation)) return;
    _clearBusinessState();
    await refresh();
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
    final data = await api.get('/stores/$id/snapshot');
    if (!_current(generation)) return;
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
    await _auth?.signOut();
    _authenticated = false;
    try {
      if (_googleInitialization != null) await GoogleSignIn.instance.signOut();
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    ++_generation;
    _expiryTimer?.cancel();
    _authSubscription?.cancel();
    unawaited(cache.close());
    super.dispose();
  }
}
