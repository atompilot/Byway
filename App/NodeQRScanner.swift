import AVFoundation
import SwiftUI
import VisionKit

struct NodeQRScanner: View {
    let save: (String) async throws -> String?

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = ScannerState.checking

    private enum ScannerState {
        case checking, ready, denied, unavailable, importing
        case partial(String)
        case invalidCode(String)
    }

    var body: some View {
        Group {
            switch state {
            case .checking:
                ProgressView()
            case .importing:
                ProgressView("正在导入")
            case .partial(let progress):
                ContentUnavailableView {
                    Label(progress, systemImage: "qrcode")
                } actions: {
                    Button("继续扫描") { state = .ready }
                }
            case .ready:
                QRCodeCamera(didRead: importCode) { state = .unavailable }
            case .denied:
                ContentUnavailableView {
                    Label("需要相机权限", systemImage: "camera")
                } description: {
                    Text("你可以在设置中允许 Byway 使用相机，或返回粘贴节点链接。")
                } actions: {
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
            case .unavailable:
                ContentUnavailableView("相机暂不可用", systemImage: "camera",
                                       description: Text("你可以返回粘贴节点链接。"))
            case .invalidCode(let message):
                ContentUnavailableView {
                    Label("无法导入节点", systemImage: "qrcode")
                } description: {
                    Text(message)
                } actions: {
                    Button("重新扫码") { state = .ready }
                }
            }
        }
        .navigationTitle("扫码添加")
        .navigationBarTitleDisplayMode(.inline)
        .task { await authorizeCamera() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .denied = state,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                state = DataScannerViewController.isAvailable ? .ready : .unavailable
            }
        }
    }

    private func authorizeCamera() async {
        guard DataScannerViewController.isSupported else {
            state = .unavailable
            return
        }
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard !Task.isCancelled else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            state = DataScannerViewController.isAvailable ? .ready : .unavailable
        case .denied:
            state = .denied
        default:
            state = .unavailable
        }
    }

    private func importCode(_ payload: String) {
        state = .importing
        Task {
            do { if let progress = try await save(payload) { state = .partial(progress) } }
            catch { state = .invalidCode(error.localizedDescription) }
        }
    }
}

private struct QRCodeCamera: UIViewControllerRepresentable {
    let didRead: (String) -> Void
    let unavailable: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(didRead: didRead, unavailable: unavailable)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.finish()
    }

    final class Controller: UIViewController, DataScannerViewControllerDelegate {
        private let didRead: (String) -> Void
        private let unavailable: () -> Void
        private var finished = false
        private let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )

        init(didRead: @escaping (String) -> Void, unavailable: @escaping () -> Void) {
            self.didRead = didRead
            self.unavailable = unavailable
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidLoad() {
            super.viewDidLoad()
            scanner.delegate = self
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !finished else { return }
            do { try scanner.startScanning() }
            catch { stopWithError() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            scanner.stopScanning()
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !finished, scanner.isScanning else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue else { continue }
                finish()
                didRead(payload)
                return
            }
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            stopWithError()
        }

        private func stopWithError() {
            guard !finished else { return }
            finish()
            unavailable()
        }

        func finish() {
            finished = true
            scanner.stopScanning()
        }
    }
}
