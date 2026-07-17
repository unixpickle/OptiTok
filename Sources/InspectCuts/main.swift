import ArgumentParser
import Foundation
import OptiTok

@main
struct InspectCuts: ParsableCommand {

  /// Replicates the relevant fields of the train loop.
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
    abstract: "Inspect cuts found by brute force to implement future, better cut families."
  )

  @Argument(help: "Path for solve state.")
  var statePath: String

  @Option(help: "Epsilon for cut selection.")
  var cutEpsilon = 1e-4

  @Option(help: "Number of brute force triples to check.")
  var bruteForceTriples: Int = 10000

  @Option(help: "Number of brute force clique groups to check.")
  var bruteForceCliqueGroups: Int = 0

  @Option(help: "Maximum clique group size.")
  var maxCliqueGroupSize: Int = 4

  @Option(help: "Maximum bitmap constraints for each brute force candidate.")
  var maxConstraints: Int = 10000

  mutating func run() throws {
    let url = URL(fileURLWithPath: statePath)
    let state = try Self.readState(State.self, from: url)
    guard let solution = state.lastSolution else {
      throw ValidationError("state does not contain lastSolution")
    }
    print("Loaded existing train state from: \(url.path)")

    var cutters = [(String, CutAlgorithm)]()
    if bruteForceTriples > 0 {
      cutters.append(
        (
          "brute_force_triples",
          BruteForceWordGroup(
            epsilon: cutEpsilon,
            crossSize: 3,
            maxConstraints: maxConstraints,
            candidateCount: bruteForceTriples
          )
        ))
    }
    if bruteForceCliqueGroups > 0 {
      cutters.append(
        (
          "brute_force_clique_groups",
          BruteForceCliqueGroup(
            epsilon: cutEpsilon,
            maxCrossSize: maxCliqueGroupSize,
            maxConstraints: maxConstraints,
            candidateCount: bruteForceCliqueGroups
          )
        ))
    }

    for (algName, cutter) in cutters {
      print("finding cuts for algorithm \(algName)...")
      let cuts = cutter.findCuts(
        lp: state.lp,
        solution: solution,
        callbacks: NopCallbacks()
      ).sorted { $0.violation > $1.violation }

      for (index, cut) in cuts.enumerated() {
        print()
        printCut(cut, index: index, lp: state.lp, solution: solution)
      }
    }
  }

  private func printCut(
    _ cut: CutCandidate,
    index: Int,
    lp: LP,
    solution: LP.Vector
  ) {
    let constraint = cut.constraint
    let scale = integralDisplayScale(for: constraint)
    print("cut \(index + 1)")
    if scale != 1 {
      print("  displayScale: \(format(scale))")
    }
    print("  violation: \(formatScaled(cut.violation, scale: scale))")
    if let lowerBound = constraint.lowerBound {
      print("  lowerBound: \(formatScaled(lowerBound, scale: scale))")
    }
    if let upperBound = constraint.upperBound {
      print("  upperBound: \(formatScaled(upperBound, scale: scale))")
    }
    print("  lhs at solution: \(formatScaled(constraint.coeffs.dot(solution), scale: scale))")

    let edgeTerms = constraint.coeffs.edges.sorted { lhs, rhs in
      let leftEdge = lp.graph.edges[lhs.key]
      let rightEdge = lp.graph.edges[rhs.key]
      return (leftEdge.word, leftEdge.start, leftEdge.length, lhs.key)
        < (rightEdge.word, rightEdge.start, rightEdge.length, rhs.key)
    }

    let wordToTerms = Dictionary(grouping: edgeTerms, by: { lp.graph.edges[$0.key].word })
    if wordToTerms.isEmpty {
      print("  words: none")
    } else {
      print("  words:")
      for wordID in wordToTerms.keys.sorted() {
        let word = lp.graph.words[wordID]
        print(
          "    word \(wordID) \(quoted(word.bytes)) weight=\(format(word.weight))"
        )
        for (edgeID, coeff) in wordToTerms[wordID] ?? [] {
          let edge = lp.graph.edges[edgeID]
          let colorBytes = lp.graph.colors[edge.color]
          let edgeValue = solution.edges[edgeID, default: 0]
          print(
            "      edge \(edgeID) coeff=\(formatScaled(coeff, scale: scale)) "
              + "value=\(format(edgeValue)) "
              + "start=\(edge.start) len=\(edge.length) "
              + "color=\(edge.color) \(quoted(colorBytes))"
          )
        }
      }
    }

    let colorTerms = constraint.coeffs.colors.sorted { $0.key < $1.key }
    if colorTerms.isEmpty {
      print("  colors: none")
    } else {
      print("  colors:")
      for (colorID, coeff) in colorTerms {
        let colorValue = solution.colors[colorID, default: 0]
        print(
          "    color \(colorID) coeff=\(formatScaled(coeff, scale: scale)) "
            + "value=\(format(colorValue)) "
            + "\(quoted(lp.graph.colors[colorID]))"
        )
      }
    }
  }

  private func quoted(_ bytes: [UInt8]) -> String {
    if let string = String(bytes: bytes, encoding: .utf8) {
      return "\"\(string)\""
    } else {
      return String(describing: bytes)
    }
  }

  private func format(_ value: Double) -> String {
    String(format: "%.12g", value)
  }

  private func formatScaled(_ value: Double, scale: Double) -> String {
    let scaled = value * scale
    let rounded = scaled.rounded()
    if abs(scaled - rounded) < 1e-7 {
      return String(format: "%.0f", rounded)
    }
    return format(scaled)
  }

  private func integralDisplayScale(for constraint: LP.Constraint) -> Double {
    let coefficients =
      Array(constraint.coeffs.edges.values) + Array(constraint.coeffs.colors.values)
    let absCoefficients = coefficients.map(abs).filter { $0 > 0 }
    guard let unit = absCoefficients.min(), unit.isFinite, unit > 0 else {
      return 1
    }

    let scale = 1 / unit
    guard scale.isFinite, scale <= 1e9 else {
      return 1
    }

    let maxError =
      absCoefficients.map { value in
        let scaled = value * scale
        return abs(scaled - scaled.rounded())
      }.max() ?? 0
    return maxError < 1e-5 ? scale : 1
  }

  private static func readState<T: Decodable>(_: T.Type, from url: URL) throws -> T {
    let dec = PropertyListDecoder()
    let data = try Data(contentsOf: url)
    return try dec.decode(T.self, from: data)
  }

}
