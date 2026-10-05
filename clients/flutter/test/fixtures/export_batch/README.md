# Export byte goldens

These gzip files contain complete JSON, CSV and XLSX output bytes captured before
the batch-write optimization. Tests decompress them and compare every byte,
including ZIP headers and worksheet XML, without rewriting the goldens.

The deterministic ledger in `test/data/export_batch_test.dart` covers 0, 1, 499,
500, 501 and 1000 transactions. It includes all three transaction types, transfer
fees, tied dates, Unicode, formula-like notes, quotes, CR/LF and XML control
characters. The `1000-filtered-*` cases use a note filter and preserve the existing
date order; unfiltered JSON preserves insertion order.

Original sources at capture:

- `lib/data/sqlite_snapshots.dart`: `545415b73ae69a187f0e6951ce6260213e14df66a17d0ceac3ae098b1924c4a0`
- `lib/data/ledger_exports.dart`: `a3bda1b71ddb8c234df7fc76b489a4d1390a7d36c7cb8c438b35576f098d73cd`

Capture verification: `.qa/flutter-export-batch-baseline.log`, 11 tests passed
before production source changes. The capture switch was removed from the final
tests; normal verification only reads the committed golden bytes.
