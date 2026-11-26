import Foundation
import UniformTypeIdentifiers

protocol FileDropURLProviding: AnyObject {
    @discardableResult
    func loadFileURLData(
        completion: @escaping (Data?, Error?) -> Void
    ) -> Progress

    @discardableResult
    func loadFileURLObject(
        completion: @escaping (URL?, Error?) -> Void
    ) -> Progress
}

extension NSItemProvider: FileDropURLProviding {
    func loadFileURLData(
        completion: @escaping (Data?, Error?) -> Void
    ) -> Progress {
        loadDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            completionHandler: completion
        )
    }

    func loadFileURLObject(
        completion: @escaping (URL?, Error?) -> Void
    ) -> Progress {
        loadObject(ofClass: URL.self, completionHandler: completion)
    }
}

enum FileDropURLLoader {
    enum LoadError: LocalizedError {
        case invalidDataRepresentation
        case unavailable(dataError: String, objectError: String)

        var errorDescription: String? {
            switch self {
            case .invalidDataRepresentation:
                return "The dropped item did not contain a valid file URL."
            case .unavailable(let dataError, let objectError):
                return "Could not resolve the dropped file URL (data: \(dataError); object: \(objectError))."
            }
        }
    }

    /// Finder advertises file drops as `public.file-url` data. Loading that
    /// representation directly avoids intermittent `nil` values observed from
    /// `loadObject(ofClass: URL.self)`. Keep the object path as a fallback for
    /// providers that do not vend a decodable data representation.
    @discardableResult
    static func load(
        from provider: FileDropURLProviding,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> Progress {
        provider.loadFileURLData { data, dataError in
            if let data,
               let url = URL(dataRepresentation: data, relativeTo: nil),
               url.isFileURL {
                completion(.success(url.standardizedFileURL))
                return
            }

            let resolvedDataError = dataError ?? LoadError.invalidDataRepresentation
            provider.loadFileURLObject { url, objectError in
                if let url, url.isFileURL {
                    completion(.success(url.standardizedFileURL))
                    return
                }

                completion(.failure(LoadError.unavailable(
                    dataError: resolvedDataError.localizedDescription,
                    objectError: objectError?.localizedDescription ?? "no URL returned"
                )))
            }
        }
    }
}
