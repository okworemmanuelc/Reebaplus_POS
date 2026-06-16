import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/core/utils/logger.dart';

class PrinterService {
  static const _lastMacKey = 'last_printer_mac';

  PrinterService();

  Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) {
      // iOS / macOS use CoreBluetooth, not runtime permissions — there is no
      // dialog to request here. The native Bluetooth-access prompt fires the
      // first time the plugin creates its CBCentralManager (i.e. on the first
      // call below). What matters before we scan is that Bluetooth has actually
      // powered on; _ensureBleReady waits for that. A false result means
      // Bluetooth is off or the app was denied access.
      return _ensureBleReady();
    }
    try {
      // Printing to an already-paired thermal printer needs BLUETOOTH_CONNECT
      // on Android 12+ (API 31+). BLUETOOTH_SCAN is only for discovering NEW
      // devices, so it's requested but treated as best-effort. We deliberately
      // do NOT request location: we never run a classic Bluetooth discovery (we
      // read the OS bonded list and connect), and gating on location got denied
      // on POS devices and silently blocked every print. On Android < 12 these
      // map to install-time permissions and report granted automatically.
      final statuses = await [
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ].request();

      final connectGranted =
          statuses[Permission.bluetoothConnect]?.isGranted ?? false;
      if (!connectGranted) {
        AppLogger.error('BLUETOOTH_CONNECT not granted: $statuses');
      }
      return connectGranted;
    } catch (e) {
      AppLogger.error('Printer permission request failed: $e');
      return false;
    }
  }

  /// iOS/macOS only: the plugin lazily creates its `CBCentralManager` on the
  /// first method call, and its state starts as `.unknown`, settling to
  /// `.poweredOn` asynchronously. If we scan (`getPairedDevices`) before it
  /// settles, the native scan sees `.unknown`, never starts, and returns an
  /// empty list — the #1 reason iOS shows "no printers" on first open. Polling
  /// `bluetoothEnabled` both creates the manager and reports its real state, so
  /// we wait (≤ ~3.6s) for it to power on. No-op concept on Android.
  Future<bool> _ensureBleReady() async {
    for (var i = 0; i < 12; i++) {
      try {
        if (await PrintBluetoothThermal.bluetoothEnabled) return true;
      } catch (_) {
        // Adapter not ready yet — keep polling until the timeout.
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    AppLogger.error('Bluetooth not ready (off or unauthorized) after warm-up');
    return false;
  }

  Future<bool> get isConnected async {
    return await PrintBluetoothThermal.connectionStatus;
  }

  Future<List<BluetoothInfo>> getPairedDevices() async {
    // On Android this reads the OS bonded (paired) list. On iOS/macOS the
    // plugin runs a ~5s BLE scan instead and returns *nearby* devices — which
    // silently finds nothing unless CoreBluetooth has powered on first, so warm
    // it up before scanning. (No-op on Android.)
    if (!Platform.isAndroid) {
      await _ensureBleReady();
    }
    return await PrintBluetoothThermal.pairedBluetooths;
  }

  Future<bool> connect(String macAddress) async {
    try {
      AppLogger.info('Connecting to printer: $macAddress');
      final ok = await PrintBluetoothThermal.connect(
        macPrinterAddress: macAddress,
      );
      if (!ok) return false;
      // iOS/macOS (CoreBluetooth): connect() returns true the moment the link
      // is up, but the plugin only *starts* GATT service + characteristic
      // discovery at that point. The writable characteristic isn't ready for a
      // brief window, so an immediate writeBytes finds no characteristic and
      // fails. Give discovery time to land before reporting success. Android
      // (Bluetooth Classic SPP) has no separate discovery step.
      if (!Platform.isAndroid) {
        await Future.delayed(const Duration(milliseconds: 1500));
      }
      return true;
    } catch (e) {
      AppLogger.error('Error connecting to printer: $e');
      return false;
    }
  }

  /// Persists the MAC of the printer the user last successfully connected to
  /// via [PrinterPicker]. Read by [autoConnect] on next launch.
  Future<void> saveLastConnectedMac(String mac) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastMacKey, mac);
  }

  Future<bool> autoConnect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMac = prefs.getString(_lastMacKey);
      if (savedMac != null && savedMac.isNotEmpty) {
        final paired = await getPairedDevices();
        final match = paired.where((d) => d.macAdress == savedMac).toList();
        if (match.isNotEmpty) {
          AppLogger.info(
            'Auto-connecting to saved printer ${match.first.name}',
          );
          if (await connect(savedMac)) return true;
        }
      }
      return await _autoConnectByName();
    } catch (e) {
      AppLogger.error('Auto-connect failed: $e');
      return false;
    }
  }

  /// Fallback for first-run / no-saved-MAC state. Matches by substring on the
  /// device name — brittle, but preserved for users who haven't picked a
  /// printer yet.
  Future<bool> _autoConnectByName() async {
    final paired = await getPairedDevices();
    final targetPrinters = paired.where((d) {
      final name = d.name.toLowerCase();
      return name.contains('bluetooth_mobile_printer') ||
          name.contains('mp583') ||
          name.contains('thermal') ||
          name.contains('printer');
    }).toList();

    if (targetPrinters.isNotEmpty) {
      final targetPrinter = targetPrinters.first;
      AppLogger.info('Auto-connecting to ${targetPrinter.name}');
      return await connect(targetPrinter.macAdress);
    }
    return false;
  }

  Future<bool> printBytes(List<int> bytes) async {
    try {
      if (!await isConnected) {
        final connected = await autoConnect();
        if (!connected) return false;
      }
      return await PrintBluetoothThermal.writeBytes(bytes);
    } catch (e) {
      AppLogger.error('Printing failed: $e');
      return false;
    }
  }

  /// Writes bytes without attempting auto-connect. Use this after the user
  /// has manually selected a device through the [PrinterPicker].
  Future<bool> printBytesDirectly(List<int> bytes) async {
    try {
      if (!await isConnected) return false;
      return await PrintBluetoothThermal.writeBytes(bytes);
    } catch (e) {
      AppLogger.error('Direct printing failed: $e');
      return false;
    }
  }
}
