import Foundation
import SoPlex

public class SoPlexSolver {

  public struct Config: Codable {
    public var logToConsole: Bool
    public var perturbation: Double

    public init(
      logToConsole: Bool = false,
      perturbation: Double = 0
    ) {
      self.logToConsole = logToConsole
      self.perturbation = perturbation
    }
  }

  public typealias Basis = SparseSoPlexSolver.Basis
  public typealias Error = SparseSoPlexSolver.Error

  private let solver: SparseSoPlexSolver
  private var _lp: LP

  public var lp: LP { _lp }

  public init(_ lp: LP, config: Config = Config()) throws {
    self._lp = lp
    self.solver = try SparseSoPlexSolver(
      columns: Self.columns(for: lp, perturbation: config.perturbation),
      rows: Self.rows(for: lp.constraints, lp: lp),
      config: SparseSoPlexSolver.Config(logToConsole: config.logToConsole)
    )
  }

  public func add(constraint: LP.Constraint) throws {
    try add(constraints: [constraint])
  }

  public func add(constraints: [LP.Constraint]) throws {
    if constraints.isEmpty {
      return
    }

    try solver.add(rows: Self.rows(for: constraints, lp: lp))
    _lp.constraints.append(contentsOf: constraints)
  }

  public func solve() throws -> LP.Vector {
    let colValues = try solver.solve()
    var result = LP.Vector.empty
    for edgeID in lp.graph.edges.indices {
      let value = colValues[lp.edgeToCol[edgeID]]
      if value != 0 {
        result.edges[edgeID] = value
      }
    }
    for colorID in lp.graph.colors.indices {
      let value = colValues[lp.colorToCol[colorID]]
      if value != 0 {
        result.colors[colorID] = value
      }
    }
    return result
  }

  public func basis() throws -> Basis? {
    try solver.basis()
  }

  public func restore(basis: Basis) throws {
    try solver.restore(basis: basis)
  }

  private static func columns(for lp: LP, perturbation: Double) -> [SparseSoPlexSolver.Column] {
    let columnCount = lp.graph.edges.count + lp.graph.colors.count
    var colCost = Array(repeating: 0.0, count: columnCount)
    for (edgeID, value) in lp.objective.edges {
      colCost[lp.edgeToCol[edgeID]] = value - Double.random(in: 0...perturbation)
    }
    for (colorID, value) in lp.objective.colors {
      colCost[lp.colorToCol[colorID]] = value - Double.random(in: 0...perturbation)
    }

    return colCost.map {
      SparseSoPlexSolver.Column(objective: $0, lowerBound: 0, upperBound: 1)
    }
  }

  private static func rows(for constraints: [LP.Constraint], lp: LP) -> [SparseSoPlexSolver.Row] {
    constraints.map { constraint in
      SparseSoPlexSolver.Row(
        entries: entries(for: constraint.coeffs, lp: lp),
        lowerBound: constraint.lowerBound,
        upperBound: constraint.upperBound
      )
    }
  }

  private static func entries(for vector: LP.Vector, lp: LP) -> [SparseSoPlexSolver.RowEntry] {
    let edgeEntries = vector.edges.sorted(by: { $0.key < $1.key }).compactMap { edgeID, value in
      value == 0 ? nil : SparseSoPlexSolver.RowEntry(column: lp.edgeToCol[edgeID], value: value)
    }
    let colorEntries = vector.colors.sorted(by: { $0.key < $1.key }).compactMap { colorID, value in
      value == 0 ? nil : SparseSoPlexSolver.RowEntry(column: lp.colorToCol[colorID], value: value)
    }
    return edgeEntries + colorEntries
  }

}
