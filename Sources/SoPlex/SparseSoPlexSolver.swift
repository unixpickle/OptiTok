import CSoPlex

public final class SparseSoPlexSolver {

  public enum Error: Swift.Error, CustomStringConvertible {
    case couldNotCreateSolver
    case invalidRowEntry(row: Int, column: Int, columnCount: Int)
    case soPlexError(operation: String, status: Int, message: String)
    case modelNotOptimal(status: Int, message: String)
    case missingSolution(message: String)

    public var description: String {
      switch self {
      case .couldNotCreateSolver:
        return "could not create SoPlex solver"
      case .invalidRowEntry(let row, let column, let columnCount):
        return "row \(row) references column \(column), but model has \(columnCount) columns"
      case .soPlexError(let operation, let status, let message):
        return "SoPlex \(operation) failed with status \(status): \(message)"
      case .modelNotOptimal(let status, let message):
        return "SoPlex model status is not optimal: status=\(status): \(message)"
      case .missingSolution(let message):
        return "SoPlex did not return a primal solution: \(message)"
      }
    }
  }

  public struct Config: Codable {
    public var logToConsole: Bool

    public init(logToConsole: Bool = false) {
      self.logToConsole = logToConsole
    }
  }

  public struct Column: Codable {
    public var objective: Double
    public var lowerBound: Double?
    public var upperBound: Double?

    public init(objective: Double, lowerBound: Double? = 0, upperBound: Double? = nil) {
      self.objective = objective
      self.lowerBound = lowerBound
      self.upperBound = upperBound
    }
  }

  public struct RowEntry: Codable {
    public var column: Int
    public var value: Double

    public init(column: Int, value: Double) {
      self.column = column
      self.value = value
    }
  }

  public struct Row: Codable {
    public var entries: [RowEntry]
    public var lowerBound: Double?
    public var upperBound: Double?

    public init(entries: [RowEntry], lowerBound: Double? = nil, upperBound: Double? = nil) {
      self.entries = entries
      self.lowerBound = lowerBound
      self.upperBound = upperBound
    }
  }

  public struct Basis: Codable {
    public var rows: [Int32]
    public var columns: [Int32]

    public init(rows: [Int32], columns: [Int32]) {
      self.rows = rows
      self.columns = columns
    }
  }

  public static let infinity = CSoPlex_infinity()

  private let model: OpaquePointer
  private var pendingBasis: Basis? = nil

  public var rowCount: Int { Int(CSoPlex_numberRows(model)) }
  public var columnCount: Int { Int(CSoPlex_numberCols(model)) }

  public init(
    columns: [Column] = [],
    rows: [Row] = [],
    config: Config = Config()
  ) throws {
    guard let model = CSoPlex_newModel(config.logToConsole ? 1 : 0) else {
      throw Error.couldNotCreateSolver
    }
    self.model = model

    do {
      try add(columns: columns)
      try add(rows: rows)
    } catch {
      CSoPlex_deleteModel(model)
      throw error
    }
  }

  deinit {
    CSoPlex_deleteModel(model)
  }

  public func add(column: Column) throws {
    try add(columns: [column])
  }

  public func add(columns: [Column]) throws {
    if columns.isEmpty {
      return
    }

    try detachBasisForMutation()

    let oldColumnCount = columnCount
    let objectives = columns.map(\.objective)
    let lowers = columns.map { soPlexLowerBound($0.lowerBound) }
    let uppers = columns.map { soPlexUpperBound($0.upperBound) }
    let status = objectives.withUnsafeBufferPointer { objectiveBuffer in
      lowers.withUnsafeBufferPointer { lowerBuffer in
        uppers.withUnsafeBufferPointer { upperBuffer in
          CSoPlex_addColumns(
            model,
            objectiveBuffer.baseAddress,
            lowerBuffer.baseAddress,
            upperBuffer.baseAddress,
            CInt(columns.count)
          )
        }
      }
    }
    guard status == 0 else {
      throw Error.soPlexError(
        operation: "add columns",
        status: Int(status),
        message: lastErrorMessage()
      )
    }

    let expectedColumnCount = oldColumnCount + columns.count
    guard columnCount == expectedColumnCount else {
      throw Error.soPlexError(
        operation: "add columns",
        status: columnCount,
        message: lastErrorMessage()
      )
    }
    pendingBasis = nil
  }

  public func add(row: Row) throws {
    try add(rows: [row])
  }

  public func add(rows: [Row]) throws {
    if rows.isEmpty {
      return
    }

    try validate(rows: rows)
    try detachBasisForMutation()
    let oldRowCount = rowCount
    try addRowsToModel(rows, operation: "add rows")
    let expectedRows = oldRowCount + rows.count
    guard rowCount == expectedRows else {
      throw Error.soPlexError(
        operation: "add rows",
        status: rowCount,
        message: lastErrorMessage()
      )
    }

    if pendingBasis != nil {
      pendingBasis!.rows.append(
        contentsOf: Array(repeating: CSoPlex_basicBasisStatus(), count: rows.count)
      )
    }
  }

  public func solve() throws -> [Double] {
    try applyPendingBasis()

    let status = CSoPlex_optimize(model)
    guard CSoPlex_isOptimalStatus(status) != 0 else {
      if status < 0 {
        throw Error.soPlexError(
          operation: "optimize", status: Int(status), message: lastErrorMessage())
      } else {
        throw Error.modelNotOptimal(status: Int(status), message: lastErrorMessage())
      }
    }
    pendingBasis = nil

    var result = Array(repeating: 0.0, count: columnCount)
    let solutionStatus = result.withUnsafeMutableBufferPointer { buffer in
      CSoPlex_getPrimal(model, buffer.baseAddress, CInt(buffer.count))
    }
    guard solutionStatus == 0 else {
      throw Error.missingSolution(message: lastErrorMessage())
    }
    return result
  }

  public func basis() throws -> Basis? {
    if let pendingBasis {
      return pendingBasis
    }
    if CSoPlex_hasBasis(model) == 0 {
      return nil
    }

    let rowCount = self.rowCount
    let columnCount = self.columnCount
    guard rowCount >= 0, columnCount >= 0 else {
      throw Error.soPlexError(
        operation: "get basis dimensions",
        status: rowCount < 0 ? rowCount : columnCount,
        message: lastErrorMessage()
      )
    }

    var rows = Array(repeating: Int32(0), count: rowCount)
    var columns = Array(repeating: Int32(0), count: columnCount)
    let status = rows.withUnsafeMutableBufferPointer { rowBuffer in
      columns.withUnsafeMutableBufferPointer { columnBuffer in
        CSoPlex_getBasis(
          model,
          rowBuffer.baseAddress,
          CInt(rowCount),
          columnBuffer.baseAddress,
          CInt(columnCount)
        )
      }
    }
    guard status == 0 else {
      throw Error.soPlexError(
        operation: "get basis", status: Int(status), message: lastErrorMessage())
    }
    return Basis(rows: rows, columns: columns)
  }

  public func restore(basis: Basis) throws {
    let modelRows = rowCount
    let modelColumns = columnCount
    guard basis.rows.count == modelRows, basis.columns.count == modelColumns else {
      throw Error.soPlexError(
        operation: "set basis",
        status: -1,
        message:
          "basis dimensions rows=\(basis.rows.count) columns=\(basis.columns.count) do not match model rows=\(modelRows) columns=\(modelColumns)"
      )
    }

    pendingBasis = basis
  }

  private func applyPendingBasis() throws {
    guard let pendingBasis else {
      return
    }

    let modelRows = rowCount
    let modelColumns = columnCount
    guard pendingBasis.rows.count == modelRows, pendingBasis.columns.count == modelColumns else {
      throw Error.soPlexError(
        operation: "set basis",
        status: -1,
        message:
          "basis dimensions rows=\(pendingBasis.rows.count) columns=\(pendingBasis.columns.count) do not match model rows=\(modelRows) columns=\(modelColumns)"
      )
    }

    let status = pendingBasis.rows.withUnsafeBufferPointer { rowBuffer in
      pendingBasis.columns.withUnsafeBufferPointer { columnBuffer in
        CSoPlex_setBasis(
          model,
          rowBuffer.baseAddress,
          CInt(pendingBasis.rows.count),
          columnBuffer.baseAddress,
          CInt(pendingBasis.columns.count)
        )
      }
    }
    guard status == 0 else {
      throw Error.soPlexError(
        operation: "set basis", status: Int(status), message: lastErrorMessage())
    }
  }

  private func detachBasisForMutation() throws {
    if pendingBasis == nil {
      pendingBasis = try basis()
    }
    if CSoPlex_hasBasis(model) != 0 {
      let status = CSoPlex_clearBasis(model)
      guard status == 0 else {
        throw Error.soPlexError(
          operation: "clear basis",
          status: Int(status),
          message: lastErrorMessage()
        )
      }
    }
  }

  private func validate(rows: [Row]) throws {
    let columnCount = self.columnCount
    for (rowIndex, row) in rows.enumerated() {
      for entry in row.entries {
        guard entry.column >= 0, entry.column < columnCount else {
          throw Error.invalidRowEntry(
            row: rowIndex,
            column: entry.column,
            columnCount: columnCount
          )
        }
      }
    }
  }

  private func addRowsToModel(_ rows: [Row], operation: String) throws {
    let matrix = buildRowwiseMatrix(rows)
    let rowStatus = matrix.starts.withUnsafeBufferPointer { startBuffer in
      matrix.lengths.withUnsafeBufferPointer { lengthBuffer in
        matrix.indices.withUnsafeBufferPointer { indexBuffer in
          matrix.values.withUnsafeBufferPointer { valueBuffer in
            matrix.lower.withUnsafeBufferPointer { lowerBuffer in
              matrix.upper.withUnsafeBufferPointer { upperBuffer in
                CSoPlex_addRows(
                  model,
                  startBuffer.baseAddress,
                  lengthBuffer.baseAddress,
                  indexBuffer.baseAddress,
                  valueBuffer.baseAddress,
                  lowerBuffer.baseAddress,
                  upperBuffer.baseAddress,
                  CInt(rows.count),
                  CInt(matrix.values.count)
                )
              }
            }
          }
        }
      }
    }
    guard rowStatus == 0 else {
      throw Error.soPlexError(
        operation: operation,
        status: Int(rowStatus),
        message: lastErrorMessage()
      )
    }
  }

  private func buildRowwiseMatrix(_ rows: [Row]) -> (
    starts: [CInt], lengths: [CInt], indices: [CInt], values: [Double], lower: [Double],
    upper: [Double]
  ) {
    var starts = [CInt]()
    starts.reserveCapacity(rows.count)
    var lengths = [CInt]()
    lengths.reserveCapacity(rows.count)
    var indices = [CInt]()
    var values = [Double]()
    var lower = [Double]()
    lower.reserveCapacity(rows.count)
    var upper = [Double]()
    upper.reserveCapacity(rows.count)

    for row in rows {
      let start = indices.count
      starts.append(CInt(start))
      for entry in row.entries.sorted(by: { $0.column < $1.column }) where entry.value != 0 {
        indices.append(CInt(entry.column))
        values.append(entry.value)
      }
      lengths.append(CInt(indices.count - start))
      lower.append(soPlexLowerBound(row.lowerBound))
      upper.append(soPlexUpperBound(row.upperBound))
    }
    return (starts, lengths, indices, values, lower, upper)
  }

  private func soPlexLowerBound(_ value: Double?) -> Double {
    value ?? -Self.infinity
  }

  private func soPlexUpperBound(_ value: Double?) -> Double {
    value ?? Self.infinity
  }

  private func lastErrorMessage() -> String {
    guard let message = CSoPlex_lastError(model), message[0] != 0 else {
      return "no additional details"
    }
    return String(cString: message)
  }

}
