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
/// migration `0129_devices.sql`).
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
}
