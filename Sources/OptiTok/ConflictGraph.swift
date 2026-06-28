public struct ConflictGraph<V> where V: Comparable, V: Hashable {
  public var adjacency: [V: Set<V>]

  public init(pairs: some Sequence<(V, V)>) {
    adjacency = [:]
    for pair in pairs {
      adjacency[pair.0, default: []].insert(pair.1)
      adjacency[pair.1, default: []].insert(pair.0)
    }
  }

  /// Find non-repeating cycles of the given length (deduped by lowest start value).
  public func cycles(_ n: Int) -> AnyIterator<[V]> {
    return AnyIterator(
      adjacency.keys.lazy.flatMap({ start in dfs([start], [start], n) }).makeIterator()
    )
  }

  private func dfs(_ cur: [V], _ curSet: Set<V>, _ n: Int) -> AnyIterator<[V]> {
    if cur.count == n {
      if hasEdge(from: cur.last!, to: cur.first!) {
        return AnyIterator([cur].makeIterator())
      } else {
        return AnyIterator([[V]]().makeIterator())
      }
    }
    let seq = adjacency[cur.last!, default: []].lazy.flatMap { neighbor -> AnyIterator<[V]> in
      if curSet.contains(neighbor) || neighbor < cur.first! {
        return AnyIterator([[V]]().makeIterator())
      }
      return dfs(cur + [neighbor], curSet.union([neighbor]), n)
    }
    return AnyIterator(seq.makeIterator())
  }

  private func hasEdge(from: V, to: V) -> Bool {
    adjacency[from, default: .init()].contains(to)
  }
}
