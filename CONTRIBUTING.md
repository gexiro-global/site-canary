# Contributing

Bug reports with a minimal reproduction are especially useful. Changes that improve portability, diagnostics, or transport safety are welcome.

## Ground rules

- Keep the monitor POSIX `sh` and dependency-light.
- Keep checks read-only and suitable for off-host operation.
- Never add real domains, credentials, tokens, or other secrets.
- `shellcheck` must pass clean.
- Every behavior change needs an offline assertion in `tests/run_tests.sh`.

## Support expectations

Maintained on a best-effort basis. No SLA or commercial support is provided. Pin the version when using this tool in operational monitoring.
