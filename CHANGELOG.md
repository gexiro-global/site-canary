# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- Standardize the canonical test runner on an explicit Bash shebang and direct execution.
- Fail closed on request transport errors, empty/missing response metadata, non-2xx status, content failures, and invalid/excessive latency.
- Make marker checks literal and case-sensitive; accumulate comma-separated and repeated `forbid` values and reject explicitly empty markers.
- Harden configuration parsing for whitespace, CRLF, escaped pipes, equals signs, duplicates, and unknown keys.
- JSON-encode webhook text and HTML-escape Telegram text without exposing transport credentials.
- Reject unsafe state traversal, symlinks, and non-regular files; use private atomic state files and serialized transitions for concurrent runs.
- Guarantee an explicit summary for normal, dry-run, test, and error outcomes.

## [0.1.0]

- Initial release with status, required-marker, cross-tenant leak, and latency checks.
- Aggregate transition alerts through stdout, a generic webhook, and Telegram.
- Fully offline test suite and cron-oriented persistent state.
