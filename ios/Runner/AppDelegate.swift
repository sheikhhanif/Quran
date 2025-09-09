import Flutter
import UIKit
import CoreText

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "SurahHeaderView") {
      registrar.register(SurahHeaderPlatformViewFactory(registrar: registrar), withId: "SurahHeaderView")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

class SurahHeaderPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let registrar: FlutterPluginRegistrar

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return SurahHeaderPlatformView(frame: frame, viewId: viewId, args: args, registrar: registrar)
  }
}

class SurahHeaderPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let label: UILabel

  init(frame: CGRect, viewId: Int64, args: Any?, registrar: FlutterPluginRegistrar) {
    self.container = UIView(frame: frame)
    self.label = UILabel(frame: .zero)
    super.init()

    container.backgroundColor = .clear
    label.textAlignment = .center
    label.numberOfLines = 1
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.1
    
    // Parse arguments for theme and other parameters
    var themeMode = "normal" // default
    var maxWidth = frame.width
    var ligatureText = ""
    
    if let dict = args as? [String: Any] {
      if let text = dict["text"] as? String {
        ligatureText = text
        print("iOS Platform View: Received ligature text: \(text)")
      }
      if let theme = dict["theme"] as? String {
        themeMode = theme
        print("iOS Platform View: Received theme: \(theme)")
      }
      if let width = dict["maxWidth"] as? Double {
        maxWidth = CGFloat(width)
        print("iOS Platform View: Received maxWidth: \(width)")
      }
    }
    
    if ligatureText.isEmpty {
      print("iOS Platform View: No text received in arguments")
      ligatureText = "سورة 1" // Fallback
    }
    
    // Set theme-based text color
    switch themeMode {
    case "reading":
      label.textColor = UIColor(red: 43/255, green: 24/255, blue: 16/255, alpha: 1) // #2B1810
    case "dark":
      label.textColor = UIColor(red: 232/255, green: 227/255, blue: 211/255, alpha: 1) // #E8E3D3
    default: // normal
      label.textColor = UIColor(red: 26/255, green: 26/255, blue: 26/255, alpha: 1) // #1A1A1A
    }

    // Calculate dynamic font size based on maxWidth
    let baseFontSize: CGFloat = 96
    let scaleFactor = min(maxWidth / 350.0, 2.0) // Scale based on width, max 2x
    let dynamicFontSize = baseFontSize * scaleFactor
    print("iOS Platform View: Calculated font size: \(dynamicFontSize) for maxWidth: \(maxWidth)")

    // Load font from Flutter assets
    let key = registrar.lookupKey(forAsset: "assets/quran/fonts/surah-header/surah-header.ttf")
    print("iOS Platform View: Looking for font with key: \(key)")
    
    if let path = Bundle.main.path(forResource: key, ofType: nil) {
      print("iOS Platform View: Found font path: \(path)")
      if let data = NSData(contentsOfFile: path) {
        print("iOS Platform View: Font data loaded, size: \(data.length) bytes")
        if let provider = CGDataProvider(data: data) {
          let font = CGFont(provider)
          if let postScriptName = font?.postScriptName {
            let fontName = postScriptName as String
            print("iOS Platform View: Font postscript name: \(fontName)")
            
            // Check if font is already available
            if UIFont(name: fontName, size: dynamicFontSize) != nil {
              print("iOS Platform View: Font already available: \(fontName)")
              label.font = UIFont(name: fontName, size: dynamicFontSize)
            } else {
              // Try to register the font
              var error: Unmanaged<CFError>?
              if CTFontManagerRegisterGraphicsFont(font!, &error) {
                print("iOS Platform View: Font registered successfully: \(fontName)")
                label.font = UIFont(name: fontName, size: dynamicFontSize)
              } else {
                print("iOS Platform View: Failed to register font")
                if let error = error {
                  print("iOS Platform View: Error: \(error)")
                }
                // Try to use the font anyway, it might be available under a different name
                label.font = UIFont(name: fontName, size: dynamicFontSize)
              }
            }
          }
        } else {
          print("iOS Platform View: Failed to create CGDataProvider")
        }
      } else {
        print("iOS Platform View: Failed to load font data from path")
      }
    } else {
      print("iOS Platform View: Font file not found in bundle")
      // List all available resources for debugging
      if let resourcePath = Bundle.main.resourcePath {
        print("iOS Platform View: Bundle resource path: \(resourcePath)")
        do {
          let contents = try FileManager.default.contentsOfDirectory(atPath: resourcePath)
          print("iOS Platform View: Available resources: \(contents)")
        } catch {
          print("iOS Platform View: Error listing resources: \(error)")
        }
      }
    }

    // Apply advanced typography features for ligatures
    let features: [[UIFontDescriptor.FeatureKey: Int]] = [
      [.featureIdentifier: kLigaturesType, .typeIdentifier: kCommonLigaturesOnSelector],
      [.featureIdentifier: kLigaturesType, .typeIdentifier: kContextualLigaturesOnSelector],
      [.featureIdentifier: kLigaturesType, .typeIdentifier: kRareLigaturesOnSelector]
    ]

    if let currentFont = label.font {
      let descriptor = currentFont.fontDescriptor.addingAttributes([
        UIFontDescriptor.AttributeName.featureSettings: features
      ])
      label.font = UIFont(descriptor: descriptor, size: currentFont.pointSize)
      print("iOS Platform View: Font loaded: \(currentFont.fontName)")
    } else {
      print("iOS Platform View: Font failed to load")
    }

    // Set the text with ligature support
    label.text = ligatureText
    print("iOS Platform View: Set text to: \(ligatureText)")
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
    ])
  }

  func view() -> UIView {
    return container
  }
}
