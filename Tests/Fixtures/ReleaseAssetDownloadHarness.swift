import Foundation
import Combine
struct Asset:Identifiable { let id:Int; let name:String }
struct AppError:LocalizedError { let text:String; var errorDescription:String? {text} }
// PRODUCTION_RELEASE_MODELS
extension ReleaseSummary {
 init(id:Int) {self.init(id:id,tag_name:"v\(id)",name:nil,draft:false,prerelease:false,created_at:"2026-10-20T00:00:00Z",published_at:nil)}
}
extension ManagedRelease {
 init(id:Int) {self.init(id:id,tag_name:"v\(id)",name:nil,draft:false,prerelease:false,created_at:"2026-10-20T00:00:00Z",published_at:nil,updated_at:"2026-10-20T00:00:00Z",body:nil)}
}
struct Permissions { var push:Bool? }
struct Repository { let permissions:Permissions? }
enum AccountStore { static var generation=UUID() }
extension Notification.Name { static let githubAccountChanged=Notification.Name("fixture-account-changed") }
extension Notification.Name { static let releaseManagementChanged=Notification.Name("fixture-release-changed") }
enum RefreshFailure { static func isCancellation(_ error:Error)->Bool { error is CancellationError || (error as NSError).code == NSURLErrorCancelled } }
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
 var releaseRows:[ReleaseSummary]=[], requestedPages:[Int]=[]
 var holdReleases=false, heldReleases:CheckedContinuation<[ReleaseSummary],Error>?
 func invalidateManagedPresence(_ repo:String) {}
 func downloadManagedAssetWithProgress(_ repo:String,asset:Asset,transfer:@escaping(ReleaseDownloadProgress)->Void) async throws ->URL {
  callbacks.append(transfer)
  return try await withCheckedThrowingContinuation {pending.append($0)}
 }
 func managedRepository(_ repo:String) async throws ->Repository {Repository(permissions:Permissions(push:true))}
 func managedReleases(_ repo:String,page:Int) async throws ->[ReleaseSummary] {
  requestedPages.append(page)
  if holdReleases {return try await withCheckedThrowingContinuation {heldReleases=$0}}
  return Array(releaseRows.dropFirst((page-1)*ReleaseManagementRules.pageSize).prefix(ReleaseManagementRules.pageSize))
 }
 func managedLatestID(_ repo:String,refresh:Bool) async throws ->Int? {nil}
 func managedRelease(_ repo:String,id:Int) async throws ->ManagedRelease {ManagedRelease(id:id)}
 func managedAssets(_ repo:String,id:Int,page:Int) async throws ->[Asset] {[]}
}
// PRODUCTION_RELEASE_CHANGES
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
  let listAPI=GitHub(), list=ReleaseScreenState(api:listAPI,repo:"owner/repo")
  listAPI.releaseRows=(1...85).map {ReleaseSummary(id:$0)}
  for reset in [true,false,false] {list.list(reset:reset);await wait{!list.busy}}
  precondition(list.rows.count==60 && list.more && list.listLoaded)
  list.cancel() // The list remains alive while its detail is presented.
  let saved=ManagedRelease(id:40,tag_name:"renamed",name:"New title",draft:true,prerelease:false,created_at:"2026-10-20T00:00:00Z",published_at:nil,updated_at:"2026-10-25T00:00:00Z",body:nil)
  list.latestID=40
  ReleaseManagementChanges.changed(api:listAPI,repo:"OWNER/REPO",release:saved)
  precondition(list.rows[39].name=="New title" && list.rows[39].draft && list.rows[39].id==40 && list.latestID==nil && list.rows.count==60)
  let order=list.rows.map(\.id)
  ReleaseManagementChanges.changed(api:listAPI,repo:"other/repo",deletedReleaseID:40)
  NotificationCenter.default.post(name:.releaseManagementChanged,object:nil,userInfo:["repo":"owner/repo","generation":UUID(),"deletedReleaseID":40])
  precondition(list.rows.map(\.id)==order)
  for id in 1...25 {
   listAPI.releaseRows.removeAll {$0.id==id}
   ReleaseManagementChanges.changed(api:listAPI,repo:"owner/repo",deletedReleaseID:id)
  }
  precondition(list.rows.map(\.id)==Array(26...60) && list.rows[14].name=="New title")
  list.list(reset:false);await wait{!list.busy}
  precondition(listAPI.requestedPages.last==2 && list.rows.map(\.id)==Array(26...65))
  while list.more {list.list(reset:false);await wait{!list.busy}}
  precondition(list.rows.map(\.id)==Array(26...85))
  for id in 26...85 {ReleaseManagementChanges.changed(api:listAPI,repo:"owner/repo",deletedReleaseID:id)}
  precondition(list.rows.isEmpty && list.listLoaded && !list.more)
  let calls=listAPI.requestedPages.count
  precondition(calls==6) // Three initial pages, then pages 2, 3 and the empty page 4.
  let delayedAPI=GitHub(), delayed=ReleaseScreenState(api:delayedAPI,repo:"owner/repo")
  delayedAPI.releaseRows=(1...20).map {ReleaseSummary(id:$0)}
  delayed.list(reset:true);await wait{!delayed.busy}
  delayedAPI.holdReleases=true;delayed.list(reset:false);await wait{delayedAPI.heldReleases != nil}
  ReleaseManagementChanges.changed(api:delayedAPI,repo:"owner/repo",deletedReleaseID:1)
  precondition(!delayed.busy && delayed.rows.map(\.id)==Array(2...20))
  delayedAPI.heldReleases!.resume(returning:[ReleaseSummary(id:1),ReleaseSummary(id:21)])
  delayedAPI.heldReleases=nil;delayedAPI.holdReleases=false
  for _ in 0..<20 {await Task.yield()}
  precondition(delayed.rows.map(\.id)==Array(2...20))
  delayed.list(reset:false);await wait{!delayed.busy} // Cached boundary still contains deleted ID 1.
  precondition(delayedAPI.requestedPages.last==1 && delayed.rows.map(\.id)==Array(2...20))
  delayedAPI.releaseRows=(2...21).map {ReleaseSummary(id:$0)}
  delayed.list(reset:false);await wait{!delayed.busy}
  precondition(delayedAPI.requestedPages.last==1 && delayed.rows.map(\.id)==Array(2...21))
  delayedAPI.releaseRows=[ReleaseSummary(id:1)]
  delayed.list(reset:true);await wait{!delayed.busy}
  precondition(delayed.rows.map(\.id)==[1]) // Explicit refresh clears confirmed deletion IDs.
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
  print("PASS actual release controller: in-place edits/deletions, page-boundary recovery, session gates, empty loaded list, download status/progress, save-before-success, retry/cancellation and stale callbacks")
 }
}
