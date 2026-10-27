import Foundation
@main struct CodecWorkerTests {
 static func main() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("CodecWorkerFixtures-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
  defer { try? FileManager.default.removeItem(at:root) }
  var checks=0
  func check(_ value:Bool,_ label:String) { precondition(value,label);checks += 1 }
  let snapshot=EnvironmentSnapshot(rows:[EnvRow("GPU","synthetic fixture")],encoders:[],driver:EnvProbe.evaluateDriver(DriverEvidence()),decoderCaps:EnvProbe.DecCaps(),capturedAt:Date(timeIntervalSince1970:1_793_000_000))
  let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
  func json(_ event:CodecWorkerEvent) throws -> String { String(decoding:try encoder.encode(event),as:UTF8.self) }
  func quote(_ string:String) -> String { "'"+string.replacingOccurrences(of:"'",with:"'\\''")+"'" }
  func emit(_ string:String,newline:Bool=true) -> String { "printf '"+(newline ? "%s\\n":"%s")+"' "+quote(string)+"\n" }
  let environment=try json(CodecWorkerEvent(kind:"environment",environment:snapshot))
  var rows:[BenchRow]=[]
  for i in 0..<9 { rows.append(BenchRow(group:"fixture",item:"case-\(i)",mode:"synthetic",ok:false,fps:0,engine:"",detail:"fixture only",status:.notTested)) }
  let rowLines=try rows.map { try emit(json(CodecWorkerEvent(kind:"row",row:$0))) }.joined()
  let complete=try emit(json(CodecWorkerEvent(kind:"complete",cancelled:false)))
  func script(_ name:String,_ body:String) throws -> URL {
   let url=root.appendingPathComponent(name+".sh");try body.write(to:url,atomically:true,encoding:.utf8);return url
  }
  let cut=environment.index(environment.startIndex,offsetBy:environment.count/2)
  let fragmented=emit(String(environment[..<cut]),newline:false)+"sleep 0.02\n"+emit(String(environment[cut...]))
  let normal=try script("normal",fragmented+"printf '%s\\n' 'driver diagnostic fixture' >&2\n"+rowLines+complete)
  var received:[BenchRow]=[],diagnostics:[String]=[]
  let client=CodecWorkerClient(executableURL:URL(fileURLWithPath:"/bin/sh"),arguments:[normal.path])
  let result=client.run(onEvent:{if let row=$0.row {received.append(row)}},onDiagnostic:{diagnostics.append($0)})
  check(result.complete && !result.cancelled,"fragmented environment and nine rows complete")
  check(received.count==9,"all nine planned identities survive stream framing")
  check(diagnostics.contains("driver diagnostic fixture"),"driver stderr drained before completion")
  let crash=try script("crash",emit(environment)+(try emit(json(CodecWorkerEvent(kind:"row",row:rows[0]))))+"exit 7\n")
  var partial=0
  let crashed=CodecWorkerClient(executableURL:URL(fileURLWithPath:"/bin/sh"),arguments:[crash.path]).run(onEvent:{if $0.row != nil {partial += 1}},onDiagnostic:{_ in})
  check(!crashed.complete && crashed.exitCode==7 && partial==1,"abnormal exit preserves partial results")
  let missing=try script("missing",emit(environment)+rowLines)
  let incomplete=CodecWorkerClient(executableURL:URL(fileURLWithPath:"/bin/sh"),arguments:[missing.path]).run(onEvent:{_ in},onDiagnostic:{_ in})
  check(!incomplete.complete && incomplete.exitCode==0,"exit zero without end record is not success")
  let duplicate=try script("duplicate",emit(environment)+rowLines+(try emit(json(CodecWorkerEvent(kind:"row",row:rows[0]))))+complete)
  let duplicated=CodecWorkerClient(executableURL:URL(fileURLWithPath:"/bin/sh"),arguments:[duplicate.path]).run(onEvent:{_ in},onDiagnostic:{_ in})
  check(!duplicated.complete,"duplicate identity cannot masquerade as a complete run")
  let cancelledEnd=try emit(json(CodecWorkerEvent(kind:"complete",cancelled:true)))
  let cancellation=try script("cancel","on_cancel() {\n"+rowLines+cancelledEnd+"exit 0\n}\ntrap on_cancel INT\n"+emit(environment)+"while :; do sleep 0.1; done\n")
  let cancellable=CodecWorkerClient(executableURL:URL(fileURLWithPath:"/bin/sh"),arguments:[cancellation.path])
  cancellable.cancel()
  let cancelled=cancellable.run(onEvent:{_ in},onDiagnostic:{_ in})
  check(cancelled.complete && cancelled.cancelled,"cancellation queued before startup reaches ready child safely")
  print("Codec worker protocol fixtures: \(checks) checks passed (shell fixtures; no GPU calls)")
 }
}
