package com.reebaplus.pos

import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterFragmentActivity() {
    private var usbPrinterPlugin: UsbPrinterPlugin? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // #608: draw behind the system bars on Android 10–14 too, matching
        // Android 15+ where targetSdk 36 already forces it (Play Console
        // edge-to-edge warning). Called after super so Flutter has already
        // swapped LaunchTheme for NormalTheme before the window decor is
        // built. SystemUiMode.edgeToEdge in main.dart keeps it on across
        // resumes.
        enableEdgeToEdge()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // #614: USB receipt printers (MethodChannel reebaplus/usb_printer).
        usbPrinterPlugin?.dispose()
        usbPrinterPlugin = UsbPrinterPlugin(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        usbPrinterPlugin?.dispose()
        usbPrinterPlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
