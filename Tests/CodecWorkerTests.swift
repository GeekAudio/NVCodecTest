import Foundation

@main struct CodecWorkerTests {
 static func main() throws {
  var checks=0
  func check(_ value:Bool,_ label:String) { precondition(value,label);checks += 1 }
  func rejects(_ body:() throws -> Void,_ label:String) {
   do { try body(); preconditionFailure(label) } catch { checks += 1 }
  }

  let ids=CodecTestPlan.allCaseIDs
  check(ids.count==9 && Set(ids).count==9,"canonical plan has nine unique test identities")
  check(try CodecTestPlan.validate(nil)==ids,"no selection preserves the full matrix")
  let shuffled=[ids[8],ids[2],ids[6]]
  check(try CodecTestPlan.validate(shuffled)==[ids[2],ids[6],ids[8]],"subset is normalized to grid order")
  check(try CodecTestPlan.arguments(for:Set(shuffled))==["--case-id",ids[2],"--case-id",ids[6],"--case-id",ids[8]],"selection args are canonical and repeatable")
  check(try CodecTestPlan.selection(in:["--codec-worker"]+CodecTestPlan.arguments(for:Set(shuffled)))==[ids[2],ids[6],ids[8]],"worker receives selected IDs")
  check(try CodecTestPlan.selection(in:["--codec-worker"])==ids,"legacy worker arguments default to all nine")
  rejects({ _ = try CodecTestPlan.validate([]) },"empty selection must fail")
  rejects({ _ = try CodecTestPlan.validate([ids[0],ids[0]]) },"duplicate IDs must fail")
  rejects({ _ = try CodecTestPlan.validate(["unknown|case|id"]) },"unknown IDs must fail")
  rejects({ _ = try CodecTestPlan.selection(in:["--codec-worker","--case-id"]) },"missing ID must fail")
  rejects({ _ = try CodecTestPlan.selection(in:["--codec-worker","--case-id=\(ids[0])"]) },"equals form must fail explicitly")
  rejects({ _ = try CodecTestPlan.selection(in:["--codec-worker","--case-id","bad-id"]) },"unknown worker ID must fail")
  rejects({ _ = try CodecTestPlan.selection(in:["--codec-worker","--case-id",ids[0],"--case-id",ids[0]]) },"duplicate worker ID must fail")

  let root=FileManager.default.temporaryDirectory.appendingPathComponent("CodecWorkerFixtures-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
  defer { try? FileManager.default.removeItem(at:root) }
  let snapshot=EnvironmentSnapshot(rows:[EnvRow("GPU","synthetic fixture")],encoders:[],driver:EnvProbe.evaluateDriver(DriverEvidence()),decoderCaps:EnvProbe.DecCaps(),capturedAt:Date(timeIntervalSince1970:1_793_000_000))
  let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
  func json(_ event:CodecWorkerEvent) throws -> String { String(decoding:try encoder.encode(event),as:UTF8.self) }
  func quote(_ string:String) -> String { "'"+string.replacingOccurrences(of:"'",with:"'\\''" )+"'" }
  func emit(_ string:String,newline:Bool=true) -> String { "printf '"+(newline ? "%s\\n":"%s")+"' "+quote(string)+"\n" }
  let environment=try json(CodecWorkerEvent(kind:"environment",environment:snapshot))
  let rows=CodecTestPlan.cases.map { item in
   BenchRow(group:item.group,item:item.item,mode:item.mode,ok:false,fps:0,engine:"",detail:"fixture only",status:.notTested)
  }
  let rowLines=try rows.map { try emit(json(CodecWorkerEvent(kind:"row",row:$0))) }.joined()
  let complete=try emit(json(CodecWorkerEvent(kind:"complete",cancelled:false)))
  func script(_ name:String,_ body:String) throws -> URL {
   let url=root.appendingPathComponent(name+".sh");try body.write(to:url,atomically:true,encoding:.utf8);return url
  }
  func client(_ url:URL,expected:[String]?=nil)->CodecWorkerClient {
   CodecWorkerClient(executableURL:URL(fileURLWithPath:"/bin/sh"),arguments:[url.path],expectedCaseIDs:expected)
  }
  func linesFor(_ selected:[String]) throws -> String {
   try selected.map { id in try emit(json(CodecWorkerEvent(kind:"row",row:rows.first{$0.id==id}!))) }.joined()
  }

  let cut=environment.index(environment.startIndex,offsetBy:environment.count/2)
  let fragmented=emit(String(environment[..<cut]),newline:false)+"sleep 0.02\n"+emit(String(environment[cut...]))
  let normal=try script("normal",fragmented+"printf '%s\\n' 'driver diagnostic fixture' >&2\n"+rowLines+complete)
  var received:[BenchRow]=[],diagnostics:[String]=[]
  let result=client(normal).run(onEvent:{if let row=$0.row {received.append(row)}},onDiagnostic:{diagnostics.append($0)})
  check(result.complete && !result.cancelled,"fragmented environment and nine canonical rows complete")
  check(received.map(\.id)==ids,"full worker preserves canonical row order")
  check(diagnostics.contains("driver diagnostic fixture"),"driver stderr drains before completion")

  let selected=[ids[2],ids[6]]
  let subsetScript=try script("subset",emit(environment)+(try linesFor(Array(selected.reversed())))+complete)
  let subset=client(subsetScript,expected:selected).run(onEvent:{_ in},onDiagnostic:{_ in})
  check(subset.complete,"a selected subset completes with exactly its identities in any stream order")
  let missingScript=try script("missing-row",emit(environment)+(try linesFor([selected[0]]))+complete)
  check(!client(missingScript,expected:selected).run(onEvent:{_ in},onDiagnostic:{_ in}).complete,"omitted selected result cannot complete")
  let wrongScript=try script("wrong-row",emit(environment)+(try linesFor([ids[1]]))+complete)
  check(!client(wrongScript,expected:[ids[0]]).run(onEvent:{_ in},onDiagnostic:{_ in}).complete,"unselected identity cannot satisfy requested case")

  let crash=try script("crash",emit(environment)+(try linesFor([ids[0]]))+"exit 7\n")
  var partial=0
  let crashed=client(crash,expected:[ids[0]]).run(onEvent:{if $0.row != nil {partial += 1}},onDiagnostic:{_ in})
  check(!crashed.complete && crashed.exitCode==7 && partial==1,"abnormal exit preserves partial rows")
  let missing=try script("missing",emit(environment)+(try linesFor([ids[0]])))
  let incomplete=client(missing,expected:[ids[0]]).run(onEvent:{_ in},onDiagnostic:{_ in})
  check(!incomplete.complete && incomplete.exitCode==0,"exit zero without end record is not success")
  let duplicate=try script("duplicate",emit(environment)+rowLines+(try emit(json(CodecWorkerEvent(kind:"row",row:rows[0]))))+complete)
  check(!client(duplicate).run(onEvent:{_ in},onDiagnostic:{_ in}).complete,"duplicate identity cannot masquerade as complete")

  let cancelledEnd=try emit(json(CodecWorkerEvent(kind:"complete",cancelled:true)))
  let cancellation=try script("cancel","on_cancel() {\n"+(try linesFor(selected))+cancelledEnd+"exit 0\n}\ntrap on_cancel INT\n"+emit(environment)+"while :; do sleep 0.1; done\n")
  let cancellable=client(cancellation,expected:selected)
  cancellable.cancel()
  let cancelled=cancellable.run(onEvent:{_ in},onDiagnostic:{_ in})
  check(cancelled.complete && cancelled.cancelled,"queued cancellation retains only the selected result IDs")
  print("Codec worker and selection fixtures: \(checks) checks passed (shell fixtures; no GPU calls)")
 }
}
