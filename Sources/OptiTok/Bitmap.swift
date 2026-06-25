public struct BitmapSet: Equatable {
  /// The edges in the set are always sorted.
  public let edges: [EdgeID]

  /// The colors in the set are always sorted.
  public let colors: [ColorID]

  public var bitmaps: Set<Bitmap>

  public let edgeToIdx: [EdgeID: Int]
  public let colorToIdx: [ColorID: Int]

  public init(
    edges: some Sequence<EdgeID>,
    colors: some Sequence<ColorID>,
    bitmaps: Set<Bitmap> = []
  ) {
    self.edges = edges.sorted()
    self.colors = colors.sorted()
    self.bitmaps = bitmaps
    let edgeCount = self.edges.count
    edgeToIdx = Dictionary(uniqueKeysWithValues: zip(self.edges, self.edges.indices))
    colorToIdx = Dictionary(
      uniqueKeysWithValues: zip(self.colors, self.colors.indices.map { $0 + edgeCount })
    )
  }

  public func projected(
    edges newEdges: some Sequence<EdgeID>,
    colors newColors: some Sequence<ColorID>
  ) -> BitmapSet {
    let (edges, colors, bitmaps) = projectedBitmaps(edges: newEdges, colors: newColors)
    return BitmapSet(
      edges: edges,
      colors: colors,
      bitmaps: Set(bitmaps)
    )
  }

  public func cross(_ other: BitmapSet) -> BitmapSet {
    let sharedEdges = Set(edges).intersection(other.edges)
    let sharedColors = Set(colors).intersection(other.colors)

    // Key each bitmap to the projected dims
    var keyToLeft = [Bitmap: [Bitmap]]()
    for (key, item) in zip(projectedBitmaps(edges: sharedEdges, colors: sharedColors).2, bitmaps) {
      keyToLeft[key, default: []].append(item)
    }

    // Now join the other bitmap set to this one.
    let newEdges = Set(edges).union(other.edges).sorted()
    let newColors = Set(colors).union(other.colors).sorted()
    var newSet = BitmapSet(edges: newEdges, colors: newColors)

    let leftMapping = newSet.map(subEdges: edges, subColors: colors)
    let rightMapping = newSet.map(subEdges: other.edges, subColors: other.colors)

    for (key, rightItem) in zip(
      other.projectedBitmaps(edges: sharedEdges, colors: sharedColors).2, other.bitmaps
    ) {
      for leftItem in keyToLeft[key] ?? [] {
        var newBitmap = Bitmap(count: newEdges.count + newColors.count)
        for (src, dst) in leftMapping.enumerated() {
          newBitmap[dst] = leftItem[src]
        }
        for (src, dst) in rightMapping.enumerated() {
          newBitmap[dst] = rightItem[src]
        }
        newSet.bitmaps.insert(newBitmap)
      }
    }

    return newSet
  }

  private func projectedBitmaps(
    edges newEdges: some Sequence<EdgeID>,
    colors newColors: some Sequence<ColorID>
  ) -> ([EdgeID], [ColorID], AnySequence<Bitmap>) {
    let edgeSet = Set(newEdges)
    let colorSet = Set(newColors)
    let sourceIndices = map(subEdges: newEdges, subColors: newColors)
    return (
      edges.filter(edgeSet.contains),
      colors.filter(colorSet.contains),
      AnySequence(
        bitmaps.lazy.map { bmp in
          var newBitmap = Bitmap(count: sourceIndices.count)
          for (i, j) in sourceIndices.enumerated() {
            newBitmap[i] = bmp[j]
          }
          return newBitmap
        }
      )
    )
  }

  private func map(subEdges: some Sequence<EdgeID>, subColors: some Sequence<ColorID>) -> [Int] {
    let edgeSet = Set(subEdges)
    let colorSet = Set(subColors)
    var sourceIndices = [Int]()
    for (i, edge) in edges.enumerated() {
      if edgeSet.contains(edge) {
        sourceIndices.append(i)
      }
    }
    for (i, color) in colors.enumerated() {
      if colorSet.contains(color) {
        sourceIndices.append(i + self.edges.count)
      }
    }
    return sourceIndices
  }

}

public struct Bitmap: Hashable, CustomStringConvertible {
  public let count: Int
  public var pattern: [UInt64]

  public var bitString: String {
    var result = ""
    result.reserveCapacity(count)
    for i in 0..<count {
      result.append(self[i] ? "1" : "0")
    }
    return result
  }

  public var description: String {
    return "Bitmap(\(bitString))"
  }

  public init(count: Int) {
    self.count = count
    let wordCount = (count / 64) + (count % 64 == 0 ? 0 : 1)
    pattern = [UInt64](repeating: 0, count: wordCount)
  }

  public init(bits: [Bool]) {
    self.count = bits.count
    let wordCount = (count / 64) + (count % 64 == 0 ? 0 : 1)
    pattern = [UInt64](repeating: 0, count: wordCount)
    for (i, x) in bits.enumerated() {
      self[i] = x
    }
  }

  public subscript(index: Int) -> Bool {
    get {
      return pattern[index / 64] & (1 << (index % 64)) != 0
    }

    set {
      if newValue {
        pattern[index / 64] |= (1 << (index % 64))
      } else {
        pattern[index / 64] &= ~(UInt64(1) << (index % 64))
      }
    }
  }

}
