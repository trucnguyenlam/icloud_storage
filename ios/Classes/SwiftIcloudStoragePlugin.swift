import Flutter
import UIKit

public class SwiftIcloudStoragePlugin: NSObject, FlutterPlugin {
  var listStreamHandler: StreamHandler?
  var messenger: FlutterBinaryMessenger?
  var streamHandlers: [String: StreamHandler] = [:]
  let querySearchScopes = [
    NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope,
  ]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let channel = FlutterMethodChannel(name: "icloud_storage", binaryMessenger: messenger)
    let instance = SwiftIcloudStoragePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.messenger = messenger
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listChildren":
      listChildren(call, result)
    case "getFile":
      getFile(call, result)
    case "fastDownload":
      fastDownload(call, result)
    case "isReady":
      isReady(call, result)
    case "gather":
      gather(call, result)
    case "upload":
      upload(call, result)
    case "download":
      download(call, result)
    case "delete":
      delete(call, result)
    case "move":
      move(call, result)
    case "createEventChannel":
      createEventChannel(call, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func extractRelativePath(_ fileURL: URL, _ containerURL: URL) -> String {
    var relativePath = String(fileURL.path.dropFirst(containerURL.path.count))
    if relativePath.starts(with: "/") {
      relativePath = String(relativePath.dropFirst())
    }
    return relativePath
  }

  private func listChildrenOfDirectoryInICloud(at directoryURL: URL, container containerURL: URL)
    -> [[String: Any?]]
  {
    var fileMaps: [[String: Any?]] = []

    let fileCoordinator = NSFileCoordinator()
    fileCoordinator.coordinate(readingItemAt: directoryURL, options: [], error: nil) {
      (directoryURL) in
      do {
        let fileURLs = try FileManager.default.contentsOfDirectory(
          at: directoryURL, includingPropertiesForKeys: nil, options: [])
        for nFileURL in fileURLs {
          let fileURL = canonicalURL(nFileURL)
          let map: [String: Any?] = [
            "relativePath": extractRelativePath(fileURL, containerURL),
            "name": fileURL.lastPathComponent,
            "realPath": fileURL.path,
            "isFolder": fileURL.hasDirectoryPath,
          ]
          fileMaps.append(map)
        }
      } catch {
        DebugHelper.log("Error listing files: \(error)")
      }
    }
    return fileMaps
  }

  private func listChildren(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let containerId = args["containerId"] as? String,
      let path = args["path"] as? String
    else {
      result(argumentError)
      return
    }

    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
    else {
      result(containerError)
      return
    }

    var appendPath: String = "Documents"
    if path != nil && !path.isEmpty {
      appendPath = path
    }

    let directoryURL = containerURL.appendingPathComponent(appendPath)
    DebugHelper.log("directoryURL: \(directoryURL.path)")

    let childrenURLs = listChildrenOfDirectoryInICloud(at: directoryURL, container: containerURL)
    result(childrenURLs)
  }

  private func getFile(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let containerId = args["containerId"] as? String,
      let path = args["path"] as? String
    else {
      result(argumentError)
      return
    }

    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
    else {
      result(containerError)
      return
    }

    var appendPath: String = "Documents"
    if path != nil && !path.isEmpty {
      appendPath = path
    }

    let fileURL = containerURL.appendingPathComponent(appendPath)
    DebugHelper.log("fileURL: \(fileURL.path)")

    var lastModifiedDate: Date?
    var creationDate: Date?
    var fileSize: Int?
    let fileCoordinator = NSFileCoordinator()
    fileCoordinator.coordinate(readingItemAt: fileURL, options: [], error: nil) { (newURL) in
      do {
        let fileExists = FileManager.default.fileExists(atPath: newURL.path)
        if !fileExists {
          result([String: Any?]())
          return
        }
        let attributes = try newURL.resourceValues(forKeys: [
          .contentModificationDateKey, .creationDateKey, .fileSizeKey,
        ])
        lastModifiedDate = attributes.contentModificationDate
        creationDate = attributes.creationDate
        fileSize = attributes.fileSize
      } catch {
        DebugHelper.log("Error retrieving file attributes: \(error)")
        result(nativeCodeError(error))
        return
      }
    }
    let map: [String: Any?] = [
      "relativePath": extractRelativePath(fileURL, containerURL),
      "name": fileURL.lastPathComponent,
      "realPath": fileURL.path,
      "isFolder": fileURL.hasDirectoryPath,
      "sizeInBytes": fileSize,
      "creationDate": creationDate?.timeIntervalSince1970,
      "contentChangeDate": lastModifiedDate?.timeIntervalSince1970,
    ]
    result(map)
  }

  /// iCloud file that has not been downloaded will be in this form .name.icloud
  /// - Parameter url: url to be canonicalised
  /// - Returns: canonical url
  private func canonicalURL(_ url: URL) -> URL {
    let prefix = "."
    let suffix = ".icloud"
    var fileName = url.lastPathComponent
    if fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) {
      fileName.removeFirst(prefix.count)
      fileName.removeLast(suffix.count)
      var result = url.deletingLastPathComponent()
      result.appendPathComponent(fileName)
      return result
    } else {
      return url
    }
  }

  private func uncanonicalURL(_ url: URL) -> URL {
    let prefix = "."
    let suffix = ".icloud"
    let newFilename = prefix + url.lastPathComponent + suffix
    var result = url.deletingLastPathComponent()
    result.appendPathComponent(newFilename)
    return result
  }

  private func isOnCloud(_ url: URL) -> Bool {
    let prefix = "."
    let suffix = ".icloud"
    var fileName = url.lastPathComponent
    return fileName.hasPrefix(prefix) && fileName.hasSuffix(suffix)
  }

  private func fastDownload(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let containerId = args["containerId"] as? String,
      let relativePath = args["relativePath"] as? String,
      let localFilePath = args["localFilePath"] as? String,
      let eventChannelName = args["eventChannelName"] as? String
    else {
      result(argumentError)
      return
    }

    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
    else {
      result(containerError)
      return
    }

    let fileURL = containerURL.appendingPathComponent(relativePath)

    // Workaround: initiate .icloud file download to make the file available
    let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
    if !fileExists {
      let nSessionConfig = URLSessionConfiguration.default
      let nSession = URLSession(configuration: nSessionConfig)
      let nDownloadTask = nSession.downloadTask(with: uncanonicalURL(fileURL))
      nDownloadTask.resume()
      nDownloadTask.cancel()
    }

    let downloadStreamHandler: StreamHandler? = self.streamHandlers.removeValue(
      forKey: eventChannelName)
    let fileCoordinator = NSFileCoordinator()
    fileCoordinator.coordinate(readingItemAt: fileURL, options: [], error: nil) {
      [weak self] (newURL) in
      guard let self = self else { return }
      let fileExists = FileManager.default.fileExists(atPath: newURL.path)
      if !fileExists {
        let error = FlutterError(
          code: "E_NAT", message: "Native Code Error", details: "\(relativePath) does not exist")
        downloadStreamHandler?.setEvent(error)
        result(error)
        return
      }

      let destinationURL = URL(fileURLWithPath: localFilePath)
      let sessionConfig = URLSessionConfiguration.default
      let session = URLSession(
        configuration: sessionConfig,
        delegate: DownloadDelegate(
          destinationURL: destinationURL, streamHandler: downloadStreamHandler),
        delegateQueue: nil)
      let downloadTask = session.downloadTask(with: newURL)
      downloadStreamHandler?.onCancelHandler = { [self] in
        downloadTask.cancel()
      }
      downloadTask.resume()
    }
    result(nil)
  }

  private func gather(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let containerId = args["containerId"] as? String,
      let eventChannelName = args["eventChannelName"] as? String
    else {
      result(argumentError)
      return
    }

    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
    else {
      result(containerError)
      return
    }
    DebugHelper.log("containerURL: \(containerURL.path)")

    let query = NSMetadataQuery.init()
    query.operationQueue = .main
    query.searchScopes = querySearchScopes
    query.predicate = NSPredicate(
      format: "%K beginswith %@", NSMetadataItemPathKey, containerURL.path)
    addGatherFilesObservers(
      query: query, containerURL: containerURL, eventChannelName: eventChannelName, result: result)

    if !eventChannelName.isEmpty {
      let streamHandler = self.streamHandlers[eventChannelName]!
      streamHandler.onCancelHandler = { [self] in
        removeObservers(query)
        query.stop()
        removeStreamHandler(eventChannelName)
      }
    }
    query.start()
  }

  private func addGatherFilesObservers(
    query: NSMetadataQuery, containerURL: URL, eventChannelName: String,
    result: @escaping FlutterResult
  ) {
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query,
      queue: query.operationQueue
    ) {
      [self] (notification) in
      let files = mapFileAttributesFromQuery(query: query, containerURL: containerURL)
      removeObservers(query)
      if eventChannelName.isEmpty { query.stop() }
      result(files)
    }

    if !eventChannelName.isEmpty {
      NotificationCenter.default.addObserver(
        forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: query,
        queue: query.operationQueue
      ) {
        [self] (notification) in
        let files = mapFileAttributesFromQuery(query: query, containerURL: containerURL)
        let streamHandler = self.streamHandlers[eventChannelName]!
        streamHandler.setEvent(files)
      }
    }
  }

  private func mapFileAttributesFromQuery(query: NSMetadataQuery, containerURL: URL) -> [[String:
    Any?]]
  {
    var fileMaps: [[String: Any?]] = []
    for item in query.results {
      guard let fileItem = item as? NSMetadataItem else { continue }
      guard let fileURL = fileItem.value(forAttribute: NSMetadataItemURLKey) as? URL else {
        continue
      }
      if fileURL.absoluteString.last == "/" { continue }

      let map: [String: Any?] = [
        "relativePath": String(fileURL.absoluteString.dropFirst(containerURL.absoluteString.count)),
        "sizeInBytes": fileItem.value(forAttribute: NSMetadataItemFSSizeKey),
        "creationDate": (fileItem.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)?
          .timeIntervalSince1970,
        "contentChangeDate":
          (fileItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)?
          .timeIntervalSince1970,
        "hasUnresolvedConflicts": fileItem.value(
          forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey),
        "downloadStatus": fileItem.value(
          forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey),
        "isDownloading": fileItem.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey),
        "isUploaded": fileItem.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey),
        "isUploading": fileItem.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey),
      ]
      fileMaps.append(map)
    }
    return fileMaps
  }

  private func isReady(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let containerId = args["containerId"] as? String
    else {
      result(argumentError)
      return
    }

    if FileManager.default.ubiquityIdentityToken == nil {
      result(FlutterError(code: "E_NOTSIGNIN", message: "Not signed in to iCloud", details: nil))
      return
    }

    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
    else {
      result(containerError)
      return
    }
    DebugHelper.log("containerURL: \(containerURL.path)")

    let rootDir = containerURL.appendingPathComponent("Documents")
    if !FileManager.default.fileExists(atPath: rootDir.path) {
      result(
        FlutterError(code: "E_NOTEXIST", message: "Documents directory not exist", details: nil))
      return
    }

    result(true)
  }

  private func upload(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let containerId = args["containerId"] as? String,
      let localFilePath = args["localFilePath"] as? String,
      let cloudFileName = args["cloudFileName"] as? String,
      let eventChannelName = args["eventChannelName"] as? String
    else {
      result(argumentError)
      return
    }

    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
    else {
      result(containerError)
      return
    }
    DebugHelper.log("containerURL: \(containerURL.path)")

    let cloudFileURL = containerURL.appendingPathComponent(cloudFileName)
    let localFileURL = URL(fileURLWithPath: localFilePath)

    do {
      if FileManager.default.fileExists(atPath: cloudFileURL.path) {
        try FileManager.default.removeItem(at: cloudFileURL)
      } else {
        let cloudFileDirURL = cloudFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: cloudFileDirURL.path) {
          try FileManager.default.createDirectory(
            at: cloudFileDirURL, withIntermediateDirectories: true, attributes: nil)
        }
      }
      try FileManager.default.copyItem(at: localFileURL, to: cloudFileURL)
    } catch {
      result(nativeCodeError(error))
    }

    if !eventChannelName.isEmpty {
      let query = NSMetadataQuery.init()
      query.operationQueue = .main
      query.searchScopes = querySearchScopes
      query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, cloudFileURL.path)

      let uploadStreamHandler = self.streamHandlers[eventChannelName]!
      uploadStreamHandler.onCancelHandler = { [self] in
        removeObservers(query)
        query.stop()
        removeStreamHandler(eventChannelName)
      }
      addUploadObservers(query: query, eventChannelName: eventChannelName)

      query.start()
    }

    result(nil)
  }

  private func addUploadObservers(query: NSMetadataQuery, eventChannelName: String) {
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query,
      queue: query.operationQueue
    ) { [self] (notification) in
      onUploadQueryNotification(query: query, eventChannelName: eventChannelName)
    }

    NotificationCenter.default.addObserver(
      forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: query,
      queue: query.operationQueue
    ) { [self] (notification) in
      onUploadQueryNotification(query: query, eventChannelName: eventChannelName)
    }
  }

  private func onUploadQueryNotification(query: NSMetadataQuery, eventChannelName: String) {
    if query.results.count == 0 {
      return
    }

    guard let fileItem = query.results.first as? NSMetadataItem else { return }
    guard let fileURL = fileItem.value(forAttribute: NSMetadataItemURLKey) as? URL else { return }
    guard
      let fileURLValues = try? fileURL.resourceValues(forKeys: [.ubiquitousItemUploadingErrorKey])
    else { return }
    guard let streamHandler = self.streamHandlers[eventChannelName] else { return }

    if let error = fileURLValues.ubiquitousItemUploadingError {
      streamHandler.setEvent(nativeCodeError(error))
      return
    }

    if let progress = fileItem.value(forAttribute: NSMetadataUbiquitousItemPercentUploadedKey)
      as? Double
    {
      streamHandler.setEvent(progress)
      if progress >= 100 {
        streamHandler.setEvent(FlutterEndOfEventStream)
        removeStreamHandler(eventChannelName)
      }
    }
  }

  private func download(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let containerId = args["containerId"] as? String,
      let cloudFileName = args["cloudFileName"] as? String,
      let localFilePath = args["localFilePath"] as? String,
      let eventChannelName = args["eventChannelName"] as? String
    else {
      result(argumentError)
      return
    }

    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
    else {
      result(containerError)
      return
    }
    DebugHelper.log("containerURL: \(containerURL.path)")

    let cloudFileURL = containerURL.appendingPathComponent(cloudFileName)
    do {
      try FileManager.default.startDownloadingUbiquitousItem(at: cloudFileURL)
    } catch {
      result(nativeCodeError(error))
    }

    let query = NSMetadataQuery.init()
    query.operationQueue = .main
    query.searchScopes = querySearchScopes
    query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, cloudFileURL.path)

    let downloadStreamHandler = self.streamHandlers[eventChannelName]
    downloadStreamHandler?.onCancelHandler = { [self] in
      removeObservers(query)
      query.stop()
      removeStreamHandler(eventChannelName)
    }

    let localFileURL = URL(fileURLWithPath: localFilePath)
    addDownloadObservers(
      query: query, cloudFileURL: cloudFileURL, localFileURL: localFileURL,
      eventChannelName: eventChannelName)

    query.start()
    result(nil)
  }

  private func addDownloadObservers(
    query: NSMetadataQuery, cloudFileURL: URL, localFileURL: URL, eventChannelName: String
  ) {
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query,
      queue: query.operationQueue
    ) { [self] (notification) in
      onDownloadQueryNotification(
        query: query, cloudFileURL: cloudFileURL, localFileURL: localFileURL,
        eventChannelName: eventChannelName)
    }

    NotificationCenter.default.addObserver(
      forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: query,
      queue: query.operationQueue
    ) { [self] (notification) in
      onDownloadQueryNotification(
        query: query, cloudFileURL: cloudFileURL, localFileURL: localFileURL,
        eventChannelName: eventChannelName)
    }
  }

  private func onDownloadQueryNotification(
    query: NSMetadataQuery, cloudFileURL: URL, localFileURL: URL, eventChannelName: String
  ) {
    if query.results.count == 0 {
      return
    }

    guard let fileItem = query.results.first as? NSMetadataItem else { return }
    guard let fileURL = fileItem.value(forAttribute: NSMetadataItemURLKey) as? URL else { return }
    guard
      let fileURLValues = try? fileURL.resourceValues(forKeys: [
        .ubiquitousItemDownloadingErrorKey, .ubiquitousItemDownloadingStatusKey,
      ])
    else { return }
    let streamHandler: StreamHandler? = self.streamHandlers[eventChannelName]

    if let error = fileURLValues.ubiquitousItemDownloadingError {
      streamHandler?.setEvent(nativeCodeError(error))
      return
    }

    if let progress = fileItem.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey)
      as? Double
    {
      streamHandler?.setEvent(progress)
    }

    if fileURLValues.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
      do {
        try moveCloudFile(at: cloudFileURL, to: localFileURL)
        streamHandler?.setEvent(FlutterEndOfEventStream)
        removeStreamHandler(eventChannelName)
      } catch {
        streamHandler?.setEvent(nativeCodeError(error))
      }
    }
  }

  private func moveCloudFile(at: URL, to: URL) throws {
    do {
      if FileManager.default.fileExists(atPath: to.path) {
        try FileManager.default.removeItem(at: to)
      }
      try FileManager.default.moveItem(at: at, to: to)
    } catch {
      throw error
    }
  }

  private func delete(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let containerId = args["containerId"] as? String,
      let cloudFileName = args["cloudFileName"] as? String
    else {
      result(argumentError)
      return
    }

    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
    else {
      result(containerError)
      return
    }
    DebugHelper.log("containerURL: \(containerURL.path)")

    let fileURL = containerURL.appendingPathComponent(cloudFileName)
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    fileCoordinator.coordinate(
      writingItemAt: fileURL, options: NSFileCoordinator.WritingOptions.forDeleting, error: nil
    ) {
      writingURL in
      do {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: writingURL.path, isDirectory: &isDir) {
          result(fileNotFoundError)
          return
        }
        try FileManager.default.removeItem(at: writingURL)
        result(nil)
      } catch {
        DebugHelper.log("error: \(error.localizedDescription)")
        result(nativeCodeError(error))
      }
    }
  }

  private func move(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let containerId = args["containerId"] as? String,
      let atRelativePath = args["atRelativePath"] as? String,
      let toRelativePath = args["toRelativePath"] as? String
    else {
      result(argumentError)
      return
    }

    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
    else {
      result(containerError)
      return
    }
    DebugHelper.log("containerURL: \(containerURL.path)")

    let atURL = containerURL.appendingPathComponent(atRelativePath)
    let toURL = containerURL.appendingPathComponent(toRelativePath)
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    fileCoordinator.coordinate(
      writingItemAt: atURL, options: NSFileCoordinator.WritingOptions.forMoving,
      writingItemAt: toURL, options: NSFileCoordinator.WritingOptions.forReplacing, error: nil
    ) {
      atWritingURL, toWritingURL in
      do {
        let toDirURL = toWritingURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: toDirURL.path) {
          try FileManager.default.createDirectory(
            at: toDirURL, withIntermediateDirectories: true, attributes: nil)
        }
        try FileManager.default.moveItem(at: atWritingURL, to: toWritingURL)
        result(nil)
      } catch {
        DebugHelper.log("error: \(error.localizedDescription)")
        result(nativeCodeError(error))
      }
    }
  }

  private func removeObservers(_ query: NSMetadataQuery) {
    NotificationCenter.default.removeObserver(
      self, name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query)
    NotificationCenter.default.removeObserver(
      self, name: NSNotification.Name.NSMetadataQueryDidUpdate, object: query)
  }

  private func createEventChannel(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let eventChannelName = args["eventChannelName"] as? String
    else {
      result(argumentError)
      return
    }

    let streamHandler = StreamHandler()
    let eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: self.messenger!)
    eventChannel.setStreamHandler(streamHandler)
    self.streamHandlers[eventChannelName] = streamHandler

    result(nil)
  }

  private func removeStreamHandler(_ eventChannelName: String) {
    self.streamHandlers[eventChannelName] = nil
  }

  let argumentError = FlutterError(code: "E_ARG", message: "Invalid Arguments", details: nil)
  let containerError = FlutterError(
    code: "E_CTR",
    message: "Invalid containerId, or user is not signed in, or user disabled iCloud permission",
    details: nil)
  let fileNotFoundError = FlutterError(
    code: "E_FNF", message: "The file does not exist", details: nil)

  private func nativeCodeError(_ error: Error) -> FlutterError {
    return FlutterError(code: "E_NAT", message: "Native Code Error", details: "\(error)")
  }
}

class StreamHandler: NSObject, FlutterStreamHandler {
  private var _eventSink: FlutterEventSink?
  var onCancelHandler: (() -> Void)?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    _eventSink = events
    DebugHelper.log("on listen")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancelHandler?()
    _eventSink = nil
    DebugHelper.log("on cancel")
    return nil
  }

  func setEvent(_ data: Any) {
    _eventSink?(data)
  }
}

class DebugHelper {
  public static func log(_ message: String) {
    #if DEBUG
      print(message)
    #endif
  }
}

class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
  let destinationURL: URL
  let streamHandler: StreamHandler?

  init(destinationURL: URL, streamHandler: StreamHandler?) {
    self.destinationURL = destinationURL
    self.streamHandler = streamHandler
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      try moveCloudFile(at: location, to: destinationURL)
      self.streamHandler?.setEvent(FlutterEndOfEventStream)
    } catch {
      self.streamHandler?.setEvent(
        FlutterError(code: "E_NAT", message: "Native Code Error", details: "\(error)")
      )
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    self.streamHandler?.setEvent(progress * 100)
  }

  private func moveCloudFile(at: URL, to: URL) throws {
    do {
      if FileManager.default.fileExists(atPath: to.path) {
        try FileManager.default.removeItem(at: to)
      }
      try FileManager.default.moveItem(at: at, to: to)
    } catch {
      throw error
    }
  }
}
