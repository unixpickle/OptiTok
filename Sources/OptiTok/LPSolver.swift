import CSoPlex
import Foundation

public class SoPlexSolver {

  public enum Error: Swift.Error, CustomStringConvertible {
    case couldNotCreateSolver
    case soPlexError(operation: String, status: Int, message: String)
    case modelNotOptimal(status: Int, message: String)
    case missingSolution(message: String)

    public var description: String {
      switch self {
      case .couldNotCreateSolver:
        return "could not create SoPlex solver"
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
    public var perturbation: Double

    public init(
      logToConsole: Bool = false,
      perturbation: Double = 0
    ) {
      self.logToConsole = logToConsole
      self.perturbation = perturbation
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

  private static let infinity = 1.0e30

  private let model: OpaquePointer
  private var _lp: LP
  private var config: Config
  private var pendingBasis: Basis? = nil

  public var lp: LP { _lp }

  public init(_ lp: LP, config: Config = Config()) throws {
    guard let model = CSoPlex_newModel(config.logToConsole ? 1 : 0) else {
      throw Error.couldNotCreateSolver
    }
    self.model = model
    self._lp = lp
    self.config = config

    do {
      try initializeModel()
    } catch {
      CSoPlex_deleteModel(model)
      throw error
    }
  }

  deinit {
    CSoPlex_deleteModel(model)
  }

  public func add(constraint: LP.Constraint) throws {
    try add(constraints: [constraint])
  }

  public func add(constraints: [LP.Constraint]) throws {
    if constraints.isEmpty {
      return
    }

    try detachBasisForMutation()
    try addRowsToModel(constraints, operation: "add rows")

    let expectedRows = CInt(_lp.constraints.count + constraints.count)
    guard CSoPlex_numberRows(model) == expectedRows else {
      throw Error.soPlexError(
        operation: "add rows",
        status: Int(CSoPlex_numberRows(model)),
        message: lastErrorMessage()
      )
    }
    if pendingBasis != nil {
      pendingBasis!.rows.append(
        contentsOf: Array(repeating: CSoPlex_basicBasisStatus(), count: constraints.count)
      )
    }
    _lp.constraints.append(contentsOf: constraints)
  }

  public func solve() throws -> LP.Vector {
    try applyPendingBasis()

    let status = CSoPlex_optimize(model)
    guard CSoPlex_isOptimalStatus(status) != 0 else {
      if status < 0 {
        throw Error.soPlexError(operation: "optimize", status: Int(status), message: lastErrorMessage())
      } else {
        throw Error.modelNotOptimal(status: Int(status), message: lastErrorMessage())
      }
    }
    pendingBasis = nil

    var colValues = Array(repeating: 0.0, count: columnCount)
    let solutionStatus = colValues.withUnsafeMutableBufferPointer { buffer in
      CSoPlex_getPrimal(model, buffer.baseAddress, CInt(buffer.count))
    }
    guard solutionStatus == 0 else {
      throw Error.missingSolution(message: lastErrorMessage())
    }

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

  public func basis() throws -> Basis? {
    if let pendingBasis {
      return pendingBasis
    }
    if CSoPlex_hasBasis(model) == 0 {
      return nil
    }

    let rowCount = Int(CSoPlex_numberRows(model))
    let colCount = Int(CSoPlex_numberCols(model))
    guard rowCount >= 0, colCount >= 0 else {
      throw Error.soPlexError(
        operation: "get basis dimensions",
        status: rowCount < 0 ? rowCount : colCount,
        message: lastErrorMessage()
      )
    }

    var rows = Array(repeating: Int32(0), count: rowCount)
    var columns = Array(repeating: Int32(0), count: colCount)
    let status = rows.withUnsafeMutableBufferPointer { rowBuffer in
      columns.withUnsafeMutableBufferPointer { columnBuffer in
        CSoPlex_getBasis(
          model,
          rowBuffer.baseAddress,
          CInt(rowCount),
          columnBuffer.baseAddress,
          CInt(colCount)
        )
      }
    }
    guard status == 0 else {
      throw Error.soPlexError(operation: "get basis", status: Int(status), message: lastErrorMessage())
    }
    return Basis(rows: rows, columns: columns)
  }

  public func restore(basis: Basis) throws {
    let modelRows = Int(CSoPlex_numberRows(model))
    let modelColumns = Int(CSoPlex_numberCols(model))
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

    let modelRows = Int(CSoPlex_numberRows(model))
    let modelColumns = Int(CSoPlex_numberCols(model))
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
      throw Error.soPlexError(operation: "set basis", status: Int(status), message: lastErrorMessage())
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

  private var columnCount: Int {
    lp.graph.edges.count + lp.graph.colors.count
  }

  private func initializeModel() throws {
    var colCost = Array(repeating: 0.0, count: columnCount)
    for (edgeID, value) in lp.objective.edges {
      colCost[lp.edgeToCol[edgeID]] = value - Double.random(in: 0...config.perturbation)
    }
    for (colorID, value) in lp.objective.colors {
      colCost[lp.colorToCol[colorID]] = value - Double.random(in: 0...config.perturbation)
    }

    let colLower = Array(repeating: 0.0, count: columnCount)
    let colUpper = Array(repeating: 1.0, count: columnCount)
    let columnStatus = colCost.withUnsafeBufferPointer { colCostBuffer in
      colLower.withUnsafeBufferPointer { colLowerBuffer in
        colUpper.withUnsafeBufferPointer { colUpperBuffer in
          CSoPlex_addColumns(
            model,
            colCostBuffer.baseAddress,
            colLowerBuffer.baseAddress,
            colUpperBuffer.baseAddress,
            CInt(columnCount)
          )
        }
      }
    }
    guard columnStatus == 0 else {
      throw Error.soPlexError(
        operation: "add columns",
        status: Int(columnStatus),
        message: lastErrorMessage()
      )
    }

    try addRowsToModel(lp.constraints, operation: "add initial rows")
  }

  private func addRowsToModel(_ constraints: [LP.Constraint], operation: String) throws {
    let matrix = buildRowwiseMatrix(constraints)
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
                  CInt(constraints.count),
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

  private func buildRowwiseMatrix(_ constraints: [LP.Constraint]) -> (
    starts: [CInt], lengths: [CInt], indices: [CInt], values: [Double], lower: [Double],
    upper: [Double]
  ) {
    var starts = [CInt]()
    starts.reserveCapacity(constraints.count)
    var lengths = [CInt]()
    lengths.reserveCapacity(constraints.count)
    var indices = [CInt]()
    var values = [Double]()
    var lower = [Double]()
    lower.reserveCapacity(constraints.count)
    var upper = [Double]()
    upper.reserveCapacity(constraints.count)

    for constraint in constraints {
      let start = indices.count
      starts.append(CInt(start))
      appendEntries(for: constraint.coeffs, indices: &indices, values: &values)
      lengths.append(CInt(indices.count - start))
      lower.append(soPlexLowerBound(constraint.lowerBound))
      upper.append(soPlexUpperBound(constraint.upperBound))
    }
    return (starts, lengths, indices, values, lower, upper)
  }

  private func appendEntries(
    for vector: LP.Vector,
    indices: inout [CInt],
    values: inout [Double]
  ) {
    for (edgeID, value) in vector.edges.sorted(by: { $0.key < $1.key }) where value != 0 {
      indices.append(CInt(lp.edgeToCol[edgeID]))
      values.append(value)
    }
    for (colorID, value) in vector.colors.sorted(by: { $0.key < $1.key }) where value != 0 {
      indices.append(CInt(lp.colorToCol[colorID]))
      values.append(value)
    }
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
