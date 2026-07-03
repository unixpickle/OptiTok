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

  @Flag(help: "Drop cuts whose nonzero edge/color variables are already covered by higher-violation cuts.")
  var noCoveredCuts = false

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

    let cutAlgs: [(String, CutAlgorithm)] = [
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
          if state.lastSolution!.colors.values.count(where: { $0 > fractionalEpsilon }) <= vocabSize {
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
        if noCoveredCuts {
          allCuts = filterCoveredCuts(allCuts)
        }
        if allCuts.count > cutLimit {
          allCuts.removeLast(allCuts.count - cutLimit)
        }
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

  private func filterCoveredCuts(_ cuts: [CutCandidate]) -> [CutCandidate] {
    var coveredEdges = Set<EdgeID>()
    var coveredColors = Set<ColorID>()
    var result = [CutCandidate]()
    for cut in cuts {
      let newEdges = cut.constraint.coeffs.edges.filter { edgeID, value in
        value > cutEpsilon && !coveredEdges.contains(edgeID)
      }
      let newColors = cut.constraint.coeffs.colors.filter { colorID, value in
        value > cutEpsilon && !coveredColors.contains(colorID)
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
}
