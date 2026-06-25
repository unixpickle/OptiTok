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
    maxChecksPerPair: Int = 1,
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
      let chains = topk.items
      if chains.count < 2 {
        continue
      }

      // TODO: don't do naive enumeration + shuffle + truncation here
      var pairs = (0..<chains.count).flatMap { i in
        Array((0..<chains.count - 1).map { j in (i, j + (j >= i ? 1 : 0)) })
      }
      pairs.shuffle()

      for (idx0, idx1) in pairs.prefix(maxChecksPerPair) {
        let ch0 = chains[idx0]
        let ch1 = chains[idx1]
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
      if chain.count > minChainLength {
        chains.append(chain)
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
