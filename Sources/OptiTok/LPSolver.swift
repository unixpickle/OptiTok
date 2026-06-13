import CHiGHS
import Foundation

public class HiGHSSolver: Codable {

  public enum Error: Swift.Error, CustomStringConvertible {
    case couldNotCreateSolver
    case highsError(operation: String, status: HighsInt)
    case modelNotOptimal(status: HighsInt)

    public var description: String {
      switch self {
      case .couldNotCreateSolver:
        return "could not create HiGHS solver"
      case .highsError(let operation, let status):
        return "HiGHS \(operation) failed with status \(status)"
      case .modelNotOptimal(let status):
        return "HiGHS model status is not optimal: \(status)"
      }
    }
  }

  public struct Config: Codable {
    public var threads: Int?
    public var solver: String?
    public var simplexStrategy: Int?
    public var logToConsole: Bool
    public var logFile: String?

    public init(
      threads: Int? = nil,
      solver: String? = nil,
      simplexStrategy: Int? = nil,
      logToConsole: Bool = false,
      logFile: String? = nil
    ) {
      self.threads = threads
      self.solver = solver
      self.simplexStrategy = simplexStrategy
      self.logToConsole = logToConsole
      self.logFile = logFile
    }
  }

  private enum CodingKeys: String, CodingKey {
    case lp
    case config
    case basis
  }

  private let highs: OpaquePointer
  private var _lp: LP
  private var config: Config

  public var lp: LP { _lp }

  public required convenience init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let lp = try container.decode(LP.self, forKey: .lp)
    let config = try container.decode(Config.self, forKey: .config)
    let basis = try container.decodeIfPresent(Data.self, forKey: .basis)
    try self.init(lp, config: config)
    if let basis {
      try loadBasis(basis)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(lp, forKey: .lp)
    try container.encode(config, forKey: .config)
    try container.encodeIfPresent(dumpBasis(), forKey: .basis)
  }

  public init(_ lp: LP, config: Config = Config()) throws {
    guard let rawHighs = Highs_create() else {
      throw Error.couldNotCreateSolver
    }
    self.highs = OpaquePointer(rawHighs)
    self._lp = lp
    self.config = config

    do {
      try configure()
      try initializeMatrix()
    } catch {
      Highs_destroy(rawHighs)
      throw error
    }
  }

  deinit {
    Highs_destroy(UnsafeMutableRawPointer(highs))
  }

  public func add(constraint: LP.Constraint) throws {
    var indices = [HighsInt]()
    var values = [Double]()
    appendEntries(for: constraint.coeffs, indices: &indices, values: &values)

    let status = indices.withUnsafeBufferPointer { indexBuffer in
      values.withUnsafeBufferPointer { valueBuffer in
        Highs_addRow(
          UnsafeMutableRawPointer(highs),
          highsLowerBound(constraint.lowerBound),
          highsUpperBound(constraint.upperBound),
          HighsInt(indices.count),
          indexBuffer.baseAddress,
          valueBuffer.baseAddress
        )
      }
    }
    try checkStatus(status, operation: "add row")
    try passRowName(_lp.constraints.count)
    _lp.constraints.append(constraint)
  }

  public func solve() throws -> LP.Vector {
    try checkStatus(Highs_run(UnsafeMutableRawPointer(highs)), operation: "run")

    let modelStatus = Highs_getModelStatus(UnsafeRawPointer(highs))
    guard modelStatus == kHighsModelStatusOptimal else {
      throw Error.modelNotOptimal(status: modelStatus)
    }

    var colValues = Array(repeating: 0.0, count: columnCount)
    let status = colValues.withUnsafeMutableBufferPointer { colBuffer in
      Highs_getSolution(
        UnsafeRawPointer(highs),
        colBuffer.baseAddress,
        nil,
        nil,
        nil
      )
    }
    try checkStatus(status, operation: "get solution")

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

  private static let infinity = 1.0e30

  private var columnCount: Int {
    lp.graph.edges.count + lp.graph.colors.count
  }

  private func configure() throws {
    try checkStatus(
      Highs_setBoolOptionValue(
        UnsafeMutableRawPointer(highs),
        "log_to_console",
        config.logToConsole ? 1 : 0
      ),
      operation: "set log_to_console"
    )
    if let threads = config.threads {
      try checkStatus(
        Highs_setIntOptionValue(UnsafeMutableRawPointer(highs), "threads", HighsInt(threads)),
        operation: "set threads"
      )
      if threads != 1 {
        try checkStatus(
          Highs_setStringOptionValue(UnsafeMutableRawPointer(highs), "parallel", "on"),
          operation: "set parallel"
        )
      }
    }
    if let solver = config.solver {
      try checkStatus(
        Highs_setStringOptionValue(UnsafeMutableRawPointer(highs), "solver", solver),
        operation: "set solver"
      )
    }
    if let simplexStrategy = config.simplexStrategy {
      try checkStatus(
        Highs_setIntOptionValue(
          UnsafeMutableRawPointer(highs), "simplex_strategy", HighsInt(simplexStrategy)),
        operation: "set simplex_strategy"
      )
    }
    if let logFile = config.logFile {
      try checkStatus(
        Highs_setStringOptionValue(UnsafeMutableRawPointer(highs), "log_file", logFile),
        operation: "set log_file"
      )
    }
  }

  private func initializeMatrix() throws {
    let matrix = buildRowwiseMatrix(lp.constraints)
    let numCol = HighsInt(columnCount)
    let numRow = HighsInt(lp.constraints.count)

    var colCost = Array(repeating: 0.0, count: columnCount)
    for (edgeID, value) in lp.objective.edges {
      colCost[lp.edgeToCol[edgeID]] = value
    }
    for (colorID, value) in lp.objective.colors {
      colCost[lp.colorToCol[colorID]] = value
    }

    let colLower = Array(repeating: 0.0, count: columnCount)
    let colUpper = Array(repeating: 1.0, count: columnCount)
    let rowLower = lp.constraints.map { highsLowerBound($0.lowerBound) }
    let rowUpper = lp.constraints.map { highsUpperBound($0.upperBound) }
    let starts = matrix.starts
    let indices = matrix.indices
    let values = matrix.values

    let status = colCost.withUnsafeBufferPointer { colCostBuffer in
      colLower.withUnsafeBufferPointer { colLowerBuffer in
        colUpper.withUnsafeBufferPointer { colUpperBuffer in
          rowLower.withUnsafeBufferPointer { rowLowerBuffer in
            rowUpper.withUnsafeBufferPointer { rowUpperBuffer in
              starts.withUnsafeBufferPointer { startsBuffer in
                indices.withUnsafeBufferPointer { indicesBuffer in
                  values.withUnsafeBufferPointer { valuesBuffer in
                    Highs_passLp(
                      UnsafeMutableRawPointer(highs),
                      numCol,
                      numRow,
                      HighsInt(values.count),
                      kHighsMatrixFormatRowwise,
                      kHighsObjSenseMaximize,
                      0.0,
                      colCostBuffer.baseAddress,
                      colLowerBuffer.baseAddress,
                      colUpperBuffer.baseAddress,
                      rowLowerBuffer.baseAddress,
                      rowUpperBuffer.baseAddress,
                      startsBuffer.baseAddress,
                      indicesBuffer.baseAddress,
                      valuesBuffer.baseAddress
                    )
                  }
                }
              }
            }
          }
        }
      }
    }
    try checkStatus(status, operation: "pass LP")
    try passColumnNames()
    try passRowNames()
  }

  private func dumpBasis() throws -> Data? {
    var basisValidity = HighsInt(0)
    try checkStatus(
      Highs_getIntInfoValue(UnsafeRawPointer(highs), "basis_validity", &basisValidity),
      operation: "get basis_validity"
    )
    guard basisValidity == kHighsBasisValidityValid else {
      return nil
    }

    let url = Self.temporaryBasisURL()
    defer { try? FileManager.default.removeItem(at: url) }

    try checkStatus(
      CHighs_writeBasis(UnsafeMutableRawPointer(highs), url.path),
      operation: "write basis"
    )
    return try Data(contentsOf: url)
  }

  private func loadBasis(_ data: Data) throws {
    let url = Self.temporaryBasisURL()
    defer { try? FileManager.default.removeItem(at: url) }

    try data.write(to: url, options: .atomic)
    try checkStatus(
      CHighs_readBasis(UnsafeMutableRawPointer(highs), url.path),
      operation: "read basis"
    )
  }

  private static func temporaryBasisURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("OptiTok-\(UUID().uuidString)")
      .appendingPathExtension("basis")
  }

  private func passColumnNames() throws {
    for edgeID in lp.graph.edges.indices {
      try passColumnName(lp.edgeToCol[edgeID], name: "edge_\(edgeID)")
    }
    for colorID in lp.graph.colors.indices {
      try passColumnName(lp.colorToCol[colorID], name: "color_\(colorID)")
    }
  }

  private func passColumnName(_ colID: LP.ColID, name: String) throws {
    try checkStatus(
      Highs_passColName(UnsafeRawPointer(highs), HighsInt(colID), name),
      operation: "pass column name"
    )
  }

  private func passRowNames() throws {
    for rowID in lp.constraints.indices {
      try passRowName(rowID)
    }
  }

  private func passRowName(_ rowID: Int) throws {
    try checkStatus(
      Highs_passRowName(UnsafeRawPointer(highs), HighsInt(rowID), "row_\(rowID)"),
      operation: "pass row name"
    )
  }

  private func buildRowwiseMatrix(_ constraints: [LP.Constraint]) -> (
    starts: [HighsInt], indices: [HighsInt], values: [Double]
  ) {
    var starts = [HighsInt]()
    starts.reserveCapacity(constraints.count)
    var indices = [HighsInt]()
    var values = [Double]()

    for constraint in constraints {
      starts.append(HighsInt(indices.count))
      appendEntries(for: constraint.coeffs, indices: &indices, values: &values)
    }
    return (starts, indices, values)
  }

  private func appendEntries(
    for vector: LP.Vector,
    indices: inout [HighsInt],
    values: inout [Double]
  ) {
    for (edgeID, value) in vector.edges.sorted(by: { $0.key < $1.key }) where value != 0 {
      indices.append(HighsInt(lp.edgeToCol[edgeID]))
      values.append(value)
    }
    for (colorID, value) in vector.colors.sorted(by: { $0.key < $1.key }) where value != 0 {
      indices.append(HighsInt(lp.colorToCol[colorID]))
      values.append(value)
    }
  }

  private func highsLowerBound(_ value: Double?) -> Double {
    value ?? -Self.infinity
  }

  private func highsUpperBound(_ value: Double?) -> Double {
    value ?? Self.infinity
  }

  private func checkStatus(_ status: HighsInt, operation: String) throws {
    guard status == kHighsStatusOk else {
      throw Error.highsError(operation: operation, status: status)
    }
  }
}
