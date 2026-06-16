public protocol CutAlgorithm {
  func findCuts(lp: LP, solution: LP.Vector) -> [LP.Constraint]
}
