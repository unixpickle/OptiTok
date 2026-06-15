public struct Graph: Codable {

  public typealias WordID = Int
  public typealias EdgeID = Int
  public typealias ColorID = Int

  public struct Edge: Hashable, Codable {
    public let word: WordID
    public let start: Int
    public let length: Int
    public let color: ColorID
  }

  public struct Word: Hashable, Codable {
    public let bytes: [UInt8]
    public let weight: Double
  }

  public var colors: [[UInt8]]
  public var words: [Word]
  public var edges: [Edge]

  /// Mapping of wordID to edges of the word.
  public var wordToEdges: [Set<EdgeID>]

  /// Mapping of edgeID to overlapping (conflicting) edges.
  public var overlap: [Set<EdgeID>]

  /// Initialize the graph from a corpus of words, some of which may repeat arbitrarily many times.
  public init(
    corpus: [[UInt8]], maxColorLen: Int, minColorOccurrences: Int, forceSingleBytes: Bool = true
  ) {
    var counts = [[UInt8]: Int]()
    for w in corpus {
      counts[w, default: 0] += 1
    }
    words = counts.map { (k, v) in Word(bytes: k, weight: Double(v)) }

    var colorMap = [[UInt8]: ColorID]()
    var startColors = [[UInt8]]()
    if forceSingleBytes {
      startColors.append(contentsOf: (0...255).map { [UInt8($0)] })
      colorMap = .init(uniqueKeysWithValues: zip(startColors, startColors.indices))
    }
    func lookupColor(bytes: [UInt8]) -> ColorID {
      if let c = colorMap[bytes] {
        return c
      }
      startColors.append(bytes)
      colorMap[bytes] = colorMap.count
      return colorMap.count - 1
    }

    var startEdges = [Edge]()
    var colorCount = [ColorID: Double]()
    for (wordID, word) in words.enumerated() {
      for i in word.bytes.indices {
        for j in (i + 1)...min(i + maxColorLen, word.bytes.count) {
          let colorBytes = [UInt8](word.bytes[i..<j])
          let color = lookupColor(bytes: colorBytes)
          colorCount[color, default: 0] += word.weight
          startEdges.append(Edge(word: wordID, start: i, length: j - i, color: color))
        }
      }
    }

    var filteredColorIDMap = [ColorID: ColorID]()
    colors = [[UInt8]]()
    for (colorID, colorBytes) in startColors.enumerated() {
      let count = colorCount[colorID, default: 0]
      // Don't skip single bytes, because then there will be nothing to support
      // the words where these undercounted single bytes occur.
      if colorBytes.count > 1 && count < Double(minColorOccurrences) {
        continue
      }
      filteredColorIDMap[colorID] = colors.count
      colors.append(colorBytes)
    }

    edges = startEdges.compactMap { edge in
      if let newColor = filteredColorIDMap[edge.color] {
        Edge(word: edge.word, start: edge.start, length: edge.length, color: newColor)
      } else {
        nil
      }
    }

    wordToEdges = words.map { _ in [] }
    for (edgeID, edge) in edges.enumerated() {
      wordToEdges[edge.word].insert(edgeID)
    }

    overlap = edges.map { _ in [] }
    for wordEdges in wordToEdges {
      var posToEdges = [Int: Set<EdgeID>]()
      for edgeID in wordEdges {
        let edge = edges[edgeID]
        for i in edge.start..<(edge.start + edge.length) {
          posToEdges[i, default: .init()].insert(edgeID)
        }
        for overlapSet in posToEdges.values {
          for x in overlapSet {
            for y in overlapSet {
              if x != y {
                overlap[x].insert(y)
              }
            }
          }
        }
      }
    }
  }

  public enum VertexPosition {
    case start
    case middle
    case end
  }

  public typealias Vertex = (pos: VertexPosition, incoming: Set<EdgeID>, outgoing: Set<EdgeID>)

  public func vertices() -> AnySequence<Vertex> {
    AnySequence(
      wordToEdges.lazy.enumerated().flatMap { (wordID, wordEdges) in
        var posToIncoming = [Int: Set<EdgeID>]()
        var posToOutgoing = [Int: Set<EdgeID>]()
        for edgeID in wordEdges {
          let edge = edges[edgeID]
          posToOutgoing[edge.start, default: .init()].insert(edgeID)
          posToIncoming[edge.start + edge.length, default: .init()].insert(edgeID)
        }
        let word = words[wordID]
        return (0...word.bytes.count).map { idx in
          let pos: VertexPosition =
            if idx == 0 {
              .start
            } else if idx == word.bytes.count {
              .end
            } else {
              .middle
            }
          return (
            pos: pos, incoming: posToIncoming[idx, default: []],
            outgoing: posToOutgoing[idx, default: []]
          )
        }
      })
  }

}
