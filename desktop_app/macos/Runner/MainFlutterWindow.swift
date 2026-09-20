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
    registerImageClipboardChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  private func registerImageClipboardChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "clipboard_image", binaryMessenger: messenger)

    channel.setMethodCallHandler { call, result in
      let board = NSPasteboard.general
      if call.method == "writeImage" {
        guard let arguments = call.arguments as? [String: Any],
              let typedData = arguments["bytes"] as? FlutterStandardTypedData,
              let image = NSImage(data: typedData.data) else {
          result(
            FlutterError(
              code: "bad_image",
              message: "writeImage expects valid image bytes",
              details: nil
            )
          )
          return
        }
        let mime = arguments["mime"] as? String
        board.clearContents()
        board.writeObjects([image])
        if mime == "image/png" {
          board.setData(typedData.data, forType: .png)
        } else if mime == "image/jpeg" {
          board.setData(
            typedData.data,
            forType: NSPasteboard.PasteboardType("public.jpeg")
          )
        } else if mime == "image/webp" {
          board.setData(
            typedData.data,
            forType: NSPasteboard.PasteboardType("public.webp")
          )
        }
        result(nil)
        return
      }

      guard call.method == "readImage" else {
        result(FlutterMethodNotImplemented)
        return
      }

      let limit = (call.arguments as? [String: Any])?["limitBytes"] as? Int ?? 20 * 1024 * 1024

      func response(_ data: Data, _ mime: String, _ ext: String, _ compressed: Bool) {
        result([
          "bytes": FlutterStandardTypedData(bytes: data),
          "mime": mime,
          "extension": ext,
          "compressed": compressed,
        ])
      }

      func respondWithConvertedImage(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.80]
              ) else {
          return false
        }
        if jpeg.count > limit {
          result([
            "tooLarge": true,
            "size": jpeg.count,
          ])
          return true
        }
        response(jpeg, "image/jpeg", "jpg", true)
        return true
      }

      func respondWithImageData(
        _ data: Data,
        mime: String,
        ext: String
      ) -> Bool {
        if data.count <= limit {
          response(data, mime, ext, false)
          return true
        }
        guard let image = NSImage(data: data) else {
          return false
        }
        return respondWithConvertedImage(image)
      }

      func respondWithLocalImageFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let data = try? Data(contentsOf: url) else {
          return false
        }
        let ext = url.pathExtension.lowercased()
        let directTypes: [String: (String, String)] = [
          "png": ("image/png", "png"),
          "jpg": ("image/jpeg", "jpg"),
          "jpeg": ("image/jpeg", "jpg"),
          "webp": ("image/webp", "webp"),
        ]
        if let type = directTypes[ext] {
          return respondWithImageData(data, mime: type.0, ext: type.1)
        }
        // HEIC, TIFF, GIF, BMP, and other image files are converted to JPEG
        // so Android receives a broadly pasteable image format.
        guard let image = NSImage(data: data) else {
          return false
        }
        return respondWithConvertedImage(image)
      }

      let availableTypes = board.types?.map(\.rawValue) ?? []
      print("Clipboard image read; pasteboard types: \(availableTypes)")

      // Browsers normally provide PNG/JPEG bytes directly. WhatsApp Desktop
      // can provide WebP data instead, so accept that real image data too.
      let rawImageTypes: [(NSPasteboard.PasteboardType, String, String)] = [
        (.png, "image/png", "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "image/jpeg", "jpg"),
        (NSPasteboard.PasteboardType("public.webp"), "image/webp", "webp"),
        (NSPasteboard.PasteboardType("org.webmproject.webp"), "image/webp", "webp"),
      ]
      for (type, mime, ext) in rawImageTypes {
        if let data = board.data(forType: type),
           respondWithImageData(data, mime: mime, ext: ext) {
          return
        }
      }

      // These formats are common in macOS apps. Convert them to JPEG rather
      // than rejecting them merely because Android's clipboard is less
      // consistent about their original format.
      let convertibleImageTypes: [NSPasteboard.PasteboardType] = [
        .tiff,
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("com.microsoft.bmp"),
      ]
      for type in convertibleImageTypes {
        if let data = board.data(forType: type),
           let image = NSImage(data: data),
           respondWithConvertedImage(image) {
          return
        }
      }

      // Some desktop apps, including Electron-based apps such as WhatsApp,
      // copy a local file reference instead of placing pixels directly on the
      // pasteboard. Read only local image files; never fetch a remote URL.
      let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
      ]
      let fileURLs = board.readObjects(
        forClasses: [NSURL.self],
        options: fileOptions
      ) as? [URL] ?? []
      for url in fileURLs {
        if respondWithLocalImageFile(url) {
          return
        }
      }

      // Browsers can consume a promised file that is materialized only after
      // the receiving app asks for it. Support the same standard macOS
      // mechanism, while preserving all immediate clipboard paths above.
      if #available(macOS 10.13, *) {
        let receivers = board.readObjects(
          forClasses: [NSFilePromiseReceiver.self],
          options: nil
        ) as? [NSFilePromiseReceiver] ?? []
        if let receiver = receivers.first {
          let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSync-\(UUID().uuidString)", isDirectory: true)
          guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
          )) != nil else {
            result(nil)
            return
          }
          var finished = false
          func finishPromiseRead() {
            guard !finished else { return }
            finished = true
            try? FileManager.default.removeItem(at: directory)
          }
          let operationQueue = OperationQueue()
          operationQueue.maxConcurrentOperationCount = 1
          receiver.receivePromisedFiles(
            atDestination: directory,
            options: [:],
            operationQueue: operationQueue
          ) { url, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
              guard !finished else { return }
              if respondWithLocalImageFile(url) {
                finishPromiseRead()
              }
            }
          }
          // A provider may promise a non-image or fail without calling the
          // reader block. Resolve this MethodChannel call safely in that case.
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard !finished else { return }
            finishPromiseRead()
            result(nil)
          }
          return
        }
      }

      // A copied image may also be represented as a self-contained HTML data
      // URL. Support only embedded base64 pixels, not http(s) links, so copying
      // never causes Clipboard Sync to contact a website.
      if let htmlData = board.data(forType: .html),
         let html = String(data: htmlData, encoding: .utf8),
         let expression = try? NSRegularExpression(
           pattern: #"data:image/(png|jpe?g|webp);base64,([A-Za-z0-9+/=]+)"#,
           options: [.caseInsensitive]
         ) {
        let range = NSRange(html.startIndex..., in: html)
        if let match = expression.firstMatch(in: html, options: [], range: range) {
          let kind = (html as NSString).substring(with: match.range(at: 1)).lowercased()
          let base64 = (html as NSString).substring(with: match.range(at: 2))
          if let data = Data(base64Encoded: base64) {
            let ext = kind == "jpg" || kind == "jpeg" ? "jpg" : kind
            let mime = ext == "jpg" ? "image/jpeg" : "image/\(ext)"
            if respondWithImageData(data, mime: mime, ext: ext) {
              return
            }
          }
        }
      }

      // This covers standard TIFF and native NSImage pasteboard
      // representations used by Preview, Finder, and many macOS apps.
      if let image = NSImage(pasteboard: board),
         respondWithConvertedImage(image) {
        return
      }

      print("Clipboard item had no supported local image representation")
      result(nil)
    }
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
