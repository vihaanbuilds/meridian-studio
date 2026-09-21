// Sources/MeridianStudioApp/ProjectDocumentIO.swift
import AppKit
import ProjectModel

extension AppState {
    func newProject() {
        document = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        fileURL = nil
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let project = try ProjectStore.load(from: url)
            document = ProjectDocument(project: project)
            fileURL = url
        } catch {
            presentError(error)
        }
    }

    func saveProject() {
        if let fileURL {
            persist(to: fileURL)
        } else {
            saveProjectAs()
        }
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.mstudio"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard persist(to: url) else { return }
        fileURL = url
    }

    @discardableResult
    private func persist(to url: URL) -> Bool {
        do {
            try ProjectStore.save(document.project, to: url)
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func presentError(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}
