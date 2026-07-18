import AppKit
import VWEditCore
import VWViewer

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    // Not named `document`: NSWindowController already owns that property for NSDocument.
    let viewedDocument: Document?

    init(document: Document?) {
        self.viewedDocument = document
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Restoration reads archives at launch — explicitly off, per the speed budget.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.title = document?.url.lastPathComponent ?? "Kamacite"
        window.representedURL = document?.url
        // Any pixel not yet covered by content is theme-colored, never white.
        window.backgroundColor = .textBackgroundColor
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true
        windowFrameAutosaveName = "kamacite.document"
        window.delegate = self
        contentViewController = DocumentViewController(document: document)
        // The standard close-button dot; buffer-vs-disk divergence lives in
        // the engine session, so the window just mirrors its transitions.
        engineView?.onDirtyChange = { [weak self] dirty in
            self?.window?.isDocumentEdited = dirty
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("vw builds UI in code; no archives")
    }

    var engineView: DocumentEngineView? {
        (contentViewController as? DocumentViewController)?.engineView
    }

    // MARK: - Commit / discard (shared by ⌘S, the close prompt, and the edit server)

    enum CommitError: Error {
        /// The file changed on disk since open/last commit; nothing written.
        case diskChanged
        case writeFailed(String)
    }

    /// Chains commits: two overlapping detached writes could rename in
    /// inverted order (older bytes winning the disk after both "succeeded").
    private var commitChain: Task<Void, Never>?

    /// Persist the live buffer to disk: atomic temp+rename (the mmap'd
    /// original inode must survive), off-main write, dirty cleared only if no
    /// edits landed mid-write (the engine checks the version). Serialized:
    /// each commit snapshots AFTER the previous one's rename landed.
    func commit(force: Bool = false, completion: @escaping @MainActor (Result<UInt64, CommitError>) -> Void) {
        let previous = commitChain
        commitChain = Task { @MainActor in
            await previous?.value
            await self.performCommit(force: force, completion: completion)
        }
    }

    private func performCommit(
        force: Bool, completion: @escaping @MainActor (Result<UInt64, CommitError>) -> Void
    ) async {
        guard let document = viewedDocument, let engineView else {
            completion(.failure(.writeFailed("no document")))
            return
        }
        if !force, document.diskChangedExternally {
            completion(.failure(.diskChanged))
            return
        }
        let snapshot = engineView.commitSnapshot()
        let url = document.url
        let written: Result<FileStamp, CommitError> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try atomicWrite(snapshot.data, to: url))
            } catch {
                return .failure(.writeFailed("\(error)"))
            }
        }.value
        switch written {
        case .success(let stamp):
            document.rebase(to: snapshot.data, stamp: stamp)
            engineView.markCommitted(version: snapshot.version)
            completion(.success(snapshot.version))
        case .failure(let error):
            completion(.failure(error))
        }
    }

    /// Revert the buffer to disk truth (the last read/committed snapshot —
    /// deliberately NOT a fresh disk read; external changes surface at
    /// commit, not silently mid-view).
    func discard() {
        guard let document = viewedDocument, let engineView else { return }
        engineView.discardEdits(to: document.data)
    }

    /// File → Save (⌘S), nil-targeted through the responder chain.
    @objc func saveDocument(_ sender: Any?) {
        commit { [weak self] result in
            if case .failure(let error) = result {
                self?.presentCommitFailure(error)
            }
        }
    }

    /// Grays out File → Save when there's nothing to commit.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveDocument(_:)) {
            return engineView?.isDirty == true
        }
        return true
    }

    private func presentCommitFailure(_ error: CommitError) {
        guard let window else { return }
        let alert = NSAlert()
        switch error {
        case .diskChanged:
            alert.messageText = "The file has changed on disk"
            alert.informativeText = "Another program modified “\(viewedDocument?.url.lastPathComponent ?? "the file")” since it was opened. Committing would overwrite those changes."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.commit(force: true) { [weak self] result in
                        if case .failure(let error) = result {
                            self?.presentCommitFailure(error)
                        }
                    }
                }
            }
        case .writeFailed(let message):
            alert.messageText = "Couldn’t save “\(viewedDocument?.url.lastPathComponent ?? "the file")”"
            alert.informativeText = message
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: - Close

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard engineView?.isDirty == true else { return true }
        confirmUnsavedChanges { [weak self] shouldClose in
            if shouldClose { self?.close() }
        }
        return false
    }

    /// The standard mac triad. `decision(true)` means proceed with the close
    /// (after a successful commit, or a discard).
    func confirmUnsavedChanges(_ decision: @escaping (Bool) -> Void) {
        guard let window else {
            decision(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Do you want to keep the changes to “\(viewedDocument?.url.lastPathComponent ?? "this document")”?"
        alert.informativeText = "An agent or edit session changed this document in memory. Committing writes the changes to disk; discarding reverts them."
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.commit { [weak self] result in
                    switch result {
                    case .success:
                        decision(true)
                    case .failure(let error):
                        decision(false)
                        self?.presentCommitFailure(error)
                    }
                }
            case .alertSecondButtonReturn:
                self?.discard()
                decision(true)
            default:
                decision(false)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        DocumentController.shared.remove(self)
    }
}
