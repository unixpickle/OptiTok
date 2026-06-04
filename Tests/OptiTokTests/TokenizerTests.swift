import Testing

@testable import OptiTok

@Test func testPretokenize() async throws {
  let t = Tokenizer(vocab: [[]], pretokenizer: Tokenizer.NanochatPretokenizer)
  let tokens = t.pretokenize(text: "Hello, world! This is\na test.")
  print(tokens.map { String(decoding: $0, as: UTF8.self) })
  #expect(
    tokens
      == [
        "Hello", ",", " world", "!", " This", " is", "\n", "a", " test", ".",
      ].map {
        Array($0.utf8)
      }
  )
}

@Test func testTokenize() async throws {
  let bytes = (0..<256).map { [UInt8($0)] }
  var runs = [
    "hel", "llo", "he", "wo", "rl", "orld"
  ].map {
    Array($0.utf8)
  }
  var t = Tokenizer(vocab: bytes + runs, pretokenizer: Tokenizer.NanochatPretokenizer)
  var tokens = t.pretokenize(text: "hello world").map { t.encode(word: $0) }
  #expect(tokens == [[258, 257], [0x20, 0x77, 256+5]])

  runs = [
    "hel", "llo", "he", " wo", "rl", "orld"
  ].map {
    Array($0.utf8)
  }
  t = Tokenizer(vocab: bytes + runs, pretokenizer: Tokenizer.NanochatPretokenizer)
  tokens = t.pretokenize(text: "hello world").map { t.encode(word: $0) }
  #expect(tokens == [[258, 257], [259, 260, 0x64]])

  runs = [
    "hel", "llo", "he", " wo", "orld"
  ].map {
    Array($0.utf8)
  }
  t = Tokenizer(vocab: bytes + runs, pretokenizer: Tokenizer.NanochatPretokenizer)
  tokens = t.pretokenize(text: "hello world").map { t.encode(word: $0) }
  #expect(tokens == [[258, 257], [0x20, 0x77, 260]])
}
