// Entirely synthetic pixels; never opens a Photos library.
import Foundation
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let video = root.appendingPathComponent("synthetic.mp4")
let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128])
let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 128])
writer.add(input)
guard writer.startWriting() else { fatalError("writer start failed") }
writer.startSession(atSourceTime: .zero)
for frame in 0..<30 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32ARGB, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    context.setFillColor(CGColor(red: CGFloat(frame) / 30, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
    if frame == 0 {
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("still.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6, kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2030:01:02 03:04:05"], kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.25, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 2.5, kCGImagePropertyGPSLongitudeRef: "E"]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fatalError("JPEG failed") }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    guard adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)) else { fatalError("append failed") }
}
input.markAsFinished()
let semaphore = DispatchSemaphore(value: 0)
writer.finishWriting { semaphore.signal() }
semaphore.wait()
guard writer.status == .completed else { fatalError("writer failed") }

// Add a synthetic 440 Hz mono audio track, then form a motion JPEG with XMP timing.
func little<T: FixedWidthInteger>(_ value: T) -> Data {
  var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) }
}
let sampleCount = 48000 * 2
var pcm = Data()
for i in 0..<sampleCount { pcm.append(little(Int16(sin(Double(i) * 2 * Double.pi * 440 / 48000) * 5000))) }
var wav = Data("RIFF".utf8); wav.append(little(UInt32(36 + pcm.count))); wav.append(Data("WAVEfmt ".utf8))
wav.append(little(UInt32(16))); wav.append(little(UInt16(1))); wav.append(little(UInt16(1)))
wav.append(little(UInt32(48000))); wav.append(little(UInt32(96000))); wav.append(little(UInt16(2))); wav.append(little(UInt16(16)))
wav.append(Data("data".utf8)); wav.append(little(UInt32(pcm.count))); wav.append(pcm)
let sound = root.appendingPathComponent("tone.wav"); try wav.write(to: sound)
let source = AVURLAsset(url: video), audio = AVURLAsset(url: sound)
let composition = AVMutableComposition()
let vt = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
try vt.insertTimeRange(CMTimeRange(start: .zero, duration: source.duration), of: source.tracks(withMediaType: .video)[0], at: .zero)
vt.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 128, ty: 0)
let at = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
try at.insertTimeRange(CMTimeRange(start: .zero, duration: source.duration), of: audio.tracks(withMediaType: .audio)[0], at: .zero)
let combined = root.appendingPathComponent("with-audio.mp4")
let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
export.outputURL = combined; export.outputFileType = .mp4
let done = DispatchSemaphore(value: 0); export.exportAsynchronously { done.signal() }
guard done.wait(timeout: .now() + 30) == .success, export.status == .completed else { fatalError("Audio fixture export failed") }
let original = try Data(contentsOf: root.appendingPathComponent("still.jpg"))
let xmp = Data(("http://ns.adobe.com/xap/1.0/" + String(UnicodeScalar(0)) + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:GCamera=\"http://ns.google.com/photos/1.0/camera/\" GCamera:MotionPhoto=\"1\" GCamera:MotionPhotoPresentationTimestampUs=\"850000\"/></rdf:RDF></x:xmpmeta>").utf8)
let n = xmp.count + 2
var data = original.prefix(2); data.append(contentsOf: [0xff, 0xe1, UInt8(n >> 8), UInt8(n & 255)]); data.append(xmp); data.append(original.dropFirst(2))
let movie = try Data(contentsOf: combined)
guard movie.range(of: Data("ftypmp42".utf8)) != nil else { fatalError("fixture requires mp42 brand") }
data.append(movie)
try data.write(to: root.appendingPathComponent("motion.jpg"))
print("Synthetic motion JPEG with audio, EXIF, GPS, orientation and XMP generated")
