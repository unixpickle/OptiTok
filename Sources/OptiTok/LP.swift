/// An GraphLP is a linear program defined over a graph.
public struct GraphLP {

  public struct Vector {
    public var edges: [Graph.EdgeID: Double]
    public var colors: [Graph.ColorID: Double]

    public static var empty: Vector { Vector(edges: .init(), colors: .init()) }

    public func dot(_ v: Vector) -> Double {
      let edgeDot = edges.map { (k, x) in x * v.edges[k, default: 0.0] }.reduce(+)
      let colorDot = colors.map { (k, x) in x * v.colors[k, default: 0.0] }.reduce(+)
      return edgeDot + colorDot
    }
  }

  // A Constraint is a single row of the linear program, defined as coefficients
  // over edge and color variables, as well as an upper bound for the combination.
  public struct Constraint {
    public var coeffs: Vector
    public var upperBound: Double?
    public var lowerBound: Double?

    public init(coeffs: Vector, upperBound: Double) {
      self.coeffs = coeffs
      self.upperBound = upperBound
      self.lowerBound = 0
    }

    public init(coeffs: Vector, lowerBound: Double) {
      self.coeffs = coeffs
      self.lowerBound = lowerBound
      self.upperBound = 0
    }

    public init(coeffs: Vector, lowerBound: Double, upperBound: Double) {
      self.coeffs = coeffs
      self.lowerBound = lowerBound
      self.upperBound = upperBound
    }
  }

  // Limit determines how to limit the vocabulary.
  public enum Limit {
    case vocabSize(Int)

    public func constraints(graph: Graph) -> [Constraint] {
      switch self {
      case .vocabSize(let size):
        [
          Constraint(
            coeffs: Vector(
              edges: .init(),
              colors: .init(uniqueKeysWithValues: (0..<graph.words.count).map { ($0, Double(1)) })
            ),
            upperBound: Double(size)
          )
        ]
      }
    }
  }

  public let graph: Graph
  public let objective: Vector
  public var constraints: [Constraint]

  public typealias ColID = Int
  public let edgeToCol: [ColID]
  public let colorToCol: [ColID]

  public init(graph: Graph, limit: Limit) {
    self.graph = graph
    constraints = limit.constraints(graph: graph)
    objective = Vector(
      edges: .init(
        uniqueKeysWithValues: graph.words.enumerated().map { (wordID, word) in
          return (wordID, Double(word.bytes.count) * word.weight)
        }),
      colors: .init()
    )

    // Add flow constraints for each vertex (midpoint between bytes of a word)
    for (pos, incoming, outgoing) in graph.vertices() {
      let rhs = switch pos {
        case .start: -1.0
        case .middle: 0.0
        case .end: 1.0
      }
      var coeffs = Vector.empty
      for edge in incoming {
        coeffs.edges[edge] = 1
      }
      for edge in outgoing {
        coeffs.edges[edge] = -1
      }
      constraints.append(Constraint(coeffs: coeffs, lowerBound: rhs, upperBound: rhs))
    }

    // Add color usage constraints for each vertex
    for (edgeID, edge) in graph.edges.enumerated() {
      var coeffs = Vector.empty
      coeffs.colors[edge.color] = -1
      coeffs.edges[edgeID] = 1
      constraints.append(Constraint(coeffs: coeffs, upperBound: 0))
    }

    edgeToCol = Array(0..<graph.edges.count)
    colorToCol = (0..<graph.colors.count).map { $0 + graph.edges.count }
  }

  /// Check computes the objective value and validates the constraints.
  public check(solution: Vector) -> (maxViolation: Double, objective: Double) {
    var maxViolation = 0.0
    let objValue = solution.dot(objective)
    for c in constraints {
      let value = c.coeffs.dot(solution)
      if let lower = c.lowerBound, value < lower {
        maxViolation = max(maxViolation, lower - value)
      }
      if let upper = c.upperBound, value > upper {
        maxViolation = max(maxViolation, value - upper)
      }
    }
    return (maxViolation, objValue)
  }

}
