import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // BGTaskScheduler requires launch handlers to be registered before
    // `didFinishLaunching` returns; under the UIScene lifecycle Flutter's
    // own plugin registration happens later, during scene connection, so
    // this has to be re-registered here on every launch.
    WorkmanagerPlugin.registerLaunchHandlers()

    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      // Makes other plugins (DB, ONNX runtime, photo_manager, ...) available
      // to the headless engine Workmanager spins up for a background run.
      GeneratedPluginRegistrant.register(with: registry)
    }

    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "sims.backgroundSync")

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
