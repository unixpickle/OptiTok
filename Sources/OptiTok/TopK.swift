struct TopK<T, P: Comparable> {
  public let k: Int
  private var _items: [(T, P)]

  public var items: [T] { _items.map { $0.0 } }

  public init(k: Int) {
    self.k = k
    _items = []
  }

  mutating public func add(item: T, priority: P) {
    _items.append((item, priority))
    _items.sort { (x, y) in x.1 > y.1 }
    if _items.count > k {
      _items.remove(at: items.count - 1)
    }
  }
}
