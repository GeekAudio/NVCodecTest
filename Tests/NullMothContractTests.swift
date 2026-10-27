import Foundation
@main struct NullMothContractTests {
 static func main() {
  var count=0
  func check(_ value:Bool,_ label:String) { precondition(value,label);count += 1 }
  let cases:[(String?,Bool,String?)] = [
   ("Turing",false,"tu10x"),("Turing GTX 16",false,"tu10x"),("Ampere",false,"ga10x"),
   ("Blackwell",false,"base"),("Ada",false,nil),("Future GPU",false,nil),
   (nil,false,nil),(nil,true,"base"),("Turingish",false,nil),
   ("Ampere workstation",false,"ga10x")
  ]
  for (name,fallback,suffix) in cases {
   let modules=NullMothContract.encoderModules(generation:name,blackwellFallback:fallback)
   if let suffix {
    let expected = suffix == "base" ? ["libnvenc_h264.dylib","libnvenc_hevc.dylib"] : ["libnvenc_h264_\(suffix).dylib","libnvenc_hevc_\(suffix).dylib"]
    check(modules == expected,"source selection \(name ?? "missing")")
   } else { check(modules.isEmpty,"unknown branch stays unconfirmed \(name ?? "missing")") }
  }
  check(NullMothContract.isNVIDIADisplay(vendor:0x10de,classCode:0x030000),"NVIDIA display controller")
  check(NullMothContract.isNVIDIADisplay(vendor:0x10de,classCode:0x030200),"NVIDIA headless 3D controller")
  check(!NullMothContract.isNVIDIADisplay(vendor:0x10de,classCode:0x040300),"NVIDIA audio is not a GPU")
  check(!NullMothContract.isNVIDIADisplay(vendor:0x10de,classCode:0x0c0330),"NVIDIA USB is not a GPU")
  check(!NullMothContract.isNVIDIADisplay(vendor:0x1002,classCode:0x030000),"AMD is not NVIDIA")
  check(!NullMothContract.isNVIDIADisplay(vendor:0x8086,classCode:0x030000),"Intel is not NVIDIA")
  check(NullMothContract.decoderModules(blackwell:false)[0] == "libnvdec_h264_t2d.dylib","classic H264 path")
  check(NullMothContract.decoderModules(blackwell:true)[0] == "libnvdec_h264.dylib","Blackwell H264 path")
  check(EnvProbe.pciNumber(Data([0xde,0x10,0,0])) == 0x10de,"little-endian PCI vendor")
  check(EnvProbe.pciNumber(NSNumber(value:0x030200)) == 0x030200,"numeric registry property")
  check(EnvProbe.pciNumber(Data()) == nil,"missing PCI evidence stays unknown")
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("CodecFileFixtures-"+UUID().uuidString)
  try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
  defer {try? FileManager.default.removeItem(at:root)}
  try! Data("abc".utf8).write(to:root.appendingPathComponent("matching"))
  try! Data("changed".utf8).write(to:root.appendingPathComponent("different"))
  let presence=NullMothContract.checkFiles(root:root,names:["matching","different","missing"])
  check(presence.present==2,"both files count as present regardless of differing contents")
  check(presence.missing==1,"missing component remains explicit")
  check(presence.details.contains("different：存在"),"changed file is not rejected by content verification")
  print("NullMoth source-contract fixtures: \(count) checks passed (synthetic profiles; no physical GPU validation)")
 }
}
