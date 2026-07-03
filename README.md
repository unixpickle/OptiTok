# OptiTok

This is an attempt to cleanly implement ILP with cutting planes for optimal tokenization.

## Dependencies

OptiTok links against the SoPlex C++ API through a small C bridge. On macOS with Homebrew:

```sh
brew install soplex
swift test
```

The Swift package defaults to Homebrew's `/opt/homebrew/opt` prefixes for SoPlex, Boost, GMP,
and MPFR. If they are installed somewhere else, set the relevant prefix variables before building:

```sh
SOPLEX_PREFIX=/usr/local/opt/soplex \
  BOOST_PREFIX=/usr/local/opt/boost \
  GMP_PREFIX=/usr/local/opt/gmp \
  MPFR_PREFIX=/usr/local/opt/mpfr \
  swift test
```
