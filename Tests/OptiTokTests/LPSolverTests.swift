import Foundation
import Testing

@testable import OptiTok

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

  let encoded = try JSONEncoder().encode(solver)
  let json = String(data: encoded, encoding: .utf8) ?? ""
  #expect(json.contains("\"basis\""))

  let decodedSolver = try JSONDecoder().decode(HiGHSSolver.self, from: encoded)
  let decodedSolution = try decodedSolver.solve()
  let decodedCheck = lp.check(solution: decodedSolution)

  #expect(decodedCheck.maxViolation < 1e-7)
  #expect(abs(decodedCheck.objective - 4.0) < 1e-7)
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

@Test func testHiGHSSolverSimplexStrategies() async throws {
  let graph = Graph(
    corpus: [Array("abab".utf8)],
    maxColorLen: 2,
    minColorOccurrences: 1
  )
  let lp = LP(graph: graph, limit: .vocabSize(256))

  for simplexStrategy in [1, 4] {
    let solver = try HiGHSSolver(
      lp,
      config: .init(solver: "simplex", simplexStrategy: simplexStrategy)
    )
    let solution = try solver.solve()
    let check = lp.check(solution: solution)

    #expect(check.maxViolation < 1e-7)
    #expect(abs(check.objective - 4.0) < 1e-7)
  }
}
