import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Matches `BackupExclusionService` on the Dart side.
  private static let backupChannelName = "reebaplus/backup_exclusion"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerBackupExclusionChannel(engineBridge)
  }

  /// #285: iOS has no manifest switch for backups. A file under Documents goes
  /// to iCloud unless it carries `NSURLIsExcludedFromBackupKey`, which only
  /// native code can set — so Dart asks for it through this channel.
  private func registerBackupExclusionChannel(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "ReebaplusBackupExclusion"
    ) else { return }

    let channel = FlutterMethodChannel(
      name: AppDelegate.backupChannelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromICloudBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(
          code: "bad_arguments",
          message: "excludeFromICloudBackup requires a 'path' string.",
          details: nil
        ))
        return
      }
      result(AppDelegate.excludeFromICloudBackup(path: path))
    }
  }

  /// Sets the exclusion flag on the database and its WAL sidecars — the till's
  /// most recent writes live in `-wal`, so excluding only the main file would
  /// still ship business data to iCloud.
  private static func excludeFromICloudBackup(path: String) -> Bool {
    let fileManager = FileManager.default
    var excludedAny = false
    for candidate in [path, path + "-wal", path + "-shm"] {
      guard fileManager.fileExists(atPath: candidate) else { continue }
      var url = URL(fileURLWithPath: candidate)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        excludedAny = true
      } catch {
        NSLog("[Reebaplus] iCloud backup exclusion failed for \(candidate): \(error)")
      }
    }
    return excludedAny
  }
}
