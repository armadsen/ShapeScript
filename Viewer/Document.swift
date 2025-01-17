//
//  Document.swift
//  Viewer
//
//  Created by Nick Lockwood on 09/09/2018.
//  Copyright © 2018 Nick Lockwood. All rights reserved.
//

import Cocoa
import SceneKit
import ShapeScript

class Document: NSDocument, EvaluationDelegate {
    let cache = GeometryCache()
    let settings = Settings.shared

    var sceneViewControllers: [SceneViewController] {
        windowControllers.compactMap { $0.window?.contentViewController as? SceneViewController }
    }

    var scene: Scene? {
        didSet {
            let customCameras = geometry.cameras
            if !customCameras.isEmpty || progress?.didSucceed != false {
                let oldCameras = cameras
                cameras = CameraType.allCases.map {
                    Camera(type: $0)
                } + customCameras.enumerated().map { i, geometry in
                    Camera(geometry: geometry, index: i)
                }
                if !oldCameras.isEmpty {
                    var didUpdateCamera = false
                    for (old, new) in zip(oldCameras, cameras) where old != new {
                        camera = new
                        didUpdateCamera = true
                        break
                    }
                    if !didUpdateCamera, cameras.count > oldCameras.count {
                        camera = cameras[oldCameras.count]
                    }
                }
            }
            updateViews()
        }
    }

    var geometry: Geometry {
        Geometry(
            type: .group,
            name: nil,
            transform: .identity,
            material: .default,
            children: scene?.children ?? [],
            sourceLocation: nil
        )
    }

    var selectedGeometry: Geometry? {
        for viewController in sceneViewControllers {
            if let selectedGeometry = viewController.selectedGeometry {
                return selectedGeometry
            }
        }
        return nil
    }

    var progress: LoadingProgress? {
        didSet {
            updateViews()
        }
    }

    var errorMessage: NSAttributedString?
    var accessErrorURL: URL?

    var showWireframe: Bool {
        get { settings.value(for: #function, in: self) ?? false }
        set {
            settings.set(newValue, for: #function, in: self, andGlobally: true)
            rerender()
        }
    }

    var showAxes: Bool {
        get { settings.value(for: #function, in: self) ?? false }
        set {
            settings.set(newValue, for: #function, in: self, andGlobally: true)
            updateViews()
        }
    }

    var isOrthographic: Bool {
        get {
            settings.value(for: #function, in: self) ?? false
        }
        set {
            settings.set(newValue, for: #function, in: self)
            updateViews()
        }
    }

    var camera: Camera {
        get {
            let type: CameraType? = settings.value(for: #function, in: self)
            return cameras.first(where: { $0.type == type }) ?? .default
        }
        set {
            settings.set(newValue.type, for: #function, in: self)
            for viewController in sceneViewControllers {
                viewController.camera = newValue
            }
        }
    }

    func rerender() {
        guard let scene = scene else {
            return
        }
        let options = Self.outputOptions(for: scene, wireframe: showWireframe)
        progress?.dispatch { progress in
            progress.setStatus(.partial(scene))
            scene.scnBuild(with: options)
            progress.setStatus(.success(scene))
        }
    }

    func updateViews() {
        for viewController in sceneViewControllers {
            viewController.isLoading = (progress?.inProgress == true)
            viewController.background = scene?.background
            viewController.geometry = geometry
            viewController.errorMessage = errorMessage
            viewController.showAccessButton = (errorMessage != nil && accessErrorURL != nil)
            viewController.showAxes = showAxes
            viewController.isOrthographic = isOrthographic
            viewController.camera = camera
        }
    }

    override var fileURL: URL? {
        didSet {
            startObservingFileChangesIfPossible()
        }
    }

    override func makeWindowControllers() {
        dismissOpenSavePanel()

        if fileURL == nil {
            showNewDocumentPanel()
            return
        }

        // Returns the Storyboard that contains your Document window.
        let storyboard = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: nil)
        let windowController = storyboard.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier("Document Window Controller")) as! NSWindowController
        addWindowController(windowController)
        guard let newWindow = windowController.window else {
            return
        }
        newWindow.delegate = windowController.contentViewController as? NSWindowDelegate
        if let currentWindow = NSDocumentController.shared.currentDocument?
            .windowControllers.first?.window, currentWindow.tabbedWindows != nil
        {
            currentWindow.addTabbedWindow(newWindow, ordered: .above)
        }
        updateViews()
    }

    override func close() {
        super.close()
        progress?.cancel()
        _timer?.invalidate()
        _securityScopedResources.forEach {
            $0.stopAccessingSecurityScopedResource()
        }
    }

    private static func outputOptions(for scene: Scene, wireframe: Bool) -> Scene.OutputOptions {
        var options = Scene.OutputOptions.default
        let color = Color(.underPageBackgroundColor)
        let size = scene.bounds.size
        options.lineWidth = min(0.05, 0.002 * max(size.x, size.y, size.z))
        options.lineColor = scene.background.brightness(over: color) > 0.5 ? .black : .white
        options.wireframe = wireframe
        #if arch(x86_64)
        // Use stroke on x86 as line rendering looks bad
        options.wireframeLineWidth = options.lineWidth / 2
        #endif
        return options
    }

    override func read(from url: URL, ofType _: String) throws {
        let input = try String(contentsOf: url, encoding: .utf8)
        linkedResources.removeAll()
        if let progress = progress, progress.inProgress {
            Swift.print("[\(progress.id)] cancelling...")
            progress.cancel()
        }
        let showWireframe = self.showWireframe
        progress = LoadingProgress { [weak self] status in
            guard let self = self else {
                return
            }
            switch status {
            case .waiting:
                for viewController in self.sceneViewControllers {
                    viewController.showConsole = false
                    viewController.clearLog()
                }
            case let .partial(scene), let .success(scene):
                self.errorMessage = nil
                self.accessErrorURL = nil
                self.scene = scene
            case let .failure(error):
                self.errorMessage = error.message(with: input)
                if case let .fileAccessRestricted(_, url)? = (error as? RuntimeError)?.type {
                    self.accessErrorURL = url
                } else {
                    self.accessErrorURL = nil
                }
                self.updateViews()
            case .cancelled:
                break
            }
        }

        progress?.dispatch { [cache] progress in
            func logCancelled() -> Bool {
                if progress.isCancelled {
                    Swift.print("[\(progress.id)] cancelled")
                    return true
                }
                return false
            }

            let start = CFAbsoluteTimeGetCurrent()
            Swift.print("[\(progress.id)] starting...")
            if logCancelled() {
                return
            }

            let program = try parse(input)
            let parsed = CFAbsoluteTimeGetCurrent()
            Swift.print(String(format: "[\(progress.id)] parsing: %.2fs", parsed - start))
            if logCancelled() {
                return
            }

            let scene = try evaluate(program, delegate: self, cache: cache, isCancelled: {
                progress.isCancelled
            })
            let evaluated = CFAbsoluteTimeGetCurrent()
            Swift.print(String(format: "[\(progress.id)] evaluating: %.2fs", evaluated - parsed))
            if logCancelled() {
                return
            }

            // Clear errors and previous geometry
            progress.setStatus(.partial(.empty))

            let minUpdatePeriod: TimeInterval = 0.1
            var lastUpdate = CFAbsoluteTimeGetCurrent() - minUpdatePeriod
            let options = Self.outputOptions(for: scene, wireframe: showWireframe)
            _ = scene.build {
                if progress.isCancelled {
                    return false
                }
                let time = CFAbsoluteTimeGetCurrent()
                if time - lastUpdate > minUpdatePeriod {
                    Swift.print(String(format: "[\(progress.id)] rendering..."))
                    scene.scnBuild(with: options)
                    progress.setStatus(.partial(scene))
                    lastUpdate = time
                }
                return true
            }

            if logCancelled() {
                return
            }

            let done = CFAbsoluteTimeGetCurrent()
            Swift.print(String(format: "[\(progress.id)] geometry: %.2fs", done - evaluated))
            scene.scnBuild(with: options)
            progress.setStatus(.success(scene))

            let end = CFAbsoluteTimeGetCurrent()
            Swift.print(String(format: "[\(progress.id)] total: %.2fs", end - start))
        }
    }

    private var _modified: TimeInterval = 0
    private var _timer: Timer?

    private func startObservingFileChangesIfPossible() {
        // cancel previous observer
        _timer?.invalidate()

        // check file exists
        guard let url = fileURL, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        func getModifiedDate(_ url: URL) -> TimeInterval? {
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[FileAttributeKey.modificationDate] as? Date
            return date.map { $0.timeIntervalSinceReferenceDate }
        }

        func fileIsModified(_ url: URL) -> Bool {
            guard let newDate = getModifiedDate(url), newDate > _modified else {
                return false
            }
            return true
        }

        // set modified date
        _modified = Date.timeIntervalSinceReferenceDate

        // start watching
        _timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }
            guard getModifiedDate(url) != nil else {
                self._timer?.invalidate()
                self._timer = nil
                return
            }
            var isModified = false
            for u in [url] + Array(self._securityScopedResources) {
                isModified = isModified || fileIsModified(u)
            }
            guard isModified else {
                return
            }
            self._modified = Date.timeIntervalSinceReferenceDate
            _ = try? self.read(from: url, ofType: url.pathExtension)
        }
    }

    @IBAction private func didSelectEditor(_ sender: NSPopUpButton) {
        handleEditorPopupAction(for: sender, in: windowForSheet)
    }

    private func openFileInEditor(_ fileURL: URL?) {
        guard let fileURL = fileURL else {
            return
        }
        guard settings.userDidChooseEditor, let editor = settings.selectedEditor else {
            let popup = NSPopUpButton(title: "", target: self, action: #selector(didSelectEditor))
            configureEditorPopup(popup)
            popup.sizeToFit()

            let actionSheet = NSAlert()
            actionSheet.messageText = "Open in External Editor"
            actionSheet.informativeText = """
            ShapeScript does not include a built-in editor. Choose an external editor to use from the menu below.

            You can choose a different editor later from ShapeScript > Preferences…
            """
            actionSheet.accessoryView = popup
            actionSheet.addButton(withTitle: "Open")
            actionSheet.addButton(withTitle: "Cancel")
            showSheet(actionSheet, in: windowForSheet) { response in
                switch response {
                case .alertFirstButtonReturn:
                    self.settings.userDidChooseEditor = true
                    self.didSelectEditor(popup)
                    self.openFileInEditor(fileURL)
                default:
                    break
                }
            }
            return
        }

        do {
            try NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: editor.url,
                options: [],
                configuration: [:]
            )
        } catch {
            settings.userDidChooseEditor = false
            presentError(error)
        }
    }

    @IBAction func openInEditor(_: AnyObject) {
        openFileInEditor(selectedGeometry?.sourceLocation?.file ?? fileURL)
    }

    @IBAction func grantAccess(_: Any?) {
        let dialog = NSOpenPanel()
        dialog.title = "Grant Access"
        dialog.showsHiddenFiles = false
        dialog.directoryURL = accessErrorURL
        dialog.canChooseDirectories = true
        showSheet(dialog, in: windowForSheet) { response in
            guard response == .OK, let fileURL = self.fileURL, let url = dialog.url else {
                return
            }
            self.bookmarkURL(url)
            do {
                _ = try self.read(from: fileURL, ofType: fileURL.pathExtension)
            } catch {}
        }
    }

    @IBAction func revealInFinder(_: AnyObject) {
        if let fileURL = fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    @IBAction func showModelInfo(_: AnyObject) {
        let actionSheet = NSAlert()
        var fileURL: URL?

        // Geometry info
        let geometry = selectedGeometry ?? self.geometry
        let polygonCount: String
        let triangleCount: String
        let dimensions: String
        if progress?.didSucceed ?? true {
            polygonCount = String(geometry.polygonCount)
            triangleCount = String(geometry.triangleCount)
            dimensions = geometry.exactBounds.size.logDescription
        } else {
            polygonCount = "calculating…"
            triangleCount = "calculating…"
            dimensions = "calculating…"
        }

        if let selectedGeometry = selectedGeometry {
            var locationString = ""
            if let location = selectedGeometry.sourceLocation {
                locationString = "\nDefined on line \(location.line)"
                if let url = location.file {
                    fileURL = url
                    locationString += " in '\(url.lastPathComponent)'"
                }
            }
            let nameString = selectedGeometry.name.flatMap {
                $0.isEmpty ? nil : "Name: \($0)"
            }
            actionSheet.messageText = "Selected Object Info"
            actionSheet.informativeText = [
                nameString,
                "Type: \(selectedGeometry.type)",
                "Children: \(selectedGeometry.children.count)",
                "Polygons: \(polygonCount)",
                "Triangles: \(triangleCount)",
                "Dimensions: \(dimensions)",
//                "Size: \(selectedGeometry.transform.scale.logDescription)",
//                "Position: \(selectedGeometry.transform.offset.logDescription)",
//                "Orientation: \(selectedGeometry.transform.rotation.logDescription)",
                locationString,
            ].compactMap { $0 }.joined(separator: "\n")

        } else {
            actionSheet.messageText = "Model Info"
            actionSheet.informativeText = """
            Objects: \(geometry.objectCount)
            Polygons: \(polygonCount)
            Triangles: \(triangleCount)
            Dimensions: \(dimensions)

            Imports: \(importedFileCount)
            Textures: \(textureCount)
            """
        }
        actionSheet.addButton(withTitle: "OK")
        actionSheet.addButton(withTitle: "Open in Editor")
        showSheet(actionSheet, in: windowForSheet) { response in
            switch response {
            case .alertSecondButtonReturn:
                self.openFileInEditor(fileURL ?? self.fileURL)
            default:
                break
            }
        }
    }

    var cameras: [Camera] = []
    private var camerasMenu: NSMenu?

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showWireframe(_:)):
            menuItem.state = showWireframe ? .on : .off
        case #selector(showAxes(_:)):
            menuItem.state = showAxes ? .on : .off
        case #selector(setOrthographic(_:)):
            menuItem.state = camera.isOrthographic ?? isOrthographic ? .on : .off
            return camera.isOrthographic == nil
        case #selector(selectCamera(_:)) where menuItem.tag < cameras.count:
            menuItem.state = (camera == cameras[menuItem.tag]) ? .on : .off
        case #selector(selectCameras(_:)):
            menuItem.title = "Camera (\(camera.name))"
            camerasMenu = menuItem.submenu
            camerasMenu.map { configureCameraMenu($0, for: self) }
        default:
            break
        }
        return super.validateMenuItem(menuItem)
    }

    @IBAction func selectCameras(_: NSMenuItem) {
        // Does nothing
    }

    @IBAction func selectCamera(_ menuItem: NSMenuItem) {
        guard menuItem.tag < cameras.count else {
            NSSound.beep()
            return
        }
        camera = cameras[menuItem.tag]
    }

    @IBAction func showWireframe(_: NSMenuItem) {
        showWireframe.toggle()
    }

    @IBAction func showAxes(_: NSMenuItem) {
        showAxes.toggle()
    }

    @IBAction func setOrthographic(_: NSMenuItem) {
        isOrthographic.toggle()
    }

    var importedFileCount: Int {
        linkedResources.filter { !isImageFile($0) }.count
    }

    var textureCount: Int {
        linkedResources.filter { isImageFile($0) }.count
    }

    // MARK: EvaluationDelegate

    var linkedResources = Set<URL>()

    func resolveURL(for path: String) -> URL {
        let url = URL(fileURLWithPath: path, relativeTo: fileURL)
        linkedResources.insert(url)
        if let resolvedURL = resolveBookMark(for: url) {
            if resolvedURL.path != url.path {
                // File was moved, so return the original url (which will throw a file-not-found error)
                // TODO: we could handle this more gracefully by reporting that the file was moved
                return url
            }
            return resolvedURL
        } else {
            bookmarkURL(url)
        }
        return url
    }

    func importGeometry(for url: URL) throws -> Geometry? {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        var url = url
        if isDirectory.boolValue {
            let newURL = url.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: newURL.path) {
                url = newURL
            }
        }
        let scene = try SCNScene(url: url, options: [
            .flattenScene: false,
            .createNormalsIfAbsent: true,
            .convertToYUp: true,
        ])
        return try Geometry(scnNode: scene.rootNode)
    }

    func debugLog(_ values: [AnyHashable]) {
        var spaceNeeded = false
        let line = values.compactMap {
            switch $0 {
            case let string as String:
                spaceNeeded = false
                return string
            case let value:
                let string = String(logDescriptionFor: value as Any)
                defer { spaceNeeded = true }
                return spaceNeeded ? " \(string)" : string
            }
        }.joined()

        Swift.print(line)
        DispatchQueue.main.async {
            for viewController in self.sceneViewControllers {
                viewController.showConsole = true
                viewController.appendLog(line + "\n")
            }
        }
    }

    // MARK: Sandbox support

    // For debugging purposes
    public func clearBookmarks() {
        UserDefaults.standard.removeObject(forKey: "SandboxBookmarks")
    }

    private var bookmarks: [String: Data] {
        set {
            UserDefaults.standard.set(newValue, forKey: "SandboxBookmarks")
        }
        get {
            UserDefaults.standard.dictionary(forKey: "SandboxBookmarks") as? [String: Data] ?? [:]
        }
    }

    private func bookmarkURL(_ url: URL) {
        // Create an app-scoped bookmark for the selected file or folder
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            bookmarks[url.absoluteString] = data
        }
    }

    private var _securityScopedResources = Set<URL>()

    private func accessSecurityScopedURL(_ resolvedURL: URL) -> Bool {
        if _securityScopedResources.contains(resolvedURL) {
            return true
        } else if resolvedURL.startAccessingSecurityScopedResource() {
            _securityScopedResources.insert(resolvedURL)
            return true
        }
        return false
    }

    private func resolveBookMark(for url: URL) -> URL? {
        let path = url.absoluteString
        guard let data = bookmarks[path] else {
            guard !url.pathExtension.isEmpty,
                  let directoryURL = resolveBookMark(for: url.deletingLastPathComponent())
            else {
                return nil
            }
            let resolvedURL = directoryURL.appendingPathComponent(url.lastPathComponent)
            return accessSecurityScopedURL(resolvedURL) ? resolvedURL : nil
        }
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), accessSecurityScopedURL(resolvedURL) else {
            return nil
        }
        if isStale {
            bookmarkURL(resolvedURL)
        }
        return resolvedURL
    }
}
