import Cocoa
import CoreImage
import IOSurface
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

import Network

// class FrameSender {
//    private var connection: NWConnection
//
//    init(host: String, port: UInt16) {
//        print("FrameSender init", host, port)
//        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
//        connection.stateUpdateHandler = { newState in
//            switch newState {
//            case .ready:
//                print("Connected")
//            case let .failed(error):
//                print("Connection failed", error)
//            default:
//                break
//            }
//        }
//        connection.start(queue: .global())
//    }
//
//    func send(data: Data) {
//        connection.send(content: data, completion: .contentProcessed { error in
//            if let error = error {
//                print("Send error:", error)
//            }
//        })
//    }
// }

class FrameSender {
    private var connection: NWConnection
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue.global()
    private var isManuallyStopped = false

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        print("FrameSender init", host, port)
        connection = FrameSender.createConnection(host: host, port: port)
        startConnection()
    }

    private static func createConnection(host: String, port: UInt16) -> NWConnection {
        return NWConnection(host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: port)!,
                            using: .tcp)
    }

    private func startConnection() {
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                print("Connected")
            case let .failed(error):
                print("Connection failed:", error)
                self.reconnect()
            case let .waiting(error):
                print("Connection waiting:", error)
                self.reconnect()
            case .cancelled:
                print("Connection cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func reconnect() {
        guard !isManuallyStopped else { return }
        print("Reconnecting in 2 seconds...")
        connection.cancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            connection = FrameSender.createConnection(host: host, port: port)
            startConnection()
        }
    }

    func send(data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("Send error:", error)
                // Optional: reconnect if send fails
//                self.reconnect()
            }
        })
    }

    func stop() {
        isManuallyStopped = true
        connection.cancel()
    }
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClickOnScreen)))
    }

    private var display: CGVirtualDisplay!
    private var stream: CGDisplayStream?
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?
    private var frameSender: FrameSender!
    private var ciContext = CIContext(options: nil)

    override func viewDidLoad() {
        super.viewDidLoad()

//        frameSender = FrameSender(host: "127.0.0.1", port: 12345)
        frameSender = FrameSender(host: "192.168.0.2", port: 2400)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "DeskPad Display"
        descriptor.maxPixelsWide = 1280
        descriptor.maxPixelsHigh = 640
        descriptor.sizeInMillimeters = CGSize(width: 160, height: 100)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = 0x0001

        let display = CGVirtualDisplay(descriptor: descriptor)
        store.dispatch(ScreenViewAction.setDisplayID(display.displayID))
        self.display = display

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            // // 16:9
            // CGVirtualDisplayMode(width: 3840, height: 2160, refreshRate: 60),
            // CGVirtualDisplayMode(width: 2560, height: 1440, refreshRate: 60),
            // CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60),
            // CGVirtualDisplayMode(width: 1600, height: 900, refreshRate: 60),
            // CGVirtualDisplayMode(width: 1366, height: 768, refreshRate: 60),
            // CGVirtualDisplayMode(width: 1280, height: 720, refreshRate: 60),
            // // 16:10
            // CGVirtualDisplayMode(width: 2560, height: 1600, refreshRate: 60),
            // CGVirtualDisplayMode(width: 1920, height: 1200, refreshRate: 60),
            // CGVirtualDisplayMode(width: 1680, height: 1050, refreshRate: 60),
            // CGVirtualDisplayMode(width: 1440, height: 900, refreshRate: 60),
            // CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 60),

            CGVirtualDisplayMode(width: 1280, height: 640, refreshRate: 60),
            CGVirtualDisplayMode(width: 512, height: 256, refreshRate: 60),
            CGVirtualDisplayMode(width: 640, height: 320, refreshRate: 60),
            CGVirtualDisplayMode(width: 128, height: 64, refreshRate: 60),
        ]
        display.apply(settings)
    }

    override func update(with viewData: ScreenViewData) {
        if viewData.isWindowHighlighted != isWindowHighlighted {
            isWindowHighlighted = viewData.isWindowHighlighted
            view.window?.backgroundColor = isWindowHighlighted
                ? NSColor(named: "TitleBarActive")
                : NSColor(named: "TitleBarInactive")
            if isWindowHighlighted {
                view.window?.orderFrontRegardless()
            }
        }

        if
            viewData.resolution != .zero,
            viewData.resolution != previousResolution
            || viewData.scaleFactor != previousScaleFactor
        {
            previousResolution = viewData.resolution
            previousScaleFactor = viewData.scaleFactor
            stream = nil
            view.window?.setContentSize(viewData.resolution)
            view.window?.contentAspectRatio = viewData.resolution
            view.window?.center()
            let stream = CGDisplayStream(
                dispatchQueueDisplay: display.displayID,
                outputWidth: Int(viewData.resolution.width * viewData.scaleFactor),
                outputHeight: Int(viewData.resolution.height * viewData.scaleFactor),
                pixelFormat: 1_111_970_369, // BGRA?
                properties: [
                    CGDisplayStream.showCursor: true,
                ] as CFDictionary,
                queue: .main,
                handler: { [weak self] _, _, frameSurface, _ in
                    if let surface = frameSurface {
                        self?.view.layer?.contents = surface

//                        send unscaled BGRA
//                        IOSurfaceLock(surface, IOSurfaceLockOptions.readOnly, nil)
//                        let width = IOSurfaceGetWidth(surface)
//                        let height = IOSurfaceGetHeight(surface)
//                        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
//                        let baseAddress = IOSurfaceGetBaseAddress(surface)
//                        // Copy raw data
//                        let buffer = UnsafeRawBufferPointer(start: baseAddress, count: bytesPerRow * height)
//                        let data = Data(buffer)
//                        // Send over TCP
//                        self?.frameSender.send(data: data)
//                        IOSurfaceUnlock(surface, IOSurfaceLockOptions.readOnly, nil)

                        // Wrap IOSurface in CIImage
                        let ciImage = CIImage(ioSurface: surface)

                        // Scale to 128x64
                        let scaleX = 128.0 / CGFloat(IOSurfaceGetWidth(surface))
                        let scaleY = 64.0 / CGFloat(IOSurfaceGetHeight(surface))
                        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

                        // Render into bitmap
                        var bitmap = [UInt8](repeating: 0, count: 128 * 64 * 4) // BGRA
                        self?.ciContext.render(
                            scaledImage,
                            toBitmap: &bitmap,
                            rowBytes: 128 * 4,
                            bounds: CGRect(x: 0, y: 0, width: 128, height: 64),
                            format: .BGRA8,
                            colorSpace: CGColorSpaceCreateDeviceRGB()
                        )

//                        self?.frameSender.send(data: Data(bitmap))

                        // convert to rgb
                        var rgbData = [UInt8](repeating: 0, count: 128 * 64 * 3)
                        for i in 0 ..< 128 * 64 {
                            rgbData[i * 3 + 0] = bitmap[i * 4 + 2]
                            rgbData[i * 3 + 1] = bitmap[i * 4 + 1]
                            rgbData[i * 3 + 2] = bitmap[i * 4 + 0]

//                            let r = UInt16(bitmap[i * 4 + 2]) // R
//                            let g = UInt16(bitmap[i * 4 + 1]) // G
//                            let b = UInt16(bitmap[i * 4 + 0]) // B
//                            rgbData[i * 3 + 0] = UInt8((r * r) >> 8)
//                            rgbData[i * 3 + 1] = UInt8((g * g) >> 8)
//                            rgbData[i * 3 + 2] = UInt8((b * b) >> 8)
                        }

                        // Send over TCP
                        self?.frameSender.send(data: Data(rgbData))
                    }
                }
            )
            self.stream = stream
            stream?.start()
        }
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        let snappingOffset: CGFloat = 30
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        guard
            let screenResolution = previousResolution,
            abs(contentSize.width - screenResolution.width) < snappingOffset
        else {
            return frameSize
        }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: screenResolution)).size
    }

    @objc private func didClickOnScreen(_ gestureRecognizer: NSGestureRecognizer) {
        guard let screenResolution = previousResolution else {
            return
        }
        let clickedPoint = gestureRecognizer.location(in: view)
        let onScreenPoint = NSPoint(
            x: clickedPoint.x / view.frame.width * screenResolution.width,
            y: (view.frame.height - clickedPoint.y) / view.frame.height * screenResolution.height
        )
        store.dispatch(MouseLocationAction.requestMove(toPoint: onScreenPoint))
    }
}
