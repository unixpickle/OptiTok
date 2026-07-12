import ArgumentParser
import Foundation
import OptiTok

@main
struct SolveLoop: ParsableCommand {

  struct State: Codable {
    public enum NextStep: Codable {
      case solveLP
      case roundTokenizer
      case findCuts
      case done
      case failed
    }

    public var corpus: [[UInt8]]
    public var lp: LP
    public var basis: SoPlexSolver.Basis? = nil
    public var addedCuts: [CutCandidate] = []

    public var nextStep: NextStep = .solveLP
    public var lastSolution: LP.Vector? = nil
    public var lastRoundedVocab: [[UInt8]]? = nil
    public var round: Int = 0
  }

  static let configuration = CommandConfiguration(
    abstract: "Build and solve an OptiTok LP relaxation for a text file."
  )

  @Argument(help: "Path to the UTF-8 text file to load.")
  var bookPath: String

  @Argument(help: "Directory for solve state.")
  var updatesDir: String

  @Flag(help: "Pretokenize the input corpus.")
  var pretokenize = false

  @Option(help: "Maximum token/color byte length.")
  var maxColorLen = 16

  @Option(help: "Minimum occurrences for multi-byte colors.")
  var minColorOccurrences = 5

  @Option(help: "Force all single-byte colors into the graph and LP.")
  var forceSingleBytes = true

  @Option(help: "Vocabulary-size LP limit.")
  var vocabSize = 512

  @Flag(help: "Enable SoPlex console logging.")
  var logToConsole = false

  @Option(help: "Additional LP cost perturbation.")
  var perturbation: Double = 1e-6

  @Option(help: "Epsilon for cut selection.")
  var cutEpsilon = 1e-4

  @Option(
    help:
      "Sample cut bounds this fraction of the way from the cut value toward the current solution value."
  )
  var cutBoundEps = 0.0

  @Option(help: "Epsilon for fractionality.")
  var fractionalEpsilon = 1e-4

  @Option(help: "3-cycle template edge pairs retained per conflicting color pair.")
  var cycle3PairsPerColorPair = 2

  @Option(help: "3-cycle template cross-product samples checked per color cycle.")
  var cycle3MaxCrossProductCount = 4

  @Option(help: "5-cycle template edge pairs retained per conflicting color pair.")
  var cycle5PairsPerColorPair = 2

  @Option(help: "5-cycle template cross-product samples checked per color cycle.")
  var cycle5MaxCrossProductCount = 4

  @Option(help: "Cut limit per round.")
  var cutLimit = 10000

  @Option(help: "Cut filtering strategy: none, uncovered, disjoint.")
  var cutFilter: CutFilter = .none

  @Option(help: "Number of brute force pairs to check.")
  var bruteForcePairs: Int = 0

  @Option(help: "Number of brute force triples to check.")
  var bruteForceTriples: Int = 0

  mutating func validate() throws {
    guard maxColorLen > 0 else {
      throw ValidationError("--max-color-len must be positive")
    }
    guard minColorOccurrences > 0 else {
      throw ValidationError("--min-color-occurrences must be positive")
    }
    guard vocabSize > 0 else {
      throw ValidationError("--vocab-size must be positive")
    }
    guard cutBoundEps >= 0 && cutBoundEps <= 1 else {
      throw ValidationError("--cut-bound-eps must be between 0 and 1")
    }
    guard cycle3PairsPerColorPair > 0 else {
      throw ValidationError("--cycle3-pairs-per-color-pair must be positive")
    }
    guard cycle3MaxCrossProductCount > 0 else {
      throw ValidationError("--cycle3-max-cross-product-count must be positive")
    }
    guard cycle5PairsPerColorPair > 0 else {
      throw ValidationError("--cycle5-pairs-per-color-pair must be positive")
    }
    guard cycle5MaxCrossProductCount > 0 else {
      throw ValidationError("--cycle5-max-cross-product-count must be positive")
    }
  }

  mutating func run() throws {
    let updatesURL = URL(fileURLWithPath: updatesDir)
    try FileManager.default.createDirectory(at: updatesURL, withIntermediateDirectories: true)

    let pretokenizer: NSRegularExpression? = pretokenize ? Tokenizer.NanochatPretokenizer : nil

    var state: State
    do {
      let url = updatesURL.appendingPathComponent("latest.plist")
      state = try Self.readState(
        State.self,
        from: url
      )
      print("Loaded existing train state from: \(url.path)")
    } catch {
      print("Starting fresh after load error")
      print(" => loading corpus: \(bookPath)...")
      let text = try Self.readText(bookPath)

      let corpus = Tokenizer(vocab: [], pretokenizer: pretokenizer).pretokenize(text: text)
      print(" => pretokenized_words=\(corpus.count)")

      print(" => building graph...")
      let graph = Graph(
        corpus: corpus,
        maxColorLen: maxColorLen,
        minColorOccurrences: minColorOccurrences,
        forceSingleBytes: forceSingleBytes
      )
      try Self.writeState(graph, to: updatesURL.appendingPathComponent("graph.plist"))
      print(
        " => saved graph: words=\(graph.words.count) colors=\(graph.colors.count) edges=\(graph.edges.count)"
      )

      print(" => building LP...")
      let lp = LP(graph: graph, limit: .vocabSize(vocabSize), forceSingleBytes: forceSingleBytes)

      state = State(corpus: corpus, lp: lp)
    }

    let solver = try SoPlexSolver(
      state.lp,
      config: .init(
        logToConsole: logToConsole,
        perturbation: perturbation
      )
    )
    if let basis = state.basis {
      print(" => restoring SoPlex basis: rows=\(basis.rows.count) columns=\(basis.columns.count)")
      try solver.restore(basis: basis)
    }

    print("----- running solver -----")

    var cutAlgs: [(String, CutAlgorithm)] = [
      ("edge_chain", WordEdgeChain(epsilon: cutEpsilon)),
      (
        "3cycle",
        FractionalCycle(
          cycleLength: 3,
          maxConflictsPerPair: cycle3PairsPerColorPair,
          maxChoicesPerCycle: cycle3MaxCrossProductCount,
          epsilon: cutEpsilon
        )
      ),
      (
        "5cycle",
        FractionalCycle(
          cycleLength: 5,
          maxConflictsPerPair: cycle5PairsPerColorPair,
          maxChoicesPerCycle: cycle5MaxCrossProductCount,
          epsilon: cutEpsilon
        )
      ),
    ]
    if bruteForcePairs > 0 {
      cutAlgs.insert(
        (
          "brute_force_pairs",
          BruteForceWordGroup(
            epsilon: cutEpsilon,
            crossSize: 2,
            candidateCount: bruteForcePairs
          )
        ),
        at: 0
      )
    }
    if bruteForceTriples > 0 {
      cutAlgs.insert(
        (
          "brute_force_triples",
          BruteForceWordGroup(
            epsilon: cutEpsilon,
            crossSize: 3,
            candidateCount: bruteForceTriples
          )
        ),
        at: 0
      )
    }

    func save() throws {
      state.lp = solver.lp
      state.basis = try solver.basis()
      try Self.writeState(state, to: updatesURL.appendingPathComponent("latest.plist"))
      try Self.writeState(
        state,
        to: updatesURL.appendingPathComponent("ckpt_\(state.round)_pre_\(state.nextStep).plist")
      )
    }

    while true {
      switch state.nextStep {
      case .done:
        print("found a solution")
        return
      case .failed:
        print("failed to find a solution")
        return
      case .solveLP:
        print("round \(state.round): solving LP relaxation...")
        let solution = try solver.solve()
        state.lastSolution = solution
        state.nextStep = .roundTokenizer
        try save()
        let check = solver.lp.check(solution: solution)
        print(
          " => round \(state.round): lower_bound=\(check.objective) max_violation=\(check.maxViolation)"
        )
      case .roundTokenizer:
        print("round \(state.round): counting rounded tokens...")
        let tok = Tokenizer.rounding(
          solution: state.lastSolution!,
          graph: solver.lp.graph,
          vocabLimit: vocabSize,
          pretokenizer: pretokenizer
        )
        state.lastRoundedVocab = tok.vocab
        state.nextStep =
          if state.lastSolution!.colors.values.count(where: { $0 > fractionalEpsilon }) <= vocabSize
          {
            .done
          } else {
            .findCuts
          }
        try save()
        let tokCount = state.corpus.map { tok.encode(word: $0).count }.reduce(0, +)
        print(" => round \(state.round): rounded_tokens=\(tokCount)")
      case .findCuts:
        print("round \(state.round): searching for cuts...")
        var allCuts = [CutCandidate]()
        for (algName, alg) in cutAlgs {
          print(" => working on cut algorithm: \(algName)")
          allCuts.append(
            contentsOf: alg.findCuts(
              lp: solver.lp, solution: state.lastSolution!, callbacks: NopCallbacks()
            )
          )
        }

        allCuts.sort { $0.violation > $1.violation }
        print(" => starting with \(allCuts.count) raw cuts")
        allCuts = cutFilter.filter(cuts: allCuts)
        if allCuts.count > cutLimit {
          allCuts.removeLast(allCuts.count - cutLimit)
        }
        allCuts = sampleCutBounds(allCuts, solution: state.lastSolution!)
        print(" => adding \(allCuts.count) cuts")
        try solver.add(constraints: allCuts.map(\.constraint))

        state.round += 1
        state.nextStep =
          if allCuts.isEmpty {
            .failed
          } else {
            .solveLP
          }
        try save()

        let maxVi = allCuts.map { $0.violation }.max() ?? 0
        print(
          " => round \(state.round - 1): added_cuts=\(allCuts.count) max_cut_violation=\(maxVi)"
        )
      }
    }

    print("Solver complete.")
  }

  private func sampleCutBounds(_ cuts: [CutCandidate], solution: LP.Vector) -> [CutCandidate] {
    guard cutBoundEps > 0 else {
      return cuts
    }

    return cuts.map { cut in
      var cut = cut
      let value = cut.constraint.coeffs.dot(solution)
      var violation: Double? = nil

      if let upperBound = cut.constraint.upperBound, value > upperBound {
        let newUpperBound = sampleCutBound(bound: upperBound, solutionValue: value)
        cut.constraint.upperBound = newUpperBound
        violation = max(violation ?? 0, value - newUpperBound)
      }
      if let lowerBound = cut.constraint.lowerBound, value < lowerBound {
        let newLowerBound = sampleCutBound(bound: lowerBound, solutionValue: value)
        cut.constraint.lowerBound = newLowerBound
        violation = max(violation ?? 0, newLowerBound - value)
      }

      if let violation {
        cut.violation = violation
      }
      return cut
    }
  }

  private func sampleCutBound(bound: Double, solutionValue: Double) -> Double {
    bound + Double.random(in: 0...cutBoundEps) * (solutionValue - bound)
  }

  private static func writeState<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = PropertyListEncoder()
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
  }

  private static func readState<T: Decodable>(_: T.Type, from url: URL) throws -> T {
    let dec = PropertyListDecoder()
    let data = try Data(contentsOf: url)
    return try dec.decode(T.self, from: data)
  }

  private static func readText(_ path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard var text = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    if data.starts(with: [0xef, 0xbb, 0xbf]) {
      text = "\u{feff}" + text
    }
    return
      text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }

  enum CutFilter: String, Codable, ExpressibleByArgument {
    case none
    case uncovered
    case disjoint

    public func filter(cuts: [CutCandidate]) -> [CutCandidate] {
      switch self {
      case .none: return cuts
      case .uncovered: return filterCoveredCuts(cuts)
      case .disjoint: return filterDisjointCuts(cuts)
      }
    }

    private func filterCoveredCuts(_ cuts: [CutCandidate]) -> [CutCandidate] {
      var coveredEdges = Set<EdgeID>()
      var coveredColors = Set<ColorID>()
      var result = [CutCandidate]()
      for cut in cuts {
        let newEdges = cut.constraint.coeffs.edges.filter { edgeID, value in
          value != 0 && !coveredEdges.contains(edgeID)
        }
        let newColors = cut.constraint.coeffs.colors.filter { colorID, value in
          value != 0 && !coveredColors.contains(colorID)
        }
        if newEdges.isEmpty && newColors.isEmpty {
          continue
        }
        result.append(cut)
        coveredEdges.formUnion(newEdges.keys)
        coveredColors.formUnion(newColors.keys)
      }
      return result
    }

    private func filterDisjointCuts(_ cuts: [CutCandidate]) -> [CutCandidate] {
      typealias CutID = Int

      // Form an adjacency graph for every cut
      var colorToCuts = [ColorID: Set<CutID>]()
      var edgeToCuts = [EdgeID: Set<CutID>]()
      for (id, cut) in cuts.enumerated() {
        for (color, value) in cut.constraint.coeffs.colors {
          if value != 0 {
            colorToCuts[color, default: .init()].insert(id)
          }
        }
        for (edge, value) in cut.constraint.coeffs.edges {
          if value != 0 {
            edgeToCuts[edge, default: .init()].insert(id)
          }
        }
      }

      var remaining = Set<CutID>(cuts.indices)

      func adjacency(cut cutID: CutID) -> Set<CutID> {
        let cut = cuts[cutID]
        var neighbors = Set<CutID>()
        for (color, value) in cut.constraint.coeffs.colors {
          if value != 0 {
            neighbors.formUnion(colorToCuts[color]!)
          }
        }
        for (edge, value) in cut.constraint.coeffs.edges {
          if value != 0 {
            neighbors.formUnion(edgeToCuts[edge]!)
          }
        }
        neighbors.remove(cutID)
        return neighbors.filter(remaining.contains)
      }

      let sortedCuts = cuts.indices.sorted { (x, y) in cuts[x].violation > cuts[y].violation }
      var result = [CutCandidate]()
      for cut in sortedCuts {
        if !remaining.contains(cut) {
          continue
        }
        result.append(cuts[cut])
        remaining.remove(cut)
        for neighbor in adjacency(cut: cut) {
          remaining.remove(neighbor)
        }
      }

      return result
    }
  }
}
