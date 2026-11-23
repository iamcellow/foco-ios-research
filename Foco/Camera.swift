import AVFoundation
import os
import SwiftUI

/// The AVCaptureSession and all hardware configuration live on a dedicated queue.
final class Camera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "foco.capture", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var activeID: Int64?
    private var file: URL?
    private var captureError: Error?
    private var mounted = false
    @Published private(set) var ready = false
    @Published private(set) var shooting = false
    @Published private(set) var rawAvailable = false
    private(set) var frameFocus = CGPoint(x: 0.5, y: 0.5)
    @Published private(set) var isoRange: ClosedRange<Double> = 40 ... 1600
    @Published private(set) var shutterRange: ClosedRange<Double> = 15 ... 1000
    @Published var message: String?
    @Published var finished: URL?
    private func post(_ f: @escaping () -> Void) {
        DispatchQueue.main.async(execute: f)
    }

    func start() {
        queue.async { self.mounted = true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: launch()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { yes in
                if yes {
                    self.launch()
                } else {
                    self.fail("Autorize a câmera nos Ajustes ou importe uma foto.")
                }
            }
        default: fail("Acesso à câmera indisponível. Abra Ajustes ou importe uma foto.")
        }
    }

    private func launch() {
        queue.async {
            guard self.mounted else { return }
            do {
                if self.device == nil {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw FocoError.message("Câmera principal indisponível.") }
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    guard self.session.canAddInput(input) else { self.session.commitConfiguration(); throw FocoError.message("Entrada da câmera indisponível.") }
                    self.session.addInput(input)
                    guard self.session.canAddOutput(self.output) else {
                        self.session.removeInput(input); self.session.commitConfiguration(); throw FocoError.message("Saída de fotografia indisponível.")
                    }
                    self.session.addOutput(self.output)
                    let sizes = device.activeFormat.supportedMaxPhotoDimensions
                    if let largest = sizes.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) {
                        self.output.maxPhotoDimensions = largest
                    }
                    if self.output.isDepthDataDeliverySupported {
                        self.output.isDepthDataDeliveryEnabled = true
                    }
                    self.output.maxPhotoQualityPrioritization = .quality
                    self.session.commitConfiguration()
                    self.device = device
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let raw = self.output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
                guard let format = self.device?.activeFormat else { throw FocoError.message("Formato de câmera indisponível.") }
                let iso = Double(format.minISO) ... Double(format.maxISO)
                let minTime = format.minExposureDuration.seconds, maxTime = format.maxExposureDuration.seconds
                let times = minTime > 0 && maxTime >= minTime ? (1 / maxTime) ... (1 / minTime) : 15 ... 1000
                let running = self.session.isRunning
                self.post { self.ready = running; self.rawAvailable = raw; self.isoRange = iso; self.shutterRange = times; self.message = nil }
            } catch { self.fail(error.localizedDescription) }
        }
    }

    func stop() {
        queue.async {
            self.mounted = false
            if self.activeID == nil, self.session.isRunning {
                self.session.stopRunning()
            }
            self.post { self.ready = false }
        }
    }

    private func fail(_ s: String) {
        Logger().error("Câmera: \(s)"); post { self.message = s }
    }

    private func configure(_ f: @escaping (AVCaptureDevice) -> Void) {
        queue.async {
            guard let dev = self.device else { return }
            do { try dev.lockForConfiguration(); defer { dev.unlockForConfiguration() }; f(dev) }
            catch { self.fail(error.localizedDescription) }
        }
    }

    func exposure(manual: Bool, iso: Float, seconds: Double, bias: Float) {
        configure { dev in
            if manual, dev.isExposureModeSupported(.custom) {
                let fmt = dev.activeFormat
                let t = max(fmt.minExposureDuration.seconds, min(fmt.maxExposureDuration.seconds, seconds))
                dev.setExposureModeCustom(duration: CMTime(seconds: t, preferredTimescale: 1_000_000), iso: max(fmt.minISO, min(fmt.maxISO, iso)), completionHandler: nil)
            } else if dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
                dev.setExposureTargetBias(max(dev.minExposureTargetBias, min(dev.maxExposureTargetBias, bias)), completionHandler: nil)
            }
        }
    }

    func focus(_ point: CGPoint, framePoint: CGPoint) {
        frameFocus = framePoint
        configure { dev in
            if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.autoFocus) {
                dev.focusPointOfInterest = point; dev.focusMode = .autoFocus
            }
            if dev.exposureMode != .custom, dev.isExposurePointOfInterestSupported {
                dev.exposurePointOfInterest = point
            }
        }
    }

    func manualFocus(_ pos: Float) {
        configure { dev in
            if dev.isLockingFocusWithCustomLensPositionSupported {
                dev.setFocusModeLocked(lensPosition: pos, completionHandler: nil)
            }
        }
    }

    func capture(raw: Bool, angle: CGFloat) {
        guard ready,!shooting else { return }
        shooting = true
        queue.async {
            guard self.activeID == nil, self.session.isRunning else { self.post { self.shooting = false }; return }
            let s: AVCapturePhotoSettings
            if raw {
                guard let fmt = self.output.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat) else {
                    self.post { self.shooting = false }; self.fail("Esta configuração não oferece Bayer RAW. Selecione JPEG."); return
                }
                s = AVCapturePhotoSettings(rawPixelFormatType: fmt)
                s.photoQualityPrioritization = .speed
            } else {
                s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                s.photoQualityPrioritization = .quality
                s.isDepthDataDeliveryEnabled = self.output.isDepthDataDeliveryEnabled
                if s.isDepthDataDeliveryEnabled {
                    s.embedsDepthDataInPhoto = true
                }
            }
            s.maxPhotoDimensions = self.output.maxPhotoDimensions
            if let c = self.output.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
            self.activeID = s.uniqueID; self.file = nil; self.captureError = nil
            self.output.capturePhoto(with: s, delegate: self)
        }
    }

    func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation(), raw = photo.isRawPhoto
        queue.async {
            do {
                if let error {
                    throw error
                }
                guard let data else { throw FocoError.message("A câmera não forneceu os dados da foto.") }
                let dir = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Negativos")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(raw ? "dng" : "jpg")
                try data.write(to: dest, options: .atomic); self.file = dest
            } catch { self.captureError = error }
        }
    }

    func photoOutput(_: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        queue.async {
            guard self.activeID == resolvedSettings.uniqueID else { return }
            let file = self.file, failure = error ?? self.captureError
            self.activeID = nil
            if !self.mounted, self.session.isRunning {
                self.session.stopRunning()
            }
            self.post { self.shooting = false
                if let failure {
                    self.fail(failure.localizedDescription)
                } else if let file {
                    self.finished = file
                } else {
                    self.fail("Captura concluída sem arquivo.")
                }
            }
        }
    }
}

final class FinderView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var preview: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var focusAction: ((CGPoint, CGPoint) -> Void)?
    private let focusRing = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        focusRing.strokeColor = UIColor.systemYellow.cgColor; focusRing.fillColor = UIColor.clear.cgColor
        focusRing.lineWidth = 1.5; layer.addSublayer(focusRing)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Storyboard indisponível")
    }

    @objc func tapped(_ gesture: UITapGestureRecognizer) {
        let tap = gesture.location(in: self)
        let frame = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard frame.width > 0, frame.height > 0, frame.contains(tap) else { return }
        let p = CGPoint(x: (tap.x - frame.minX) / frame.width, y: (tap.y - frame.minY) / frame.height)
        focusRing.path = UIBezierPath(roundedRect: CGRect(x: tap.x - 17, y: tap.y - 17, width: 34, height: 34), cornerRadius: 6).cgPath
        focusAction?(preview.captureDevicePointConverted(fromLayerPoint: tap), p)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let c = preview.connection, c.isVideoRotationAngleSupported(captureAngle) {
            c.videoRotationAngle = captureAngle
        }
    }

    var captureAngle: CGFloat {
        switch window?.windowScene?.interfaceOrientation { case .landscapeLeft: return 0;case .landscapeRight: return 180;case .portraitUpsideDown: return 270;default: return 90 }
    }
}

struct Finder: UIViewRepresentable {
    let camera: Camera
    func makeUIView(context _: Context) -> FinderView {
        let v = FinderView()
        v.preview.session = camera.session; v.preview.videoGravity = .resizeAspect
        v.focusAction = camera.focus; return v
    }

    func updateUIView(_ view: FinderView, context _: Context) {
        view.setNeedsLayout()
    }
}
