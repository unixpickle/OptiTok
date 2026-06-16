public struct BitmapSet {
  public let edges: [Graph.EdgeID]
  public let colors: [Graph.ColorID]
  public var bitmaps: Set<Bitmap>

  public let edgeToIdx: [Graph.EdgeID: Int]
  public let colorToIdx: [Graph.ColorID: Int]

  public init(edges: [Graph.EdgeID], colors: [Graph.ColorID], bitmaps: Set<Bitmap> = []) {
    self.edges = edges
    self.colors = colors
    self.bitmaps = bitmaps
    edgeToIdx = Dictionary(uniqueKeysWithValues: zip(edges, edges.indices))
    colorToIdx = Dictionary(uniqueKeysWithValues: zip(colors, colors.indices))
  }

  public func projected(
    newEdges edges: some Sequence<Graph.EdgeID>,
    newColors colors: some Sequence<Graph.ColorID>
  ) -> BitmapSet {
    let edgeSet = Set(edges)
    let colorSet = Set(colors)
    var sourceIndices = [Int]()
    for (i, edge) in self.edges.enumerated() {
      if edgeSet.contains(edge) {
        sourceIndices.append(i)
      }
    }
    for (i, color) in self.colors.enumerated() {
      if colorSet.contains(color) {
        sourceIndices.append(i + self.edges.count)
      }
    }
    return BitmapSet(
      edges: Array(edges),
      colors: Array(colors),
      bitmaps: Set(
        bitmaps.map { bmp in
          var newBitmap = Bitmap(count: sourceIndices.count)
          for (i, j) in sourceIndices.enumerated() {
            newBitmap[i] = bmp[j]
          }
          return newBitmap
        }
      )
    )
  }
}

public struct Bitmap: Hashable {
  public let count: Int
  public var pattern: [UInt64]

  public init(count: Int) {
    self.count = count
    let wordCount = (count / 64) + (count % 64 == 0 ? 0 : 1)
    pattern = [UInt64](repeating: 0, count: wordCount)
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
