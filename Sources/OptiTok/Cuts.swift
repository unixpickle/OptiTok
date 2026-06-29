public protocol CutCallbacks {
  func reportStage(cutName: String, stage: String)
  func reportProgress(cutName: String, stage: String, progress: Double)
}

public struct NopCallbacks: CutCallbacks {
  public init() {}

  public func reportStage(cutName: String, stage: String) {
  }

  public func reportProgress(cutName: String, stage: String, progress: Double) {
  }
}

public struct CutCandidate: Codable {
  public var constraint: LP.Constraint
  public var violation: Double
}

public protocol CutAlgorithm {
  func findCuts(
    lp: LP,
    solution: LP.Vector,
    callbacks: CutCallbacks
  ) -> [CutCandidate]
}

public struct WordEdgeChain: CutAlgorithm {

  public var epsilon = 1e-4
  public var minChainLength = 2
  public var maxChainLength = 6
  public var fracEdgesPerPos = 4
  public var maxChainsPerPair = 16
  public var maxChecksPerPair = 1

  public init(
    epsilon: Double = 1e-4,
    minChainLength: Int = 2,
    maxChainLength: Int = 6,
    fracEdgesPerPos: Int = 4,
    maxChainsPerPair: Int = 16,
    maxChecksPerPair: Int = 1
  ) {
    self.epsilon = epsilon
    self.minChainLength = minChainLength
    self.maxChainLength = maxChainLength
    self.fracEdgesPerPos = fracEdgesPerPos
    self.maxChainsPerPair = maxChainsPerPair
    self.maxChecksPerPair = maxChecksPerPair
  }

  public func findCuts(
    lp: LP,
    solution: LP.Vector,
    callbacks: CutCallbacks
  ) -> [CutCandidate] {
    var cuts = [CutCandidate]()

    // We will record some chains for each word to then cross with each other.
    typealias ChainInstance = (word: WordID, edges: [EdgeID], pathways: BitmapSet)
    var pairsToChains = [Set<ColorID>: TopK<ChainInstance, Int>]()

    // Find violated single word chains.
    callbacks.reportStage(cutName: "WordEdgeChain", stage: "single_word")
    for word in lp.graph.words.indices {
      callbacks.reportProgress(
        cutName: "WordEdgeChain", stage: "single_word",
        progress: Double(word) / Double(lp.graph.words.count)
      )

      let wordPathways = lp.graph.tokenizations(word: word)

      let chains = chainsInWord(lp: lp, solution: solution, word: word)
      for chain in chains {
        let (vector, startColor, endColor) = chainVector(lp: lp, chain: chain)
        let proj = wordPathways.projected(edges: vector.edges.keys, colors: vector.colors.keys)
        precondition(!proj.bitmaps.isEmpty, "projected tokenizations is empty")
        let maxRhs = LP.Vector.from(bitmaps: proj).map { v in v.dot(vector) }.max()!
        let actualRhs = vector.dot(solution)
        if actualRhs > maxRhs + epsilon {
          cuts.append(
            CutCandidate(
              constraint: LP.Constraint(coeffs: vector, upperBound: maxRhs),
              violation: actualRhs - maxRhs
            )
          )
        }
        pairsToChains[[startColor, endColor], default: .init(k: maxChainsPerPair)].add(
          item: (word, chain, proj),
          priority: chain.count
        )
      }
    }

    for topk in pairsToChains.values {
      if topk.count < 2 {
        continue
      }

      for pair in randomCrosses(maxChecksPerPair, [0..<topk.count, 0..<(topk.count - 1)]) {
        let idx0 = pair[0]
        let idx1 = pair[1] + (pair[1] >= idx0 ? 1 : 0)
        let ch0 = topk[idx0]
        let ch1 = topk[idx1]
        let (v0, _, _) = chainVector(lp: lp, chain: ch0.edges)
        let (v1, _, _) = chainVector(lp: lp, chain: ch1.edges)
        let fullVector = v0.union(v1)
        let allPathways = ch0.pathways.cross(ch1.pathways)

        precondition(!allPathways.bitmaps.isEmpty, "pathways cross product is empty")
        let maxRhs = LP.Vector.from(bitmaps: allPathways).map { v in v.dot(fullVector) }.max()!
        let actualRhs = fullVector.dot(solution)
        if actualRhs > maxRhs + epsilon {
          cuts.append(
            CutCandidate(
              constraint: LP.Constraint(coeffs: fullVector, upperBound: maxRhs),
              violation: actualRhs - maxRhs
            )
          )
        }
      }
    }

    return cuts
  }

  public func chainVector(lp: LP, chain: [EdgeID]) -> (LP.Vector, ColorID, ColorID) {
    let startColor = lp.graph.edges[chain.first!].color
    let endColor = lp.graph.edges[chain.last!].color
    var vector = LP.Vector.empty
    for edge in chain {
      vector.edges[edge] = 1
    }
    vector.colors[startColor] = -1
    if endColor != startColor {
      vector.colors[endColor] = -1
    }
    return (vector, startColor, endColor)
  }

  public func chainsInWord(lp: LP, solution: LP.Vector, word: WordID) -> [[EdgeID]] {
    let edges = lp.graph.wordToEdges[word]
    let fractionalEdges: [EdgeID] = edges.compactMap { edgeID in
      guard let weight = solution.edges[edgeID] else {
        return nil
      }
      if weight < epsilon || weight > 1 - epsilon {
        return nil
      }
      let color = lp.graph.edges[edgeID].color
      guard let colorWeight = solution.colors[color] else {
        return nil
      }
      if colorWeight < epsilon || colorWeight > 1 - epsilon {
        return nil
      }
      return edgeID
    }
    if fractionalEdges.count < minChainLength {
      return []
    }

    var posToEdge = Dictionary(grouping: fractionalEdges, by: { lp.graph.edges[$0].start })
    posToEdge = posToEdge.mapValues { edges in
      Array(
        edges.sorted { (e1, e2) in
          abs(0.5 - solution.edges[e1]!) < abs(0.5 - solution.edges[e2]!)
        }.prefix(fracEdgesPerPos)
      )
    }

    var chains = [[EdgeID]]()
    func recurse(pos: Int, chain: [EdgeID]) {
      if chain.count >= minChainLength {
        chains.append(chain)
      }
      if chain.count == maxChainLength {
        return
      }
      for x in posToEdge[pos] ?? [] {
        recurse(pos: pos + 1, chain: chain + [x])
      }
    }
    for pos in posToEdge.keys.sorted() {
      recurse(pos: pos, chain: [])
    }

    return chains
  }

}

public struct FractionalCycle: CutAlgorithm {

  public var cycleLength: Int
  public var maxCheckCycles: Int
  public var maxConflictsPerPair: Int
  public var maxChoicesPerCycle: Int
  public var epsilon = 1e-4

  public init(
    cycleLength: Int = 3,
    maxCheckCycles: Int = 10_000_000,
    maxConflictsPerPair: Int = 2,
    maxChoicesPerCycle: Int = 4,
    epsilon: Double = 1e-4
  ) {
    self.cycleLength = cycleLength
    self.maxCheckCycles = maxCheckCycles
    self.maxConflictsPerPair = maxConflictsPerPair
    self.maxChoicesPerCycle = maxChoicesPerCycle
    self.epsilon = epsilon
  }

  public func findCuts(
    lp: LP,
    solution: LP.Vector,
    callbacks: CutCallbacks
  ) -> [CutCandidate] {
    struct Priority: Comparable {
      let edgeWeight: Double
      let wordWeight: Double

      static func < (lhs: Priority, rhs: Priority) -> Bool {
        (lhs.edgeWeight, lhs.wordWeight) < (rhs.edgeWeight, rhs.wordWeight)
      }
    }

    let fracEdges = findFractionalEdges(graph: lp.graph, solution: solution, epsilon: epsilon)
    var colorPairToEdgePairs = [Set<ColorID>: TopK<Set<EdgeID>, Priority>]()
    let cg = ConflictGraph<ColorID>(
      pairs: lp.graph.conflicts(edges: fracEdges).map { (edgeID1, edgeID2) in
        let c1 = lp.graph.edges[edgeID1].color
        let c2 = lp.graph.edges[edgeID2].color
        let word = lp.graph.words[lp.graph.edges[edgeID1].word]
        let cKey = Set<ColorID>([c1, c2])
        let eValue = Set<EdgeID>([edgeID1, edgeID2])
        var edgeWeight = solution.edges[edgeID1, default: 0] + solution.edges[edgeID2, default: 0]
        if edgeWeight > 1 - epsilon {
          edgeWeight = 1
        }
        colorPairToEdgePairs[cKey, default: .init(k: max(1, maxConflictsPerPair))].add(
          item: eValue,
          priority: Priority(edgeWeight: edgeWeight, wordWeight: word.weight)
        )
        return (c1, c2)
      }
    )

    var cuts = [CutCandidate]()
    var existing = Set<Set<EdgeID>>()
    for (seen, cycle) in cg.cycles(cycleLength).enumerated() {
      if seen >= maxCheckCycles {
        break
      }
      var colorCoeffs = LP.Vector.empty
      for colorID in cycle {
        colorCoeffs.colors[colorID] = -1
      }
      let allEdgePairs = cycle.indices.map { i in
        let colorPair = Set<ColorID>([cycle[i], cycle[(i + 1) % cycle.count]])
        return colorPairToEdgePairs[colorPair]!
      }
      for edgePairs in randomCrosses(maxChoicesPerCycle, allEdgePairs) {
        var coeffs = colorCoeffs
        for ep in edgePairs {
          for e in ep {
            coeffs.edges[e, default: 0] += 1
          }
        }

        let rhs = Double(cycleLength / 2)
        let lhs = coeffs.dot(solution)
        let violation = lhs - rhs
        if violation > epsilon {
          // Avoid redundant cuts
          let edgeSet = Set(coeffs.edges.keys)
          if !existing.insert(edgeSet).inserted {
            continue
          }
          cuts.append(
            CutCandidate(
              constraint: LP.Constraint(coeffs: coeffs, upperBound: rhs),
              violation: violation
            )
          )
        }
      }
    }

    return cuts
  }
}

private func findFractionalEdges(graph: Graph, solution: LP.Vector, epsilon: Double) -> [EdgeID] {
  let fracColors = Set(
    solution.colors.compactMap {
      $0.1 > epsilon && $0.1 < 1 - epsilon ? $0.0 : nil
    }
  )
  return solution.edges.compactMap { (edgeID, weight) -> EdgeID? in
    if weight < epsilon || weight > 1 - epsilon {
      return nil
    }
    if !fracColors.contains(graph.edges[edgeID].color) {
      return nil
    }
    return edgeID
  }
}
