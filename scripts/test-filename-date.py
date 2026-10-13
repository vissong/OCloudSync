#!/usr/bin/env python3
"""Exercise production Photos metadata lookup with local PhotoKit spies, without a real library."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/OCloudSync/PhotoImporter.swift').read_text()
def extract(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
harness = r'''
import Foundation
enum PHAssetMediaType: Int { case image = 1, video = 2 }
struct Subtypes: OptionSet { let rawValue: Int; static let photoLive = Subtypes(rawValue: 1) }
enum ResourceType { case photo, video, pairedVideo }
struct PHAssetResource {
  let type: ResourceType, originalFilename: String
  static func assetResources(for asset: PHAsset) -> [PHAssetResource] { asset.resources }
}
final class PHFetchOptions {
  var predicate: NSPredicate?, includeHiddenAssets = false, includeAllBurstAssets = false
}
struct Fetch {
  let items: [PHAsset]
  func enumerateObjects(_ block: (PHAsset,Int,UnsafeMutablePointer<ObjCBool>) -> Void) {
    var stop: ObjCBool = false
    for (n,item) in items.enumerated() { block(item,n,&stop); if stop.boolValue { break } }
  }
}
struct PHAsset {
  let localIdentifier: String, creationDate: Date?, mediaType: PHAssetMediaType
  let mediaSubtypes: Subtypes, resources: [PHAssetResource]
  static var library = [PHAsset]()
  static var queries = 0
  static func fetchAssets(with options: PHFetchOptions) -> Fetch {
    precondition(options.includeHiddenAssets && options.includeAllBurstAssets)
    queries += 1
    return Fetch(items: library.filter { asset in
      guard let date = asset.creationDate else { return false }
      return options.predicate!.evaluate(with: ["mediaType":asset.mediaType.rawValue,"creationDate":date])
    })
  }
}
final class Importer {
  var allowed = true
  func checkPermission() throws { if !allowed { throw SyncFailure("permission") } }
__METHODS__
}
@main struct Regression {
  static func main() async throws {
    let importer = Importer(), file = URL(fileURLWithPath:"/no-original-required")
    var asset = RemoteAsset(account:"a",remoteID:"r",fileID:"f",filename:"same.jpg",bytes:10,
      width:2,height:2,mediaType:1,version:"v",isMotion:false,dateTakenMilliseconds:1_800_000_000_123)
    let date = asset.captureDate!
    func candidate(_ id: String, name: String = "SAME.JPG", time: Date? = nil,
      video: Bool = false, live: Bool = false) -> PHAsset {
      PHAsset(localIdentifier:id,creationDate:time ?? date,mediaType:video ? .video : .image,
        mediaSubtypes:live ? [.photoLive] : [],resources:[PHAssetResource(type:video ? .video : .photo,originalFilename:name)])
    }
    PHAsset.library = [candidate("wrong-time",time:date.addingTimeInterval(1)),
      candidate("wrong-type",video:true),candidate("wrong-name",name:"different.jpg"),candidate("same")]
    let same = try importer.findExistingByNameAndDate(asset:asset,file:file)
    precondition(same == "same")
    PHAsset.library.removeLast()
    let missing = try importer.findExistingByNameAndDate(asset:asset,file:file)
    precondition(missing == nil)
    asset.isMotion = true
    PHAsset.library = [candidate("static-other-extension",name:"same.heic"),candidate("converted-live",name:"same.heic",live:true)]
    let live = try importer.findExistingByNameAndDate(asset:asset,file:file)
    precondition(live == "converted-live")
    asset.isMotion = false; asset.mediaType = 3; asset.filename = "movie.mp4"
    PHAsset.library = [candidate("video",name:"MOVIE.MP4",video:true)]
    let video = try importer.findExistingByNameAndDate(asset:asset,file:file)
    precondition(video == "video")
    importer.allowed = false
    do { _ = try importer.findExistingByNameAndDate(asset:asset,file:file); preconditionFailure("permission ignored") } catch {}
    importer.allowed = true
    asset.dateTakenMilliseconds = nil
    do { _ = try importer.findExistingByNameAndDate(asset:asset,file:file); preconditionFailure("missing date matched") } catch {}
    print("PASS: production Photos lookup matches type/name/capture second, live filename mapping, permission and missing dates; no original download")
  }
}
'''.replace('__METHODS__', '\n'.join(extract(s) for s in ['  func lookupOptions(', '  func findExistingByNameAndDate(']))
with tempfile.TemporaryDirectory(prefix='ocloud-filename-date-') as folder:
    swift = Path(folder) / 'Regression.swift'
    binary = Path(folder) / 'regression'
    swift.write_text(harness)
    subprocess.run(['swiftc','-parse-as-library',*map(str,sorted((root / 'Sources/SyncCore').glob('*.swift'))),str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
