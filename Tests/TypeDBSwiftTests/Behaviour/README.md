# TypeDB behaviour conformance tests

This directory runs the official [`typedb/typedb-behaviour`][behaviour] BDD
specification against the TypeDBSwift wrapper — the same conformance suite the
official Rust/Python/Java drivers run.

## Layout

- `features/connection/database.feature` — vendored **verbatim** from upstream
  `connection/database.feature`.
- `features/connection/transaction.feature` — vendored **verbatim** from upstream
  `connection/transaction.feature`.
- `features/query/basic.feature` — a curated "basic query" subset authored for
  this driver, written against the same step vocabulary as the connection
  features (see the header note in that file).
- `Gherkin.swift` — a minimal Gherkin parser (Feature / Background / Scenario /
  Scenario Outline + Examples / doc strings / data tables / `; fails` suffixes /
  tags).
- `BehaviourSteps.swift` — the step definitions (the "world") that translate each
  Gherkin step into TypeDBSwift API calls, plus the scenario runner.
- `BehaviourTests.swift` — XCTest entry points, one per feature file.

## Provenance

Vendored from `typedb/typedb-behaviour`, branch `master`. The connection feature
files are unmodified. When refreshing from upstream, re-copy the `connection/`
files verbatim and extend `BehaviourSteps.swift` with any new step phrasings.

## Running

These are integration tests — they require a running TypeDB 3.11+ server
(`localhost:1729`, `admin`/`password`). They run as part of `./scripts/test.sh`
and `--integration`. Each scenario starts from a clean server (all databases are
deleted when the connection opens), matching the upstream "typedb starts" /
"connection has 0 databases" precondition.

[behaviour]: https://github.com/typedb/typedb-behaviour
