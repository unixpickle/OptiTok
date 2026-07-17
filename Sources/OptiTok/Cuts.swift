import Dispatch
import Foundation
import SoPlex

public protocol CutCallbacks: Sendable {
  func reportStage(cutName: String, stage: String)
  func reportProgress(cutName: String, stage: String, progress: Double)
  func reportError(cutName: String, error: Error)
}

public struct NopCallbacks: CutCallbacks {
  public init() {}

  public func reportStage(cutName: String, stage: String) {
  }

  public func reportProgress(cutName: String, stage: String, progress: Double) {
  }

  public func reportError(cutName: String, error: Error) {
  }
}

public struct CutCandidate: Codable, Sendable {
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

private final class CutResultCollector: @unchecked Sendable {
  private let queue = DispatchQueue(label: "BruteForceWordGroup.results")
  private var results = [CutCandidate]()

  func append(_ candidate: CutCandidate) {
    queue.sync {
      results.append(candidate)
    }
  }

  func reportError(callbacks: any CutCallbacks, cutName: String, error: Error) {
    queue.sync {
      callbacks.reportError(cutName: cutName, error: error)
    }
  }

  func values() -> [CutCandidate] {
    queue.sync {
      results
    }
  }
}

public struct BruteForceWordGroup: CutAlgorithm, Sendable {

  public var epsilon: Double
  public var crossSize: Int
  public var maxConstraints: Int
  public var candidateCount: Int

  public init(
    epsilon: Double = 1e-4,
    crossSize: Int = 2,
    maxConstraints: Int = 10000,
    candidateCount: Int = 10000
  ) {
    self.epsilon = epsilon
    self.crossSize = crossSize
    self.maxConstraints = maxConstraints
    self.candidateCount = candidateCount
  }

  public func findCuts(
    lp: LP,
    solution: LP.Vector,
    callbacks: CutCallbacks
  ) -> [CutCandidate] {
    let wordSets = wordSets(lp: lp, solution: solution)
    let results = CutResultCollector()
    DispatchQueue.concurrentPerform(iterations: wordSets.count) { i in
      let wordIDs = wordSets[i]
      guard let combinations = wordCross(lp: lp, solution: solution, words: wordIDs) else {
        return
      }
      do {
        let constraint = try findMaximalCut(combos: combinations, solution: solution)
        let violation = constraint.violation(solution: solution)
        if violation > epsilon {
          results.append(CutCandidate(constraint: constraint, violation: violation))
        }
      } catch {
        results.reportError(callbacks: callbacks, cutName: "BruteForceWordGroup", error: error)
      }
    }
    return results.values()
  }

  public func wordSets(lp: LP, solution: LP.Vector) -> [[WordID]] {
    var colorToWords = [ColorID: Set<WordID>]()

    for wordID in lp.graph.words.indices {
      for colorID in fracColors(lp: lp, solution: solution, word: wordID) {
        colorToWords[colorID, default: .init()].insert(wordID)
      }
    }

    let availableWords = colorToWords.values.reduce(Set<WordID>(), { $0.union($1) })
    if availableWords.count < crossSize {
      return []
    }

    // Sample without replacement using rejection sampling, but bail if we
    // sample too much, so that we don't spend forever trying to sample more
    // valid combos than there are.
    var checked = Set<Set<WordID>>()
    for _ in 0..<(candidateCount * 4) {
      if checked.count == candidateCount {
        break
      }

      let firstWord = availableWords.randomElement()!
      var wordIDs = [firstWord]
      for _ in 1..<crossSize {
        let candidateColors = wordIDs.reduce(
          Set<ColorID>(), { $0.union(fracColors(lp: lp, solution: solution, word: $1)) })
        let wordSets: [Set<WordID>] = candidateColors.map { colorToWords[$0]! }
        let wordSet = wordSets.reduce(Set<WordID>(), { $0.union($1) }).filter({
          !wordIDs.contains($0)
        })
        guard let nextWord = wordSet.randomElement() else {
          break
        }
        wordIDs.append(nextWord)
      }
      if wordIDs.count == crossSize {
        checked.insert(Set(wordIDs))
      }
    }
    return checked.map { $0.sorted() }
  }

  public func fracColors(lp: LP, solution: LP.Vector, word: WordID) -> Set<ColorID> {
    Set(
      lp.graph.wordToEdges[word].compactMap { edgeID in
        let edgeVal = solution.edges[edgeID, default: 0]
        if edgeVal < epsilon || edgeVal > 1 - epsilon {
          return nil
        }
        let color = lp.graph.edges[edgeID].color
        let colorVal = solution.colors[color, default: 0]
        if colorVal < epsilon || colorVal > 1 - epsilon {
          return nil
        }
        return color
      }
    )
  }

  public func wordCross(lp: LP, solution: LP.Vector, words wordIDs: [WordID]) -> BitmapSet? {
    // Keep every color that has at least two occurrences.
    var colorCount = [ColorID: Int]()
    for wordID in wordIDs {
      for colorID in fracColors(lp: lp, solution: solution, word: wordID) {
        colorCount[colorID, default: 0] += 1
      }
    }
    let keepColors = Set(colorCount.compactMap { $0.value > 1 ? $0.key : nil })
    let individualBitmaps: [BitmapSet] = wordIDs.map { wordID in
      let fullTok = lp.graph.tokenizations(word: wordID)
      let colors = keepColors.intersection(fracColors(lp: lp, solution: solution, word: wordID))
      let remainingEdges = lp.graph.wordToEdges[wordID].filter { edgeID in
        let edgeValue = solution.edges[edgeID, default: 0]
        return colors.contains(lp.graph.edges[edgeID].color)
          && edgeValue > epsilon
          && edgeValue < 1 - epsilon
      }
      return fullTok.projected(edges: remainingEdges, colors: colors).fillingFalseColors()
    }
    var result = individualBitmaps[0]
    for bmp in individualBitmaps[1...] {
      guard let next = bmp.cross(result, limit: maxConstraints) else {
        return nil
      }
      result = next
    }
    return result
  }

}

public struct BruteForceCliqueGroup: CutAlgorithm, Sendable {

  private final class CliqueGroupCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let targetCount: Int
    private var seen = Set<Set<Int>>()
    private var result = [[Set<EdgeID>]]()

    init(targetCount: Int) {
      self.targetCount = targetCount
    }

    func shouldStartIteration() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return result.count < targetCount
    }

    func append(group: Set<Int>, cliques: [Set<EdgeID>]) {
      lock.lock()
      defer { lock.unlock() }
      if result.count >= targetCount {
        return
      }
      if seen.insert(group).inserted {
        result.append(group.map { cliques[$0] })
      }
    }

    func values() -> [[Set<EdgeID>]] {
      lock.lock()
      defer { lock.unlock() }
      return result
    }
  }

  /// A weighting function for candidate cliques given an existing set of cliques.
  /// The weight takes the number of colors that a new clique has in common with
  /// the existing cliques and returns a probability weight for being chosen.
  public enum WeightFunc: Sendable {
    case exponential(Double)
    case linear

    public func candidateWeight(commonColorCount: Int) -> Double {
      switch self {
      case .exponential(let base): pow(base, Double(commonColorCount))
      case .linear: Double(commonColorCount)
      }
    }
  }

  public var epsilon: Double
  public var minCrossSize: Int
  public var maxCrossSize: Int
  public var maxSharedColors: Int
  public var maxConstraints: Int
  public var candidateCount: Int
  public var weightFunc: WeightFunc

  public init(
    epsilon: Double = 1e-4,
    minCrossSize: Int = 2,
    maxCrossSize: Int = 4,
    maxSharedColors: Int = 8,
    maxConstraints: Int = 10000,
    candidateCount: Int = 10000,
    weightFunc: WeightFunc = .exponential(4)
  ) {
    self.epsilon = epsilon
    self.minCrossSize = minCrossSize
    self.maxCrossSize = maxCrossSize
    self.maxSharedColors = maxSharedColors
    self.maxConstraints = maxConstraints
    self.candidateCount = candidateCount
    self.weightFunc = weightFunc
  }

  public func findCuts(
    lp: LP,
    solution: LP.Vector,
    callbacks: CutCallbacks
  ) -> [CutCandidate] {
    let groups = cliqueGroups(lp: lp, solution: solution)
    let results = CutResultCollector()
    DispatchQueue.concurrentPerform(iterations: groups.count) { i in
      guard let combinations = bitmapFor(lp: lp, cliques: groups[i]) else {
        return
      }
      do {
        let constraint = try findMaximalCut(combos: combinations, solution: solution)
        let violation = constraint.violation(solution: solution)
        if violation > epsilon {
          results.append(CutCandidate(constraint: constraint, violation: violation))
        }
      } catch {
        results.reportError(callbacks: callbacks, cutName: "BruteForceCliqueGroup", error: error)
      }
    }
    return results.values()
  }

  private func weight(commonColors: Int) -> Double {
    weightFunc.candidateWeight(commonColorCount: commonColors)
  }

  public func bitmapFor(lp: LP, cliques: [Set<EdgeID>]) -> BitmapSet? {
    var colorCount = [ColorID: Int]()
    for clique in cliques {
      for edge in clique {
        colorCount[lp.graph.edges[edge].color, default: 0] += 1
      }
    }
    let allColors: [ColorID] = colorCount.compactMap { $0.value > 1 ? $0.key : nil }
    precondition(allColors.count < 48, "too many color combinations to enumerate in memory")

    // Start with every possible combination of colors
    let colorBitmap = BitmapSet(
      edges: [],
      colors: allColors.sorted(),
      bitmaps: Set(
        (0..<(1 << allColors.count)).map { i in
          Bitmap(count: allColors.count, pattern: UInt64(i))
        })
    )

    // For each clique, compute an exhaustive set of combinations, given that a clique
    // can only have one active edge in a valid ILP solution.
    let perClique: [BitmapSet] = cliques.map { clique in
      let allowedEdges = clique.filter { allColors.contains(lp.graph.edges[$0].color) }
      precondition(
        !allowedEdges.isEmpty, "clique can only be added if it shares at least one color")
      let withEdges = colorBitmap.adding(edges: allowedEdges, colors: [])

      // Note that the permutation set for this clique includes the case where
      // no clique edge is active, which *may* be possible in a valid tokenization,
      // but is not strictly guaranteed. If it's not possible, then we will simply have
      // some extra ILP-based constraints that potentially hide a valid cut.
      var newSet = withEdges

      for edge in allowedEdges {
        let color = lp.graph.edges[edge].color
        let colorIdx = withEdges.colorToIdx[color]!
        let edgeIdx = withEdges.edgeToIdx[edge]!
        newSet.bitmaps.formUnion(
          withEdges.bitmaps.compactMap { bitmap in
            if bitmap[colorIdx] {
              var newBmp = bitmap
              newBmp[edgeIdx] = true
              return newBmp
            }
            return nil
          })
      }
      return newSet
    }

    var result = perClique[0]
    for bmp in perClique[1...] {
      guard let next = bmp.cross(result, limit: maxConstraints) else {
        return nil
      }
      result = next
    }
    return result
  }

  public func cliqueGroups(lp: LP, solution: LP.Vector) -> [[Set<EdgeID>]] {
    typealias CliqueID = Int
    let cliques = fractionalCliques(lp: lp, solution: solution)
    if cliques.count < minCrossSize {
      return []
    }
    let cliqueColors = cliques.map { edgeIDs in
      Set(edgeIDs.map { lp.graph.edges[$0].color })
    }

    let colorToCliques: [ColorID: Set<CliqueID>] = {
      var result = [ColorID: Set<CliqueID>]()
      for (cliqueID, colors) in cliqueColors.enumerated() {
        for colorID in colors {
          result[colorID, default: []].insert(cliqueID)
        }
      }
      return result
    }()

    let result = CliqueGroupCollector(targetCount: candidateCount)
    DispatchQueue.concurrentPerform(iterations: candidateCount * 4) { _ in
      if !result.shouldStartIteration() {
        return
      }

      // State that gets updated as we add more cliques
      var group: Set<CliqueID> = []
      var edges: Set<EdgeID> = []
      var colors: Set<ColorID> = []
      var commonCount = [CliqueID: Int]()

      func countIntersection<T: Hashable & Sendable>(_ s1: Set<T>, _ s2: Set<T>) -> Int {
        s1.count(where: s2.contains)
      }

      func addClique(_ sample: CliqueID) {
        let addColors = cliqueColors[sample]
        let newColors = addColors.filter { !colors.contains($0) }
        colors.formUnion(addColors)
        edges.formUnion(cliques[sample])
        group.insert(sample)

        for color in newColors {
          for cliqueID in colorToCliques[color]! {
            commonCount[cliqueID, default: 0] += 1
          }
        }

        commonCount = commonCount.filter { (cliqueID, _) in
          // Do not allow too many common edges
          if countIntersection(edges, cliques[cliqueID]) > 0 {
            return false
          }

          // Limit the total colors
          let extraColors = cliqueColors[cliqueID]
          let redundantCount = countIntersection(extraColors, colors)
          let newCount = extraColors.count - redundantCount
          if colors.count + newCount > maxSharedColors {
            return false
          }

          return true
        }
      }

      func sampleClique() -> CliqueID? {
        let scoreMap = commonCount.map { (k, v) in (k, weight(commonColors: v)) }

        let total = scoreMap.map { $0.1 }.reduce(0, +)
        if total == 0 {
          return nil
        }
        var value = Double.random(in: 0.0..<total)
        for (i, x) in scoreMap {
          if x == 0 {
            // If we literally sample value == 0, we don't want to pick the first item.
            continue
          }
          value -= x
          if value <= 0 {
            return i
          }
        }
        // Edge case for numeric imprecision
        return nil
      }

      addClique(cliques.indices.randomElement()!)
      for _ in 1..<maxCrossSize {
        guard let sample = sampleClique() else {
          break
        }
        addClique(sample)
      }
      if group.count < minCrossSize {
        return
      }
      result.append(group: group, cliques: cliques)
    }

    return result.values()
  }

  public func fractionalCliques(lp: LP, solution: LP.Vector) -> [Set<EdgeID>] {
    func isFracEdge(_ edgeID: EdgeID) -> Bool {
      let value = solution.edges[edgeID, default: 0]
      return value > epsilon && value < 1 - epsilon
    }
    var result = [Set<EdgeID>]()
    for wordID in lp.graph.words.indices {
      var endToEdge = [Int: Set<EdgeID>]()
      var startToEdge = [Int: Set<EdgeID>]()
      for edgeID in lp.graph.wordToEdges[wordID] {
        if !isFracEdge(edgeID) {
          continue
        }
        let edge = lp.graph.edges[edgeID]
        startToEdge[edge.start, default: .init()].insert(edgeID)
        endToEdge[edge.start + edge.length, default: .init()].insert(edgeID)
      }
      if startToEdge.isEmpty {
        continue
      }
      var curClique = Set<EdgeID>()
      for idx in 0...startToEdge.keys.max()! {
        curClique.subtract(endToEdge[idx, default: .init()])
        if let newEdges = startToEdge[idx] {
          curClique.formUnion(newEdges)
          result.append(curClique)
        }
      }
    }
    return result
  }

}

private func findMaximalCut(combos: BitmapSet, solution: LP.Vector) throws -> LP.Constraint {
  // We have a pos and neg variable for each bit, plus a final bias
  var varToObj = [Double](repeating: 0, count: combos.bitCount * 2 + 2)
  for (edgeID, bitIdx) in combos.edgeToIdx {
    varToObj[bitIdx * 2] = -solution.edges[edgeID, default: 0]
    varToObj[bitIdx * 2 + 1] = solution.edges[edgeID, default: 0]
  }
  for (colorID, bitIdx) in combos.colorToIdx {
    varToObj[bitIdx * 2] = -solution.colors[colorID, default: 0]
    varToObj[bitIdx * 2 + 1] = solution.colors[colorID, default: 0]
  }
  varToObj[varToObj.count - 2] = -1
  varToObj[varToObj.count - 1] = 1

  let columns = varToObj.enumerated().map { (i, obj) in
    SparseSoPlexSolver.Column(objective: obj, lowerBound: 0)
  }
  let lp = try SparseSoPlexSolver(columns: columns)

  // Add L1 constraint to optimal cut coefficients
  try lp.add(
    row: .init(
      entries: (0..<(varToObj.count - 2)).map { i in
        .init(column: i, value: 1)
      },
      lowerBound: nil,
      upperBound: 1
    )
  )

  // We split the bias into positive/negative because SoPlex doesn't support
  // unbounded variables, but now there's an unbounded direction for the LP,
  // so we will constrain the bias to a large but finite L1 norm.
  try lp.add(
    row: .init(
      entries: [
        .init(column: varToObj.count - 2, value: 1),
        .init(column: varToObj.count - 1, value: 1),
      ],
      lowerBound: nil,
      upperBound: Double(varToObj.count * 2),
    )
  )

  // Note that these coefficients are negative of the above, since the
  // objective is minimization but these are upper bound constraints.
  for bmp in combos.bitmaps {
    var entries = [SparseSoPlexSolver.RowEntry]()
    for (i, bit) in bmp.enumerated() {
      if bit {
        entries.append(.init(column: i * 2, value: 1))
        entries.append(.init(column: i * 2 + 1, value: -1))
      }
    }
    entries.append(.init(column: varToObj.count - 2, value: 1))
    entries.append(.init(column: varToObj.count - 1, value: -1))
    try lp.add(row: .init(entries: entries, lowerBound: nil, upperBound: 0))
  }

  let solution = try lp.solve()

  var coeffs = LP.Vector.empty
  for (edgeID, bitIdx) in combos.edgeToIdx {
    let value = solution[bitIdx * 2] - solution[bitIdx * 2 + 1]
    if abs(value) > 1e-5 {
      coeffs.edges[edgeID] = value
    }
  }
  for (colorID, bitIdx) in combos.colorToIdx {
    let value = solution[bitIdx * 2] - solution[bitIdx * 2 + 1]
    if abs(value) > 1e-5 {
      coeffs.colors[colorID] = value
    }
  }

  let upperBound = LP.Vector.from(bitmaps: combos).map { $0.dot(coeffs) }.max() ?? 0
  return LP.Constraint(coeffs: coeffs, upperBound: upperBound)
}
