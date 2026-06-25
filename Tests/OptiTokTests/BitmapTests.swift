import Testing

@testable import OptiTok

@Test func testBitmapDescription() async throws {
  let bitmap = Bitmap(bits: [false, true, true, true, false, true, false, true])
  #expect(String(describing: bitmap) == "Bitmap(01110101)")
}

@Test func testBitmapSetIndexMapsUseSortedOrder() async throws {
  let bitmapSet = BitmapSet(edges: [2, 0, 1], colors: [5, 3])
  #expect(bitmapSet.edges == [0, 1, 2])
  #expect(bitmapSet.colors == [3, 5])
  #expect(bitmapSet.edgeToIdx == [0: 0, 1: 1, 2: 2])
  #expect(bitmapSet.colorToIdx == [3: 3, 5: 4])
}

@Test func testBitmapSetProjectionUsesSortedOrder() async throws {
  var bitmapSet = BitmapSet(edges: [2, 0, 1], colors: [5, 3])
  var bitmap = Bitmap(count: bitmapSet.edges.count + bitmapSet.colors.count)
  bitmap[bitmapSet.edgeToIdx[0]!] = true
  bitmap[bitmapSet.edgeToIdx[2]!] = true
  bitmap[bitmapSet.colorToIdx[5]!] = true
  bitmapSet.bitmaps.insert(bitmap)

  #expect(
    bitmapSet.projected(edges: [2, 0], colors: [5])
      == BitmapSet(
        edges: [0, 2],
        colors: [5],
        bitmaps: [
          Bitmap(bits: [true, true, true])
        ]
      )
  )
}

@Test func testBitmapSetCrossUsesSortedOrder() async throws {
  var bs1 = BitmapSet(edges: [2, 0], colors: [4])
  var bmp1 = Bitmap(count: bs1.edges.count + bs1.colors.count)
  bmp1[bs1.edgeToIdx[0]!] = true
  bmp1[bs1.colorToIdx[4]!] = true
  bs1.bitmaps.insert(bmp1)

  var bs2 = BitmapSet(edges: [1, 0], colors: [4, 3])
  var bmp2 = Bitmap(count: bs2.edges.count + bs2.colors.count)
  bmp2[bs2.edgeToIdx[0]!] = true
  bmp2[bs2.edgeToIdx[1]!] = true
  bmp2[bs2.colorToIdx[4]!] = true
  bs2.bitmaps.insert(bmp2)

  #expect(
    bs1.cross(bs2)
      == BitmapSet(
        edges: [0, 1, 2],
        colors: [3, 4],
        bitmaps: [
          Bitmap(bits: [true, true, false, false, true])
        ]
      )
  )
}

@Test func testBitmapSetCross1() async throws {
  let bs1 = BitmapSet(
    edges: [0, 1],
    colors: [0, 1],
    bitmaps: [
      Bitmap(bits: [false, true, false, false])
    ]
  )
  let bs2 = BitmapSet(
    edges: [2, 3],
    colors: [0, 1],
    bitmaps: [
      Bitmap(bits: [true, false, false, false]),
      Bitmap(bits: [false, false, false, false]),
      Bitmap(bits: [false, true, true, false]),
    ]
  )
  #expect(
    bs1.cross(bs2)
      == BitmapSet(
        edges: [0, 1, 2, 3],
        colors: [0, 1],
        bitmaps: [
          Bitmap(bits: [false, true, true, false, false, false]),
          Bitmap(bits: [false, true, false, false, false, false]),
        ]
      )
  )
}

@Test func testBitmapSetCross2() async throws {
  let bs1 = BitmapSet(
    edges: [0, 1],
    colors: [0, 1],
    bitmaps: [
      Bitmap(bits: [false, true, false, false]),
      Bitmap(bits: [true, true, false, false]),
      Bitmap(bits: [true, false, true, false]),
    ]
  )
  let bs2 = BitmapSet(
    edges: [2, 3],
    colors: [0, 1],
    bitmaps: [
      Bitmap(bits: [true, false, false, false]),
      Bitmap(bits: [false, false, false, false]),
      Bitmap(bits: [false, true, true, false]),
    ]
  )
  #expect(
    bs1.cross(bs2)
      == BitmapSet(
        edges: [0, 1, 2, 3],
        colors: [0, 1],
        bitmaps: [
          Bitmap(bits: [false, true, true, false, false, false]),
          Bitmap(bits: [false, true, false, false, false, false]),
          Bitmap(bits: [true, true, true, false, false, false]),
          Bitmap(bits: [true, true, false, false, false, false]),
          Bitmap(bits: [true, false, false, true, true, false]),
        ]
      )
  )
}
