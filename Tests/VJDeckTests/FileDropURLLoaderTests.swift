import XCTest

final class FileDropURLLoaderTests: XCTestCase {
    func testUsesFileURLDataRepresentationFirst() throws {
        let expectedURL = URL(fileURLWithPath: "/tmp/VJDeck/drop test.pdf")
        let provider = StubFileDropURLProvider(
            dataResult: .success(expectedURL.dataRepresentation),
            objectResult: .failure(TestError.objectFailure)
        )

        var receivedResult: Result<URL, Error>?
        FileDropURLLoader.load(from: provider) { receivedResult = $0 }

        let loadedURL = try XCTUnwrap(receivedResult).get()
        XCTAssertEqual(loadedURL, expectedURL.standardizedFileURL)
        XCTAssertEqual(provider.objectLoadCount, 0)
    }

    func testFallsBackToURLObjectWhenDataIsInvalid() throws {
        let expectedURL = URL(fileURLWithPath: "/tmp/VJDeck/fallback.pdf")
        let provider = StubFileDropURLProvider(
            dataResult: .success(Data([0x00])),
            objectResult: .success(expectedURL)
        )

        var receivedResult: Result<URL, Error>?
        FileDropURLLoader.load(from: provider) { receivedResult = $0 }

        let loadedURL = try XCTUnwrap(receivedResult).get()
        XCTAssertEqual(loadedURL, expectedURL.standardizedFileURL)
        XCTAssertEqual(provider.objectLoadCount, 1)
    }

    func testReportsBothErrorsWhenNeitherRepresentationLoads() throws {
        let provider = StubFileDropURLProvider(
            dataResult: .failure(TestError.dataFailure),
            objectResult: .failure(TestError.objectFailure)
        )

        var completionCount = 0
        var receivedResult: Result<URL, Error>?
        FileDropURLLoader.load(from: provider) {
            completionCount += 1
            receivedResult = $0
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertThrowsError(try XCTUnwrap(receivedResult).get()) { error in
            XCTAssertTrue(error.localizedDescription.contains("data failure"))
            XCTAssertTrue(error.localizedDescription.contains("object failure"))
        }
    }

    func testLoadsURLFromRealItemProvider() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vjdeck-file-drop-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let provider = try XCTUnwrap(NSItemProvider(contentsOf: fileURL))
        let completion = expectation(description: "Resolve file URL")
        var receivedResult: Result<URL, Error>?

        FileDropURLLoader.load(from: provider) {
            receivedResult = $0
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        let loadedURL = try XCTUnwrap(receivedResult).get()
        XCTAssertEqual(loadedURL, fileURL.standardizedFileURL)
    }
}

private enum TestError: String, LocalizedError {
    case dataFailure = "data failure"
    case objectFailure = "object failure"

    var errorDescription: String? { rawValue }
}

private final class StubFileDropURLProvider: FileDropURLProviding {
    let dataResult: Result<Data, Error>
    let objectResult: Result<URL, Error>
    private(set) var objectLoadCount = 0

    init(dataResult: Result<Data, Error>, objectResult: Result<URL, Error>) {
        self.dataResult = dataResult
        self.objectResult = objectResult
    }

    func loadFileURLData(
        completion: @escaping (Data?, Error?) -> Void
    ) -> Progress {
        switch dataResult {
        case .success(let data):
            completion(data, nil)
        case .failure(let error):
            completion(nil, error)
        }
        return finishedProgress()
    }

    func loadFileURLObject(
        completion: @escaping (URL?, Error?) -> Void
    ) -> Progress {
        objectLoadCount += 1
        switch objectResult {
        case .success(let url):
            completion(url, nil)
        case .failure(let error):
            completion(nil, error)
        }
        return finishedProgress()
    }

    private func finishedProgress() -> Progress {
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }
}
