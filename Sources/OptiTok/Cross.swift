public func randomCrosses<C: RandomAccessCollection>(
  _ count: Int,
  _ collections: [C]
) -> [[C.Element]] {
  guard count > 0 else {
    return []
  }

  let counts = collections.map(\.count)
  if counts.contains(0) {
    return []
  }

  let (doubleCount, overflow) = count.multipliedReportingOverflow(by: 2)
  let productLimit = overflow ? Int.max : max(1, doubleCount)
  let totalCount = cappedProduct(counts, limit: productLimit)
  if totalCount != nil && count >= totalCount! / 2 {
    var offsets = allCrossOffsets(counts)
    offsets.shuffle()
    return offsets.prefix(count).map { offsetsToElements($0, collections) }
  }

  var seen = Set<[Int]>()
  var rows = [[C.Element]]()
  rows.reserveCapacity(count)
  while rows.count < count {
    let offsets = counts.map { Int.random(in: 0..<$0) }
    if seen.insert(offsets).inserted {
      rows.append(offsetsToElements(offsets, collections))
    }
  }
  return rows
}

private func cappedProduct(_ values: [Int], limit: Int) -> Int? {
  var result = 1
  for value in values {
    let (next, overflow) = result.multipliedReportingOverflow(by: value)
    if overflow || next > limit {
      return nil
    }
    result = next
  }
  return result
}

private func allCrossOffsets(_ counts: [Int]) -> [[Int]] {
  if counts.isEmpty {
    return [[]]
  }

  var result = [[Int]]()

  func visit(_ index: Int, _ offsets: [Int]) {
    if index == counts.count {
      result.append(offsets)
      return
    }
    for offset in 0..<counts[index] {
      visit(index + 1, offsets + [offset])
    }
  }

  visit(0, [])
  return result
}

private func offsetsToElements<C: RandomAccessCollection>(
  _ offsets: [Int],
  _ collections: [C]
) -> [C.Element] {
  zip(offsets, collections).map { offset, collection in
    collection[collection.index(collection.startIndex, offsetBy: offset)]
  }
}
