import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerClipboardChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// Dart MethodChannel name: "clipboard"
  /// Same idea as Android MethodChannel — Dart asks, Swift talks to the OS.
  private func registerClipboardChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "clipboard", binaryMessenger: messenger)

    channel.setMethodCallHandler { call, result in
      let board = NSPasteboard.general

      switch call.method {
      case "changeToken":
        result(board.changeCount)

      case "readText":
        result(board.string(forType: .string) ?? "")

      case "writeText":
        guard let text = call.arguments as? String else {
          result(
            FlutterError(
              code: "bad_args",
              message: "writeText expects a String",
              details: nil
            )
          )
          return
        }
        board.clearContents()
        board.setString(text, forType: .string)
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
