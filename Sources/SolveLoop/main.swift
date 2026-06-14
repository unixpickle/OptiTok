import ArgumentParser
import Foundation
import OptiTok

struct Summary: Codable {
  var bookPath: String
  var updatesDir: String
  var wordCount: Int
  var uniqueWordCount: Int
  var colorCount: Int
  var edgeCount: Int
  var constraintCount: Int
  var nonZeroEdgeCount: Int
  var nonZeroColorCount: Int
  var maxViolation: Double
  var objective: Double
  var options: Options

  struct Options: Codable {
    var maxColorLen: Int
    var minColorOccurrences: Int
    var forceSingleBytes: Bool
    var vocabSize: Int
    var threads: Int?
    var solver: String?
    var simplexStrategy: Int?
    var logToConsole: Bool
    var logFile: String?
  }
}

@main
struct SolveLoop: ParsableCommand {

  static let configuration = CommandConfiguration(
    abstract: "Build and solve an OptiTok LP relaxation for a text file."
  )

  @Argument(help: "Path to the UTF-8 text file to load.")
  var bookPath: String

  @Argument(help: "Directory where graph, LP, solver, solution, and summary updates are saved.")
  var updatesDir: String

  @Option(help: "Maximum token/color byte length.")
  var maxColorLen = 16

  @Option(help: "Minimum occurrences for multi-byte colors.")
  var minColorOccurrences = 2

  @Option(help: "Force all single-byte colors into the graph and LP.")
  var forceSingleBytes = true

  @Option(help: "Vocabulary-size LP limit.")
  var vocabSize = 512

  @Option(help: "HiGHS thread count.")
  var threads: Int?

  @Option(help: "HiGHS solver option, e.g. simplex.")
  var solver: String?

  @Option(help: "HiGHS simplex_strategy option.")
  var simplexStrategy: Int?

  @Flag(help: "Enable HiGHS console logging.")
  var logToConsole = false

  @Option(help: "HiGHS log file path.")
  var logFile: String?

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
    if let threads, threads <= 0 {
      throw ValidationError("--threads must be positive")
    }
  }

  mutating func run() throws {
    let updatesURL = URL(fileURLWithPath: updatesDir)
    try FileManager.default.createDirectory(at: updatesURL, withIntermediateDirectories: true)

    print("Loading book: \(bookPath)")
    let text = try String(contentsOfFile: bookPath, encoding: .utf8)
    let corpus = Tokenizer(vocab: []).pretokenize(text: text)
    print("Pretokenized \(corpus.count) words.")

    print("Building graph...")
    let graph = Graph(
      corpus: corpus,
      maxColorLen: maxColorLen,
      minColorOccurrences: minColorOccurrences,
      forceSingleBytes: forceSingleBytes
    )
    try Self.writeState(graph, to: updatesURL.appendingPathComponent("graph.plist"))
    print(
      "Saved graph with \(graph.words.count) unique words, \(graph.colors.count) colors, \(graph.edges.count) edges."
    )

    print("Building LP...")
    let lp = LP(graph: graph, limit: .vocabSize(vocabSize), forceSingleBytes: forceSingleBytes)
    try Self.writeState(lp, to: updatesURL.appendingPathComponent("lp.plist"))
    print("Saved LP with \(lp.constraints.count) constraints.")

    print("Creating HiGHS solver...")
    let highsSolver = try HiGHSSolver(
      lp,
      config: .init(
        threads: threads,
        solver: solver,
        simplexStrategy: simplexStrategy,
        logToConsole: logToConsole,
        logFile: logFile
      )
    )

    print("Solving LP relaxation...")
    let solution = try highsSolver.solve()
    try Self.writeState(solution, to: updatesURL.appendingPathComponent("solution.plist"))
    try Self.writeState(highsSolver, to: updatesURL.appendingPathComponent("solver.plist"))

    let check = lp.check(solution: solution)
    let summary = Summary(
      bookPath: bookPath,
      updatesDir: updatesDir,
      wordCount: corpus.count,
      uniqueWordCount: graph.words.count,
      colorCount: graph.colors.count,
      edgeCount: graph.edges.count,
      constraintCount: lp.constraints.count,
      nonZeroEdgeCount: solution.edges.count,
      nonZeroColorCount: solution.colors.count,
      maxViolation: check.maxViolation,
      objective: check.objective,
      options: .init(
        maxColorLen: maxColorLen,
        minColorOccurrences: minColorOccurrences,
        forceSingleBytes: forceSingleBytes,
        vocabSize: vocabSize,
        threads: threads,
        solver: solver,
        simplexStrategy: simplexStrategy,
        logToConsole: logToConsole,
        logFile: logFile
      )
    )
    try Self.writeState(summary, to: updatesURL.appendingPathComponent("summary.plist"))

    print("Solved. Objective: \(check.objective), max violation: \(check.maxViolation)")
    print("Saved solution and solver checkpoint to \(updatesURL.path)")
  }

  private static func writeState<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = PropertyListEncoder()
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
  }
}
