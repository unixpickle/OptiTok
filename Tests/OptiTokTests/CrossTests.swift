import Testing

@testable import OptiTok

@Test func testRandomCrossesEnumeratesLargeRequest() async throws {
  let rows = randomCrosses(10, [[1, 2], [3, 4]])
  #expect(
    Set(rows)
      == Set([
        [1, 3],
        [1, 4],
        [2, 3],
        [2, 4],
      ])
  )
}

@Test func testRandomCrossesSamplesUniqueRows() async throws {
  let rows = randomCrosses(5, [[1, 2], [3, 4, 5], [6, 7, 8, 9]])
  #expect(rows.count == 5)
  #expect(Set(rows).count == 5)
  for row in rows {
    #expect([1, 2].contains(row[0]))
    #expect([3, 4, 5].contains(row[1]))
    #expect([6, 7, 8, 9].contains(row[2]))
  }
}

@Test func testRandomCrossesHandlesEmptyInputs() async throws {
  #expect(randomCrosses(5, [[Int](), [1, 2]]).isEmpty)
  #expect(randomCrosses(0, [[1, 2]]).isEmpty)
  #expect(randomCrosses(5, [[Int]]()) == [[]])
}
