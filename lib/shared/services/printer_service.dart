import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/core/utils/logger.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/features/pos/services/sample_receipt.dart';
import 'package:reebaplus_pos/shared/services/usb_printer_channel.dart';

/// Receipt printing. Two transports (#614): a USB printer plugged into this
/// device (Android tablets) is used first; the saved Bluetooth printer is the
/// backup. Printers are keyed by an id — the Bluetooth MAC, or
/// `usb:<vendorId>:<productId>[:<serial>]` — and paper size / print style are
/// saved per id.
class PrinterService {
  static const _lastMacKey = 'last_printer_mac';
  // Pre-per-printer (#116) single paper size for the whole device. Read once
  // by [_migrateLegacyPaperSize], then deleted.
  static const _legacyPaperSizeKey = 'printer_paper_size';
  // Per-printer paper size: `printer_paper_size:<mac>`.
  static const _paperSizeKeyPrefix = 'printer_paper_size:';
  static const _printStyleKeyPrefix = 'printer_print_style:';
  // Per-printer receipt size (#676): `full` | `compact`.
  static const _receiptSizeKeyPrefix = 'printer_receipt_size:';

  // Settle window for Android Bluetooth SPP link before commands can be processed.
  static const _androidConnectSettle = Duration(milliseconds: 1000);
  // Firmware wake-up and buffer-clear delay after ESC @ before receipt data arrives.
  static const _wakeGap = Duration(milliseconds: 500);
  // ESC @ hardware initialize command to reset line buffer and clear leftover state.
  static const _escInit = [0x1B, 0x40];

  PrinterService({
    Future<bool> Function(List<int> bytes)? writeBytes,
    Future<bool> Function(String mac)? connectToPrinter,
    Future<void> Function(Duration duration)? wait,
    bool? isAndroid,
    UsbPrinterChannel? usb,
  })  : _usb = usb ?? UsbPrinterChannel(),
        _writeBytes = writeBytes ?? PrintBluetoothThermal.writeBytes,
        _connectToPrinter = connectToPrinter ??
            ((mac) => PrintBluetoothThermal.connect(macPrinterAddress: mac)),
        _wait = wait ?? ((d) => Future<void>.delayed(d)),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  final Future<bool> Function(List<int> bytes) _writeBytes;
  final Future<bool> Function(String mac) _connectToPrinter;
  final Future<void> Function(Duration duration) _wait;
  final bool _isAndroid;
  final UsbPrinterChannel _usb;

  /// USB printers whose permission prompt was already shown this app run, so
  /// one print never stacks several system prompts after a "Deny".
  final Set<String> _usbPermissionAsked = {};

  /// Whether this device can use USB printers at all (Android only).
  bool get supportsUsb => _usb.isSupported;

  /// True when the app may print: Bluetooth access was granted, or a USB
  /// printer is plugged in and allowed (USB needs no Bluetooth access).
  Future<bool> requestPermissions() async {
    if (await _requestBluetoothPermissions()) return true;
    return await attachedUsbPrinter() != null;
  }

  Future<bool> _requestBluetoothPermissions() async {
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
      final ok = await _connectToPrinter(macAddress);
      if (!ok) return false;
      // iOS/macOS (CoreBluetooth): connect() returns true the moment the link
      // is up, but the plugin only *starts* GATT service + characteristic
      // discovery at that point. The writable characteristic isn't ready for a
      // brief window, so an immediate writeBytes finds no characteristic and
      // fails. Give discovery time to land before reporting success.
      // Android (Bluetooth Classic SPP): give the newly opened RFCOMM link time
      // to settle before sending commands.
      if (_isAndroid) {
        await _wait(_androidConnectSettle);
      } else {
        await _wait(const Duration(milliseconds: 1500));
      }
      // Every successful connect (auto or picked) records which printer is in
      // use, so its paper size can be looked up before the receipt is built.
      await saveLastConnectedMac(macAddress);
      return true;
    } catch (e) {
      AppLogger.error('Error connecting to printer: $e');
      return false;
    }
  }

  /// Persists the MAC of the printer the app last connected to successfully.
  /// Read by [autoConnect] on next launch and by [lastConnectedMac].
  Future<void> saveLastConnectedMac(String mac) async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyPaperSize(prefs);
    await prefs.setString(_lastMacKey, mac);
  }

  /// The printer the app last connected to, or null if it never has.
  Future<String?> lastConnectedMac() async {
    final prefs = await SharedPreferences.getInstance();
    final mac = prefs.getString(_lastMacKey);
    return (mac == null || mac.isEmpty) ? null : mac;
  }

  /// The paper width saved for the printer at [mac], or null when this
  /// printer has never been set up. Printers cannot report their paper width
  /// (ESC/POS has no standard query, and the Bluetooth plugin is write-only),
  /// so the width is asked once per printer and remembered here.
  /// Device-local, never synced — a hardware setting per till.
  Future<ReceiptPaperSize?> paperSizeFor(String mac) async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyPaperSize(prefs);
    final stored = prefs.getString('$_paperSizeKeyPrefix$mac');
    return stored == null ? null : ReceiptPaperSize.fromStorage(stored);
  }

  /// Saves the paper width for the printer at [mac].
  Future<void> savePaperSizeFor(String mac, ReceiptPaperSize size) async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyPaperSize(prefs);
    await prefs.setString('$_paperSizeKeyPrefix$mac', size.name);
  }

  /// The print style saved for the printer at [mac]; text when unset.
  Future<ReceiptPrintStyle> printStyleFor(String mac) async {
    final prefs = await SharedPreferences.getInstance();
    return ReceiptPrintStyle.fromStorage(
      prefs.getString('$_printStyleKeyPrefix$mac'),
    );
  }

  /// Saves the print style for the printer at [mac].
  Future<void> savePrintStyleFor(String mac, ReceiptPrintStyle style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_printStyleKeyPrefix$mac', style.name);
  }

  /// The receipt size saved for the printer at [mac]; full when unset (#676).
  Future<ReceiptSize> receiptSizeFor(String mac) async {
    final prefs = await SharedPreferences.getInstance();
    return ReceiptSize.fromStorage(
      prefs.getString('$_receiptSizeKeyPrefix$mac'),
    );
  }

  /// Saves the receipt size for the printer at [mac].
  Future<void> saveReceiptSizeFor(String mac, ReceiptSize size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_receiptSizeKeyPrefix$mac', size.name);
  }

  /// The receipt size of the printer receipts go to right now (see
  /// [currentPrinterId]); full when there is none.
  Future<ReceiptSize> currentReceiptSize() async {
    final id = await currentPrinterId();
    return id == null ? ReceiptSize.full : receiptSizeFor(id);
  }

  /// The print style of the printer receipts go to right now (see
  /// [currentPrinterId]); text when there is none.
  Future<ReceiptPrintStyle> currentPrintStyle() async {
    final id = await currentPrinterId();
    return id == null ? ReceiptPrintStyle.text : printStyleFor(id);
  }

  /// The printer receipts go to right now: an attached, allowed USB printer
  /// first, else the Bluetooth printer last connected to. Never shows the USB
  /// permission prompt.
  Future<String?> currentPrinterId() async {
    final usb = await attachedUsbPrinter(askPermission: false);
    return usb?.id ?? await lastConnectedMac();
  }

  /// Whether this device has a printer to print on: a USB printer plugged in,
  /// or a Bluetooth printer it has connected to before. Auto-print after a
  /// sale skips quietly when false (#614), so phones without a printer never
  /// see a print error.
  Future<bool> hasPrinterSetUp() async {
    try {
      if ((await _usb.list()).any((p) => p.id.isNotEmpty)) return true;
    } catch (e) {
      AppLogger.error('Listing USB printers failed: $e');
    }
    return await lastConnectedMac() != null;
  }

  // ── USB (#614) ────────────────────────────────────────────────────────

  /// Every USB printer plugged in right now. Each one seen for the first time
  /// is saved as 80mm + Text (the owner's default for USB till printers), so
  /// the paper-size question is never asked for USB. With [askPermission],
  /// printers not yet allowed get Android's permission prompt.
  Future<List<UsbPrinterInfo>> usbPrinters({bool askPermission = false}) async {
    try {
      final listed = (await _usb.list()).where((p) => p.id.isNotEmpty);
      final result = <UsbPrinterInfo>[];
      for (final p in listed) {
        await _ensureUsbDefaults(p.id);
        if (p.hasPermission || !askPermission) {
          result.add(p);
          continue;
        }
        _usbPermissionAsked.add(p.id);
        final granted = await _usb.requestPermission(p.id);
        result.add(p.copyWith(hasPermission: granted));
      }
      return result;
    } catch (e) {
      AppLogger.error('Listing USB printers failed: $e');
      return const [];
    }
  }

  /// The USB printer to print on, or null. Takes the first attached printer;
  /// when Android has not allowed it yet, asks once per app run (unless
  /// [askPermission] is false) and returns it only if allowed.
  Future<UsbPrinterInfo?> attachedUsbPrinter({bool askPermission = true}) async {
    try {
      final listed = (await _usb.list()).where((p) => p.id.isNotEmpty);
      if (listed.isEmpty) return null;
      final first = listed.first;
      await _ensureUsbDefaults(first.id);
      if (first.hasPermission) return first;
      if (!askPermission || _usbPermissionAsked.contains(first.id)) {
        return null;
      }
      _usbPermissionAsked.add(first.id);
      final granted = await _usb.requestPermission(first.id);
      return granted ? first.copyWith(hasPermission: true) : null;
    } catch (e) {
      AppLogger.error('USB printer lookup failed: $e');
      return null;
    }
  }

  /// Sends the sample receipt (#702) to the USB printer [id], in that
  /// printer's paper size, print style and receipt size. True when it printed.
  Future<bool> testPrintUsb(
    String id, {
    String? businessName,
    DateTime? saleDate,
  }) async {
    try {
      final bytes = await buildSampleReceiptBytes(
        businessName: businessName,
        paperSize: await paperSizeFor(id) ?? ReceiptPaperSize.mm80,
        printStyle: await printStyleFor(id),
        receiptSize: await receiptSizeFor(id),
        saleDate: saleDate,
      );
      return await _usb.write(id, bytes);
    } catch (e) {
      AppLogger.error('USB test print failed: $e');
      return false;
    }
  }

  /// Sends the same sample receipt to the Bluetooth printer [mac] (#676,
  /// #702), so the owner can check Font B / Compact on a real printer.
  /// Connects first if needed. True when it printed.
  Future<bool> testPrintBluetooth(
    String mac, {
    String? businessName,
    DateTime? saleDate,
  }) async {
    try {
      if (!await isConnected || await lastConnectedMac() != mac) {
        if (!await connect(mac)) return false;
      }
      final bytes = await buildSampleReceiptBytes(
        businessName: businessName,
        paperSize: await paperSizeFor(mac) ?? ReceiptPaperSize.mm58,
        printStyle: await printStyleFor(mac),
        receiptSize: await receiptSizeFor(mac),
        saleDate: saleDate,
      );
      return await _writeJob(bytes);
    } catch (e) {
      AppLogger.error('Bluetooth test print failed: $e');
      return false;
    }
  }

  /// The ESC/POS bytes of the sample receipt: the same lines (or paper
  /// receipt picture) the Test print preview shows.
  static Future<List<int>> buildSampleReceiptBytes({
    String? businessName,
    required ReceiptPaperSize paperSize,
    required ReceiptPrintStyle printStyle,
    ReceiptSize receiptSize = ReceiptSize.full,
    DateTime? saleDate,
  }) {
    final date = saleDate ?? DateTime.now();
    if (SampleReceipt.isText(printStyle, receiptSize)) {
      return ThermalReceiptService.buildFromLines(
        SampleReceipt.lines(
          paperSize: paperSize,
          receiptSize: receiptSize,
          saleDate: date,
          businessName: businessName,
        ),
        paperSize,
        compact: receiptSize == ReceiptSize.compact,
      );
    }
    return ThermalReceiptService.buildReceipt(
      orderId: SampleReceipt.orderId,
      cart: SampleReceipt.cart,
      subtotal: SampleReceipt.subtotal,
      crateDeposit: 0,
      total: SampleReceipt.total,
      paymentMethod: SampleReceipt.paymentMethod,
      cashReceived: SampleReceipt.cashReceived,
      businessName: businessName,
      cashierName: SampleReceipt.cashierName,
      saleDate: date,
      tracksCrates: false,
      paperSize: paperSize,
      printStyle: printStyle,
      receiptSize: receiptSize,
    );
  }

  Future<void> _ensureUsbDefaults(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final sizeKey = '$_paperSizeKeyPrefix$id';
    final styleKey = '$_printStyleKeyPrefix$id';
    if (!prefs.containsKey(sizeKey)) {
      await prefs.setString(sizeKey, ReceiptPaperSize.mm80.name);
    }
    if (!prefs.containsKey(styleKey)) {
      await prefs.setString(styleKey, ReceiptPrintStyle.text.name);
    }
  }

  /// One-time move of the old device-wide paper size onto the printer that
  /// was in use when it was chosen. Runs before the last-used printer can be
  /// overwritten, so the old choice lands on the right printer. Without a
  /// last-used printer there is nothing to attach it to, so it is dropped and
  /// the next print asks.
  Future<void> _migrateLegacyPaperSize(SharedPreferences prefs) async {
    final legacy = prefs.getString(_legacyPaperSizeKey);
    if (legacy == null) return;
    final mac = prefs.getString(_lastMacKey);
    final key = '$_paperSizeKeyPrefix$mac';
    if (mac != null && mac.isNotEmpty && !prefs.containsKey(key)) {
      await prefs.setString(key, ReceiptPaperSize.fromStorage(legacy).name);
    }
    await prefs.remove(_legacyPaperSizeKey);
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

  /// Writes a complete print job to the printer.
  ///
  /// Fixes missing receipt headers (shop name, order #, items) on Android Bluetooth
  /// printers. When an idle printer sleeps or a link opens, the printer drops bytes
  /// received before its print head and firmware are awake. On Android, we first send
  /// ESC @ ([_escInit]) to wake and reset the printer, wait [_wakeGap] for the
  /// firmware to become ready, and then write [bytes] in one single call.
  /// Non-Android platforms write [bytes] once directly.
  Future<bool> _writeJob(List<int> bytes) async {
    if (_isAndroid) {
      final wakeOk = await _writeBytes(_escInit);
      if (!wakeOk) return false;
      await _wait(_wakeGap);
      return await _writeBytes(bytes);
    }
    return await _writeBytes(bytes);
  }

  /// Prints a complete job: on the attached USB printer first; if there is
  /// none, or the USB write fails, on the Bluetooth printer (auto-connecting).
  /// USB gets the bytes as they are — no ESC @ wake gap, which only Bluetooth
  /// links need, and receipts already start with ESC @.
  Future<bool> printBytes(List<int> bytes) async {
    final usb = await attachedUsbPrinter();
    if (usb != null) {
      if (await _usb.write(usb.id, bytes)) {
        AppLogger.info('Printed on USB printer ${usb.name}');
        return true;
      }
      AppLogger.error('USB print failed on ${usb.name}; trying Bluetooth');
    }
    try {
      if (!await isConnected) {
        final connected = await autoConnect();
        if (!connected) return false;
      }
      final ok = await _writeJob(bytes);
      if (ok) AppLogger.info('Printed on Bluetooth printer');
      return ok;
    } catch (e) {
      AppLogger.error('Printing failed: $e');
      return false;
    }
  }

  /// Writes bytes without attempting auto-connect. Use this after the user
  /// has manually selected a device through the [PrinterPicker]. Bluetooth
  /// only: it follows a manual Bluetooth pick.
  Future<bool> printBytesDirectly(List<int> bytes) async {
    try {
      if (!await isConnected) return false;
      return await _writeJob(bytes);
    } catch (e) {
      AppLogger.error('Direct printing failed: $e');
      return false;
    }
  }
}
