struct TopK<T, P: Comparable>: RandomAccessCollection {
  public typealias Index = Array<(T, P)>.Index

  public let k: Int
  private var _items: [(T, P)]

  public var startIndex: Index { _items.startIndex }
  public var endIndex: Index { _items.endIndex }

  public subscript(position: Index) -> T {
    _items[position].0
  }

  public init(k: Int) {
    self.k = k
    _items = []
  }

  mutating public func add(item: T, priority: P) {
    _items.append((item, priority))
    _items.sort { (x, y) in x.1 > y.1 }
    if _items.count > k {
      _items.remove(at: _items.count - 1)
    }
  }
}
