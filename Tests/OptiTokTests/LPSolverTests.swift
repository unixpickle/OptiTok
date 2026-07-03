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

@Test func testSoPlexSolver() async throws {
  let graph = Graph(
    corpus: [Array("abab".utf8)],
    maxColorLen: 2,
    minColorOccurrences: 1
  )
  let lp = LP(graph: graph, limit: .vocabSize(256))
  let solver = try SoPlexSolver(lp)
  let solution = try solver.solve()
  let check = lp.check(solution: solution)

  #expect(check.maxViolation < 1e-7)
  #expect(abs(check.objective - 4.0) < 1e-7)
}

@Test func testSoPlexSolverAddsRowsBetweenSolves() async throws {
  let graph = Graph(
    corpus: [Array("abab".utf8)],
    maxColorLen: 2,
    minColorOccurrences: 1
  )
  let lp = LP(graph: graph, limit: .vocabSize(256))
  let solver = try SoPlexSolver(lp)
  let firstSolution = try solver.solve()

  if let edge = firstSolution.edges.first(where: { $0.value > 1e-7 }) {
    try solver.add(
      constraint: LP.Constraint(
        coeffs: LP.Vector(edges: [edge.key: 1.0], colors: [:]),
        upperBound: edge.value + 1.0
      )
    )
  }

  let secondSolution = try solver.solve()
  let check = solver.lp.check(solution: secondSolution)

  #expect(check.maxViolation < 1e-7)
}

@Test func testSoPlexSolverAddsBatchRowsBetweenSolves() async throws {
  let graph = Graph(
    corpus: [Array("abab".utf8)],
    maxColorLen: 2,
    minColorOccurrences: 1
  )
  let lp = LP(graph: graph, limit: .vocabSize(256))
  let solver = try SoPlexSolver(lp)
  let firstSolution = try solver.solve()

  let edgeConstraints = firstSolution.edges.prefix(2).map { edgeID, value in
    LP.Constraint(
      coeffs: LP.Vector(edges: [edgeID: 1.0], colors: [:]),
      upperBound: value + 1.0
    )
  }
  try solver.add(constraints: edgeConstraints)

  let secondSolution = try solver.solve()
  let check = solver.lp.check(solution: secondSolution)

  #expect(check.maxViolation < 1e-7)
  #expect(solver.lp.constraints.count == lp.constraints.count + edgeConstraints.count)
}

@Test func testSoPlexSolverSavesAndRestoresBasis() async throws {
  let graph = Graph(
    corpus: [Array("abab".utf8)],
    maxColorLen: 2,
    minColorOccurrences: 1
  )
  let lp = LP(graph: graph, limit: .vocabSize(256))
  let solver = try SoPlexSolver(lp)
  _ = try solver.solve()

  let basis = try #require(try solver.basis())
  #expect(basis.rows.count == solver.lp.constraints.count)
  #expect(basis.columns.count == graph.edges.count + graph.colors.count)

  let restoredSolver = try SoPlexSolver(lp)
  try restoredSolver.restore(basis: basis)
  let solution = try restoredSolver.solve()
  let check = restoredSolver.lp.check(solution: solution)

  #expect(check.maxViolation < 1e-7)
  #expect(abs(check.objective - 4.0) < 1e-7)
}

@Test func testSoPlexSolverAddsRowsAfterRestoringBasis() async throws {
  let graph = Graph(
    corpus: [Array("abab".utf8)],
    maxColorLen: 2,
    minColorOccurrences: 1
  )
  let lp = LP(graph: graph, limit: .vocabSize(256))
  let solver = try SoPlexSolver(lp)
  let firstSolution = try solver.solve()
  let basis = try #require(try solver.basis())

  let restoredSolver = try SoPlexSolver(lp)
  try restoredSolver.restore(basis: basis)

  if let edge = firstSolution.edges.first(where: { $0.value > 1e-7 }) {
    try restoredSolver.add(
      constraint: LP.Constraint(
        coeffs: LP.Vector(edges: [edge.key: 1.0], colors: [:]),
        upperBound: edge.value + 1.0
      )
    )
  }

  let extendedBasis = try #require(try restoredSolver.basis())
  #expect(extendedBasis.rows.count == restoredSolver.lp.constraints.count)
  #expect(extendedBasis.columns.count == graph.edges.count + graph.colors.count)

  let secondSolution = try restoredSolver.solve()
  let check = restoredSolver.lp.check(solution: secondSolution)

  #expect(check.maxViolation < 1e-7)
}
