import Foundation
import Combine
struct Asset { let id:Int; let name:String }
struct ReleaseSummary:Identifiable { let id:Int }
struct ManagedRelease:Identifiable { let id:Int }
struct Permissions { var push:Bool? }
struct Repository { let permissions:Permissions? }
enum AccountStore { static var generation=UUID() }
extension Notification.Name { static let githubAccountChanged=Notification.Name("fixture-account-changed") }
enum RefreshFailure { static func isCancellation(_ error:Error)->Bool { error is CancellationError || (error as NSError).code == NSURLErrorCancelled } }
enum ReleaseManagementRules {
 static func canWrite(_ push:Bool?,session:Bool)->Bool { push == true && session }
 static func merged<T>(_ old:[T],_ new:[T])->[T] {old+new}
 static func more(count:Int,page:Int)->Bool {false}
}
@MainActor final class DownloadStore {
 static let shared=DownloadStore()
 var operations=0, cancelAuthorization=false, holdSave=false
 var save:CheckedContinuation<URL,Error>?
 var label="fixture-downloads"
 func requireAuthorization() async throws { if cancelAuthorization {throw CancellationError()} }
 func begin(){operations+=1}
 func end(){operations-=1}
 func persist(_ url:URL,session:UUID) async throws -> URL {
  if holdSave {return try await withCheckedThrowingContinuation {save=$0}}
  return url
 }
}
@MainActor final class GitHub {
 var isCurrentSession=true
 var callbacks:[(ReleaseDownloadProgress)->Void]=[]
 var pending:[CheckedContinuation<URL,Error>]=[]
 func downloadManagedAssetWithProgress(_ repo:String,asset:Asset,transfer:@escaping(ReleaseDownloadProgress)->Void) async throws ->URL {
  callbacks.append(transfer)
  return try await withCheckedThrowingContinuation {pending.append($0)}
 }
 func managedRepository(_ repo:String) async throws ->Repository {Repository(permissions:Permissions(push:true))}
 func managedReleases(_ repo:String,page:Int) async throws ->[ReleaseSummary] {[]}
 func managedLatestID(_ repo:String,refresh:Bool) async throws ->Int? {nil}
 func managedRelease(_ repo:String,id:Int) async throws ->ManagedRelease {ManagedRelease(id:id)}
 func managedAssets(_ repo:String,id:Int,page:Int) async throws ->[Asset] {[]}
}
// PRODUCTION_PROGRESS
// PRODUCTION_STATE

@main struct Run {
 @MainActor static func wait(_ test:()->Bool) async {while !test(){await Task.yield()}}
 static func temporary() throws ->URL {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let file=root.appendingPathComponent("asset.ipa");try Data([1,2,3]).write(to:file);return file
 }
 @MainActor static func main() async throws {
  precondition(ReleaseDownloadProgress(received:50,total:100).fraction==0.5)
  precondition(ReleaseDownloadProgress(received:50,total:0).fraction==nil)
  precondition(ReleaseDownloadProgress(received:50,total:-1).fraction==nil)
  precondition(ReleaseDownloadProgress(received:101,total:100).fraction==nil)
  var clock=0.0, updates:[ReleaseDownloadProgress]=[]
  let delegate=ReleaseAssetDownloadDelegate(update:{updates.append($0)},clock:{clock})
  delegate.receive(.init(received:1,total:-1));clock=0.01
  delegate.receive(.init(received:2,total:-1));precondition(updates.count==1)
  delegate.receive(.init(received:2,total:10));precondition(updates.count==2)
  clock=0.22;delegate.receive(.init(received:5,total:10));precondition(updates.count==3)
  delegate.receive(.init(received:10,total:10));delegate.receive(.init(received:10,total:10));precondition(updates.count==4)
  let api=GitHub(), state=ReleaseScreenState(api:api,repo:"owner/repo"), asset=Asset(id:1,name:"asset.ipa")
  let store=DownloadStore.shared
  state.download(asset);precondition(state.busy && state.assetDownload?.stage == .authorizing)
  let identity=state.assetDownload?.request
  state.download(asset);precondition(state.assetDownload?.request == identity)
  await wait{api.pending.count==1}
  api.callbacks[0](.init(received:25,total:100));await wait{state.assetDownload?.progress?.received==25}
  precondition(state.assetDownload?.stage == .downloading && api.callbacks.count==1)
  store.holdSave=true
  let file=try temporary();api.pending.removeFirst().resume(returning:file)
  await wait{store.save != nil};precondition(state.assetDownload?.stage == .saving && state.busy)
  api.callbacks[0](.init(received:1,total:-1));for _ in 0..<20 {await Task.yield()}
  precondition(state.assetDownload?.stage == .saving)
  store.save!.resume(returning:file);store.save=nil;store.holdSave=false
  await wait{!state.busy};precondition(state.assetDownload?.stage == .completed && store.operations==0)
  state.cancel();precondition(state.assetDownload?.stage == .completed)
  state.prepareImport();state.error="fixture picker failure"
  precondition(state.assetDownload==nil && !state.error.isEmpty)
  state.download(asset);await wait{api.pending.count==1}
  api.pending.removeFirst().resume(throwing:NSError(domain:"fixture",code:42));await wait{!state.busy}
  precondition(state.assetDownload?.stage == .failed && !state.error.isEmpty && store.operations==0)
  state.download(asset);await wait{api.pending.count==1};let old=api.callbacks.last!
  state.cancel();precondition(!state.busy && state.assetDownload?.stage == .cancelled)
  state.download(asset);await wait{api.pending.count==2};let newID=state.assetDownload?.request
  old(.init(received:90,total:100));api.pending.removeFirst().resume(throwing:CancellationError())
  for _ in 0..<20 {await Task.yield()}
  precondition(state.busy && state.assetDownload?.request==newID && state.assetDownload?.progress==nil)
  let last=api.callbacks.last!;AccountStore.generation=UUID();api.isCurrentSession=false
  NotificationCenter.default.post(name:.githubAccountChanged,object:nil)
  api.pending.removeFirst().resume(throwing:CancellationError());last(.init(received:99,total:100))
  await wait{store.operations==0};precondition(!state.busy && state.assetDownload?.stage == .cancelled && state.assets.isEmpty)
  let authorized=GitHub(), cancelled=ReleaseScreenState(api:authorized,repo:"owner/repo")
  store.cancelAuthorization=true;cancelled.download(asset);await wait{!cancelled.busy}
  precondition(cancelled.assetDownload?.stage == .cancelled && cancelled.error.isEmpty && authorized.callbacks.isEmpty)
  print("PASS actual release controller: immediate status, duplicate rejection, bytes/unknown size, save-before-success, failure/retry, stale callbacks, cancellation, account isolation and progress throttling")
 }
}
