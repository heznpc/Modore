import Foundation

@MainActor
enum EnvironmentFolderAccess {
    private static var active: [URL] = []
    private static var loaded = false
    private static var store: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Modore/environment-folder-access.json")
    }
    static func restore() {
        guard !loaded else { return }; loaded = true
        guard let data=try? SecureLocalFileIO.boundedRead(from:store,maximumBytes:1_000_000),
              let bookmarks=try? JSONDecoder().decode([Data].self,from:data) else { return }
        for bookmark in bookmarks {
            var stale=false
            if let url=try? URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],bookmarkDataIsStale:&stale), !stale {
                _ = url.startAccessingSecurityScopedResource();active.append(url)
            }
        }
    }
    static func grant(_ url:URL) throws {
        restore()
        _ = url.startAccessingSecurityScopedResource()
        if !active.contains(url) { active.append(url) }
        let bookmarks=try active.map { try $0.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) }
        try SecureLocalFileIO.atomicWrite(JSONEncoder().encode(bookmarks),to:store,permissions:0o600)
    }
}
