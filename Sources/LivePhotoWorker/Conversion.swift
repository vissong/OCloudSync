import AVFoundation
import Foundation
import ImageIO
import PhotosUI
// Adapted from the user-provided MotionPhotoFromiPhotos native converter.
import SyncCore
import UniformTypeIdentifiers

struct ConversionError: Error, CustomStringConvertible {
  let description: String
}

func copyStillHEIC(sourceData: Data, offset: Int, uuid: String, to outputURL: URL) throws {
  let stillData = sourceData.prefix(offset) as CFData
  guard let source = CGImageSourceCreateWithData(stillData, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else {
    throw ConversionError(description: "Could not read still image")
  }
  var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
  properties.removeValue(forKey: kCGImagePropertyMakerAppleDictionary as String)
  properties.removeValue(forKey: "{XMP}")
  properties.removeValue(forKey: "{MPF}")
  properties[kCGImagePropertyMakerAppleDictionary as String] = ["17": uuid]
  properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0

  guard
    let destination = CGImageDestinationCreateWithURL(
      outputURL as CFURL, UTType.heic.identifier as CFString, 1, nil)
  else {
    throw ConversionError(description: "Could not create HEIC destination")
  }
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  guard CGImageDestinationFinalize(destination) else {
    throw ConversionError(description: "Could not finalize HEIC")
  }
}

func metadataItem(identifier: String, value: Any, dataType: String) -> AVMutableMetadataItem {
  let item = AVMutableMetadataItem()
  item.key = String(identifier.dropFirst("mdta/".count)) as NSString
  item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
  item.value = value as? NSCopying & NSObjectProtocol
  item.dataType = dataType
  return item
}

func appendTrack(
  input: AVAssetWriterInput, output: AVAssetReaderOutput, group: DispatchGroup, label: String
) {
  input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
    while input.isReadyForMoreMediaData {
      if let sample = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(sample) == 0 {
          continue
        }
        if !input.append(sample) {
          input.markAsFinished()
          group.leave()
          return
        }
      } else {
        input.markAsFinished()
        group.leave()
        return
      }
    }
  }
}

func makeMOV(videoURL: URL, outputURL: URL, uuid: String, stillTime: CMTime) throws {
  let videoAsset = AVURLAsset(url: videoURL)
  guard let videoTrack = videoAsset.tracks(withMediaType: .video).first else {
    throw ConversionError(description: "No video track")
  }
  let audioTrack = videoAsset.tracks(withMediaType: .audio).first
  guard CMTimeGetSeconds(stillTime) >= 0,
    CMTimeGetSeconds(stillTime) < CMTimeGetSeconds(videoAsset.duration)
  else {
    throw ConversionError(description: "Still time is outside motion duration")
  }

  let videoReader = try AVAssetReader(asset: videoAsset)
  let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

  let idItem = AVMutableMetadataItem()
  idItem.key = "com.apple.quicktime.content.identifier" as NSString
  idItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
  idItem.value = uuid as NSString
  idItem.dataType = "com.apple.metadata.datatype.UTF-8"
  writer.metadata = [idItem]

  let videoOutput = AVAssetReaderTrackOutput(
    track: videoTrack,
    outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
    ]
  )
  videoReader.add(videoOutput)
  let videoInput = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(videoTrack.naturalSize.width),
      AVVideoHeightKey: Int(videoTrack.naturalSize.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 12_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoAllowFrameReorderingKey: false,
        AVVideoMaxKeyFrameIntervalKey: 30,
      ],
    ])
  videoInput.transform = videoTrack.preferredTransform
  writer.add(videoInput)

  var audioOutput: AVAssetReaderTrackOutput?
  var audioInput: AVAssetWriterInput?
  if let audioTrack {
    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
    videoReader.add(output)
    let input = AVAssetWriterInput(
      mediaType: .audio, outputSettings: nil,
      sourceFormatHint: audioTrack.formatDescriptions.first as! CMFormatDescription?)
    writer.add(input)
    audioOutput = output
    audioInput = input
  }

  let spec: [String: Any] = [
    kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
      "mdta/com.apple.quicktime.still-image-time",
    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
      "com.apple.metadata.datatype.int8",
  ]
  var desc: CMFormatDescription?
  CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
    allocator: kCFAllocatorDefault,
    metadataType: kCMMetadataFormatType_Boxed,
    metadataSpecifications: [spec] as CFArray,
    formatDescriptionOut: &desc
  )
  guard let formatDescription = desc else {
    throw ConversionError(description: "Could not create metadata format description")
  }
  let metadataInput = AVAssetWriterInput(
    mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription)
  let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
  writer.add(metadataInput)

  guard writer.startWriting() else {
    throw ConversionError(
      description: writer.error?.localizedDescription ?? "Writer failed to start")
  }
  writer.startSession(atSourceTime: .zero)
  guard videoReader.startReading() else {
    throw ConversionError(
      description: videoReader.error?.localizedDescription ?? "Video reader failed")
  }

  let stillItem = metadataItem(
    identifier: "mdta/com.apple.quicktime.still-image-time", value: Int8(0),
    dataType: "com.apple.metadata.datatype.int8")
  let stillRange = CMTimeRange(start: stillTime, duration: CMTime(value: 1, timescale: 600))
  guard adaptor.append(AVTimedMetadataGroup(items: [stillItem], timeRange: stillRange)) else {
    throw ConversionError(description: "Could not append still-image-time")
  }
  metadataInput.markAsFinished()

  let group = DispatchGroup()
  group.enter()
  appendTrack(input: videoInput, output: videoOutput, group: group, label: "video-writer")
  if let audioInput, let audioOutput {
    group.enter()
    appendTrack(input: audioInput, output: audioOutput, group: group, label: "audio-writer")
  }
  guard group.wait(timeout: .now() + 120) == .success else {
    videoReader.cancelReading()
    writer.cancelWriting()
    throw ConversionError(description: "Video conversion timed out")
  }

  if videoReader.status != .completed {
    throw ConversionError(
      description: videoReader.error?.localizedDescription ?? "Video reader failed")
  }

  let sem = DispatchSemaphore(value: 0)
  writer.finishWriting { sem.signal() }
  _ = sem.wait(timeout: .now() + 120)
  guard writer.status == .completed else {
    throw ConversionError(description: writer.error?.localizedDescription ?? "Writer failed")
  }
}
