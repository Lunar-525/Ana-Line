import XCTest
@testable import AnalogCore

final class CubeTests: XCTestCase {
    func testDownloadedLUTs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Assets/FilmLuts"),includingPropertiesForKeys: nil).filter { $0.pathExtension == "cube" }
        XCTAssertEqual(files.count,6)
        for file in files {
            let cube = try CubeLUT(text: String(contentsOf: file,encoding: .utf8))
            XCTAssertEqual(cube.dimension,13)
        }
    }
    func testIdentityLayout() throws {
        let text = "TITLE \"Identity\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n" +
            "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
        let lut = try CubeLUT(text: text)
        XCTAssertEqual(lut.dimension,2)
        XCTAssertEqual(Array(lut.rgba[4..<8]),[1,0,0,1])
        XCTAssertEqual(lut.data.count,32*MemoryLayout<Float>.size)
    }
    func testRejectMalformed() {
        for text in ["LUT_3D_SIZE 99999", "LUT_3D_SIZE 2\n0 0 0", "LUT_1D_SIZE 2",
                     "LUT_3D_SIZE 2\nDOMAIN_MAX 2 2 2", "LUT_3D_SIZE 2\nnan 0 0"] {
            XCTAssertThrowsError(try CubeLUT(text: text))
        }
    }
}
