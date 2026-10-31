package com.reebaplus.pos

import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity: FlutterFragmentActivity() {
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
}
