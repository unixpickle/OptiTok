import Foundation

public struct Tokenizer {

  public static let NanochatPretokenizer = try! NSRegularExpression(
    pattern:
      "'(?i:[sdmt]|ll|ve|re)|[^\\r\\n\\p{L}\\p{N}]?+\\p{L}+|\\p{N}{1,2}| ?[^\\s\\p{L}\\p{N}]++[\\r\\n]*|\\s*[\\r\\n]|\\s+(?!\\S)|\\s+",
    options: []
  )

  public typealias TokenID = Int
  public var vocab: [[UInt8]]
  public var pretokenizer: NSRegularExpression?

  public init(vocab: [[UInt8]], pretokenizer: NSRegularExpression? = nil) {
    self.vocab = vocab
    self.pretokenizer = pretokenizer
  }

  public static func rounding(
    solution: LP.Vector,
    graph: Graph,
    vocabLimit: Int,
    pretokenizer: NSRegularExpression? = nil
  ) -> Tokenizer {
    var vocab = [[UInt8]]()
    for (colorID, weight) in solution.colors.sorted(by: { (c0, c1) in
      let (colorID0, score0) = c0
      let (colorID1, score1) = c1
      let key0 = (score0, graph.colorWeights[colorID0], graph.colors[colorID0].count)
      let key1 = (score1, graph.colorWeights[colorID1], graph.colors[colorID1].count)
      return key0 > key1
    }) {
      if weight == 0 || vocab.count == vocabLimit {
        break
      }
      vocab.append(graph.colors[colorID])
    }
    return Tokenizer(vocab: vocab, pretokenizer: pretokenizer)
  }

  /// Split up the text into words that can be passed to encode().
  public func pretokenize(text: String) -> [[UInt8]] {
    guard let pretokenizer = pretokenizer else {
      return [Array(text.utf8)]
    }
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = pretokenizer.matches(in: text, options: [], range: nsRange)
    return matches.map { match in
      return Array(String(text[Range(match.range, in: text)!]).utf8)
    }
  }

  /// Find a shortest-path encoding for the word.
  public func encode(word: [UInt8]) -> [TokenID] {
    var posToOptimal = [0: [TokenID]()]
    for start in word.indices {
      guard let baseTok = posToOptimal[start] else {
        continue
      }
      for (i, v) in vocab.enumerated() {
        if !word[start...].starts(with: v) {
          continue
        }
        let newPos = start + v.count
        if let existing = posToOptimal[newPos], existing.count < baseTok.count + 1 {
          continue
        }
        posToOptimal[newPos] = baseTok + [i]
      }
    }
    guard let result = posToOptimal[word.count] else {
      fatalError("cannot tokenize byte sequence: \(word)")
    }
    return result
  }

}
