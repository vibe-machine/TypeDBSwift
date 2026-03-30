# Contributing to TypeDBSwift

Thanks for your interest in contributing to TypeDBSwift!

## Development Setup

```bash
git clone https://github.com/vibe-machine/TypeDBSwift.git
cd TypeDBSwift
./scripts/fetch-driver.sh
swift build
```

For detailed build instructions, see [BUILDING.md](BUILDING.md).

## Running Tests

Unit tests (no server required):

```bash
./scripts/test.sh --unit
```

Integration tests (requires TypeDB server at `localhost:1729`):

```bash
./scripts/test.sh --integration
```

## Submitting Changes

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request against `main`

## Code Style

- Follow existing patterns in the codebase
- Use Swift naming conventions
- Add doc comments to public API surface
- Use `TypeDBError.checkAndThrow()` after C API calls

## License

By contributing, you agree that your contributions will be licensed under the [Apache 2.0 License](LICENSE).
