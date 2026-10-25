import 'dart:async';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

/// Captures this device's make/model + app version and upserts a single row per
/// (business_id, device_id) into the cloud-only `devices` table for the
/// operator console's analytics (there is NO in-app device screen — see
/// migration `0129_devices.sql`). The server stamps `auth_user_id` on these
/// writes (migration `0200`), so a business row also routes this login's
/// Shopper pushes; a phone with no business uses the Shopper RPC methods.
///
/// The write is a DIRECT authenticated `supabase.upsert` — like
/// `AuthService._registerCloudSession` does for `sessions` — NOT the offline
/// sync queue. It is fire-and-forget and swallows every error: device analytics
/// must never block or break login/sync. A device that logs in offline records
/// on its next online moment (sign-in / app-open re-auth / reconnect), which is
/// the accepted trade-off of the cloud-only model.
class DeviceRegistryService {
  DeviceRegistryService(this._supabase, this._secure);

  final SupabaseClient _supabase;
  final SecureStorageService _secure;

  /// Make/model + app version are constant for the process lifetime, so read
  /// them once (a platform channel round-trip each) and reuse on every upsert.
  Map<String, Object?>? _cachedMeta;

  Future<Map<String, Object?>> _deviceMeta() async {
    if (_cachedMeta != null) return _cachedMeta!;
    final info = DeviceInfoPlugin();
    String? platform;
    String? manufacturer;
    String? model;
    String? deviceName;
    String? osVersion;
    bool? isPhysical;

    try {
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        platform = 'android';
        manufacturer = a.manufacturer;
        model = a.model;
        deviceName = a.name.isNotEmpty ? a.name : '${a.brand} ${a.model}';
        osVersion = 'Android ${a.version.release} (SDK ${a.version.sdkInt})';
        isPhysical = a.isPhysicalDevice;
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        platform = 'ios';
        manufacturer = 'Apple';
        model = i.utsname.machine; // hardware id, e.g. iPhone16,1
        deviceName = i.modelName; // marketing name, e.g. "iPhone 15 Pro"
        osVersion = 'iOS ${i.systemVersion}';
        isPhysical = i.isPhysicalDevice;
      } else {
        platform = Platform.operatingSystem;
      }
    } catch (e) {
      debugPrint('[DeviceRegistry] device info read failed: $e');
    }

    String? appVersion;
    try {
      final pkg = await PackageInfo.fromPlatform();
      appVersion = '${pkg.version}+${pkg.buildNumber}';
    } catch (e) {
      debugPrint('[DeviceRegistry] package info read failed: $e');
    }

    return _cachedMeta = {
      'platform': platform,
      'manufacturer': manufacturer,
      'model': model,
      'device_name': deviceName,
      'os_version': osVersion,
      'app_version': appVersion,
      'is_physical_device': isPhysical,
    };
  }

  /// Upserts this device's row for [businessId], recording the current user as
  /// the last user seen. The server stamps `last_seen_at` (BEFORE trigger) and
  /// keeps the insert-time `first_seen_at`, so neither is sent here. Never
  /// throws — a failure (offline, un-deployed table, RLS) is logged and dropped.
  Future<void> recordPresence({
    required String businessId,
    required String userId,
    String? userEmail,
    String? userName,
  }) async {
    try {
      final deviceId = await _secure.getOrCreateDeviceId();
      final meta = await _deviceMeta();
      await _supabase.from('devices').upsert(
        {
          'business_id': businessId,
          'device_id': deviceId,
          'last_user_id': userId,
          'last_user_email': userEmail,
          'last_user_name': userName,
          ...meta,
        },
        onConflict: 'business_id,device_id',
      );
    } catch (e) {
      debugPrint('[DeviceRegistry] recordPresence failed (non-fatal): $e');
    }
  }

  /// Fire-and-forget upsert of this device's FCM token onto its `devices` row,
  /// on the same `(business_id, device_id)` conflict target as [recordPresence]
  /// (migration `0159`). The server's `_devices_enforce_token_uniqueness`
  /// trigger nulls this token on every *other* row, so one token addresses
  /// exactly one device / most-recent login (invariant #5). Called on
  /// permission-grant, token refresh, and each sign-in where a token exists.
  ///
  /// Like [recordPresence], it is fire-and-forget and swallows every error:
  /// token registration must never block or break login/sync (#138).
  Future<void> recordPushToken({
    required String businessId,
    required String token,
    required bool permissionGranted,
  }) async {
    try {
      final deviceId = await _secure.getOrCreateDeviceId();
      await _supabase.from('devices').upsert(
        {
          'business_id': businessId,
          'device_id': deviceId,
          'fcm_token': token,
          'push_permission_granted': permissionGranted,
          'fcm_token_updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'business_id,device_id',
      );
    } catch (e) {
      debugPrint('[DeviceRegistry] recordPushToken failed (non-fatal): $e');
    }
  }

  /// Fire-and-forget registration of this phone's FCM token for a signed-in
  /// **Shopper with no business on this phone** (#476, migration `0200`). Goes
  /// through the `register_shopper_push_token` RPC — identity is the server's
  /// `auth.uid()`, never sent from here — onto a business-less `devices` row.
  /// A phone with a business uses [recordPushToken] instead: its business row
  /// is stamped with the same login, so it already receives Shopper pushes.
  /// Never throws.
  Future<void> recordShopperPushToken({
    required String token,
    required bool permissionGranted,
  }) async {
    try {
      final deviceId = await _secure.getOrCreateDeviceId();
      final meta = await _deviceMeta();
      await _supabase.rpc('register_shopper_push_token', params: {
        'p_device_id': deviceId,
        'p_fcm_token': token,
        'p_push_permission_granted': permissionGranted,
        for (final e in meta.entries) 'p_${e.key}': e.value,
      });
    } catch (e) {
      debugPrint('[DeviceRegistry] recordShopperPushToken failed (non-fatal): $e');
    }
  }

  /// Fire-and-forget clear of this phone's Shopper-only token on Shopper
  /// sign-out (`clear_shopper_push_token`, migration `0200`). Never throws.
  Future<void> clearShopperPushToken() async {
    try {
      final deviceId = await _secure.getOrCreateDeviceId();
      await _supabase.rpc('clear_shopper_push_token', params: {
        'p_device_id': deviceId,
      });
    } catch (e) {
      debugPrint('[DeviceRegistry] clearShopperPushToken failed (non-fatal): $e');
    }
  }

  /// Fire-and-forget clear of this device's FCM token on logout — nulls
  /// `fcm_token` via the same upsert path (a null token never trips the
  /// uniqueness trigger). The client MUST clear its own token on logout
  /// (invariant #2); the server trigger is the backstop, not a licence to skip
  /// cleanup. Leaves `push_permission_granted` untouched (OS permission
  /// survives a logout). Never throws.
  Future<void> clearPushToken({required String businessId}) async {
    try {
      final deviceId = await _secure.getOrCreateDeviceId();
      await _supabase.from('devices').upsert(
        {
          'business_id': businessId,
          'device_id': deviceId,
          'fcm_token': null,
          'fcm_token_updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'business_id,device_id',
      );
    } catch (e) {
      debugPrint('[DeviceRegistry] clearPushToken failed (non-fatal): $e');
    }
  }
}
