# OneApp async driver qualification

The original async repair used TypeDBSwift's single serial queue for asynchronous
C-driver calls. Its QoS was default, explicitly enforced for operations and
cleanup, because the synchronous Rust driver waits on default-QoS network
threads. Higher-priority callers suspend on checked continuations rather than
block a higher-priority worker waiting for the Rust thread.

Batch query execution and migration record import/export now have async
overloads using the same queue as connection, database management, and individual
queries. This keeps an entire batch or record operation serialized without an
application-side parallel queue. Each continuation resumes exactly once with
the operation's original result or error. No cancellation of an already running
FFI call is claimed or introduced.

The reconciliation branch starts from fork main 268aed7. The previously pinned
v0.2.0 snapshot e087174 and exact dirty source/index/history are preserved in
the external one-91i7 reconciliation backup. Main adds BDD tests,
documentation, and test resource exclusions; its production Swift sources are
identical to that snapshot. The parent index still records e087174; the working
submodule checkout is 268aed7 plus the uncommitted repair, so the parent shows
an intentional dirty gitlink difference. The 3.14 upgrade is on
`codex/typedb-3.14-cohort`, based on that fork main with the original async repair
retained. No replacement parent pin has been staged or published.

Qualification is the real Lingo modeling suite with its isolated TypeDB server,
including connection, schema and batch queries, record export/import, and
cleanup. The original failure evidence is the Thread Performance Checker output
in one-swarm-lingo-dynamic-tests-fourth-raw.log. Approval requires that those
workflows pass without the original priority inversion warnings.

## TypeDB 3.14 release reconciliation

The C header and arm64 macOS library come from official driver release 3.14.0;
the read-only upstream source submodule is pinned to
`2e4d2dceecb6d9c92e36893b64b74157921aef85`. Server 3.14.2 is a separate
release train. The package minimum remains macOS 15.5, matching the released
library's Mach-O deployment target.

The artifact manifest at `Sources/CTypeDBDriver/.driver-artifact.json` records
the verified archive digest, released header/library digests, and installed
library digest after normalizing its install name and refreshing its ad-hoc
signature. The fetch script pins the default archive digest before modifying
installed files. Other versions/platforms require an explicitly supplied trusted
archive digest.

A source and exported-symbol audit found all 103 C symbols consumed by the Swift
wrapper in the new header and dylib, with unchanged declarations. Documents
remain C-rendered JSON strings; integer and decimal concepts retain their
Int64 and fixed-point components. No JSON-number conversion or new parallel
FFI path was introduced. A real-server precision regression covers values above
Double's exact integer range and a decimal with 19 fractional digits.

These are source and artifact changes only. Builds, tests, server startup,
database migration and runtime compatibility qualification have not been run.

## Bounded independent operations

The parallelism change replaces the global serial queue with four admitted
blocking operations at default QoS. Admission precedes dispatch: pending jobs,
including jobs for an occupied transaction gate, consume no worker. Each
transaction and its streams serialize query, iteration, finalization and drop;
independent transactions and whole driver-query operations can overlap.
Synchronous APIs use the same handle gates and driver lifetime leases.

Close rejects new borrows and drains executing calls before freeing the driver;
force-close signals the native shared driver first. Owned transaction cleanup
can finish after driver close. Commit/delete consumption and deferred drops
follow the official 3.14 ownership rules. Worker operations consume their own
thread-local C errors, including cleanup errors. Cancellation removes queued
jobs once; cancellation of already running FFI is not claimed.

Four executor regressions cover admission bounds, independent overlap, exclusive
gates, cancellation and cleanup. Three real-server regressions cover reads
during admitted ingestion, shared-stream serialization/finalization, and error
isolation plus close cleanup. They have not been executed. There is no plugin
priority policy or reserved foreground capacity; saturation still queues work.

## Native typed query rows

The fork exposes the official C driver 3.14 GivenRows API through immutable
`TypeDBGivenRows` and typed `TypeDBQueryRequest` inputs. Transaction queries use
the existing transaction/stream gate; mixed plain and row-backed requests use
one driver operation and one transaction, committing only after every request
succeeds. Values are passed through native concept constructors, never rendered
into TypeQL. Decimal strings use the exact native parser.

Each request permits 1...1,000 rows, at most 128 unique bare column names, and
at most 4 MiB of scalar payload. Validation rejects mismatched widths, embedded
NUL bytes, nonfinite doubles, and unsafe datetime ranges before native value
construction. Empty rows are rejected rather than executing the query once;
explicit empty cells require nullable query declarations. There is no arbitrary
aggregate category ceiling or automatic transaction splitting.

Native header-builder finish and row-builder finish consume their builders.
Row construction clones a borrowed header; cell setters clone borrowed concepts,
which Swift then drops. Query submission consumes the completed native rows
exactly once. Failure paths release only allocations still owned by Swift.
Calls, promise resolution and C error consumption retain the existing worker
and lifetime guarantees.

Four new regression methods cover invalid inputs, real native builder cleanup
and decimal-error recovery, exact integer/decimal/text/datetime round trips, and
mixed-batch rollback followed by successful commit. They have not been executed;
no build, parser/runtime qualification or database operation was performed for
this change. GammaCore contracts and Lingo mapping are first-party integration
outside this fork; unsupported providers must reject typed input rather than
interpolating values.
