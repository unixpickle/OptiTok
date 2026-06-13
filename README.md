# OptiTok

This is an attempt to cleanly implement ILP with cutting planes for optimal tokenization.

## Dependencies

OptiTok links against the HiGHS C API. On macOS with Homebrew:

```sh
brew install highs
swift test
```

The Swift package defaults to `/opt/homebrew/opt/highs`. If HiGHS is installed somewhere else, set `HIGHS_PREFIX` to the install prefix before building:

```sh
HIGHS_PREFIX=/usr/local/opt/highs swift test
```
