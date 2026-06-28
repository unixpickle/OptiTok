import Foundation
import Testing

@testable import OptiTok

@Test func testGraphColorOccurrencesAreWeighted() async throws {
  let graph = Graph(
    corpus: [Array("ab".utf8), Array("ab".utf8)],
    maxColorLen: 2,
    minColorOccurrences: 2
  )

  #expect(graph.colors.contains(Array("ab".utf8)))
}

@Test func testHiGHSSolver() async throws {
  let graph = Graph(
    corpus: [Array("abab".utf8)],
    maxColorLen: 2,
    minColorOccurrences: 1
  )
  let lp = LP(graph: graph, limit: .vocabSize(256))
  let solver = try HiGHSSolver(lp)
  let solution = try solver.solve()
  let check = lp.check(solution: solution)

  #expect(check.maxViolation < 1e-7)
  #expect(abs(check.objective - 4.0) < 1e-7)
}

@Test func testHiGHSSolverMultipleThreads() async throws {
  let graph = Graph(
    corpus: [Array("abab".utf8)],
    maxColorLen: 2,
    minColorOccurrences: 1
  )
  let lp = LP(graph: graph, limit: .vocabSize(256))
  let solver = try HiGHSSolver(lp, config: .init(threads: 2))
  let solution = try solver.solve()
  let check = lp.check(solution: solution)

  #expect(check.maxViolation < 1e-7)
  #expect(abs(check.objective - 4.0) < 1e-7)
}
