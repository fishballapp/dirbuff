import DirBuffKit
import Testing

@Suite struct MachineTests {
  @Test func theIDIsAStableHash() throws {
    let id = try Machine.id()
    #expect(id.count == 64)
    #expect(try Machine.id() == id)
  }
}
