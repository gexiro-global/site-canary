# site-canary

[![CI](https://github.com/gexiro-global/site-canary/actions/workflows/ci.yml/badge.svg)](https://github.com/gexiro-global/site-canary/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A dependency-light, config-driven external synthetic monitor for checking multiple sites over their full public paths.

`site-canary` checks the expected HTTP status, a required content marker, forbidden cross-tenant markers, and response latency. It is designed to run off-host from a separate node, where it exercises public DNS, TLS, routing, and application delivery together.

Requirements: POSIX `sh`, `curl`, `awk`, `grep`, and standard Unix utilities. `python3` is optional and is used when available for webhook JSON escaping; a built-in encoder is used otherwise.

## The cross-tenant leak check

A green status code does not prove that a hostname serves the right tenant. A proxy or deployment error can return a perfectly healthy page belonging to another site. The `forbid` field makes that failure explicit and first-class: list markers that belong to other tenants, staging environments, or default sites, and the check fails with `CROSS-TENANT LEAK` if any occur in the response body.

Use both sides of the identity check:

- `marker` proves the expected site's own identifying text is present.
- `forbid` proves one or more known foreign identifying strings are absent.

Matching is literal and case-sensitive. A site may specify multiple comma-separated forbidden markers.

## Configuration

Copy the example and edit it:

```sh
cp sites.conf.example sites.conf
```

The format is one pipe-separated site per line. Blank lines and lines whose first non-space character is `#` are ignored.

```text
https://example.com/ | expect=200 | marker=Example Domain | forbid=other-site.example,staging | max_rt=8
```

Only `url` is required. Defaults are `expect=200`, `marker=<URL hostname>`, no forbidden markers, and `max_rt=8` seconds. Values are literal; pipe characters cannot appear within a value. URLs must use HTTP or HTTPS. Redirects are followed and the status check applies to the final response.

Select the file with `--config FILE` or `SITE_CANARY_CONFIG`. State defaults to `./site-canary.state`; use `--state FILE` or `SITE_CANARY_STATE_FILE` when running from cron.

## Usage

```sh
./site-canary --config ./sites.conf --state /var/lib/site-canary/state
./site-canary --config ./sites.conf --dry-run
./site-canary --alert-env /etc/site-canary/alert.env --test
```

`--dry-run` validates and prints the resolved configuration without making requests or alert calls. `--test` sends a transport acceptance alert and exits `0` when accepted. It does not require a sites file. Without a configured remote transport, alerts are printed to stdout, including test alerts.

Exit codes are:

| Exit | Meaning |
|---|---|
| `0` | All sites healthy, or test alert accepted. |
| `1` | Usage, configuration, state-write, or test-delivery error. |
| `2` | One or more sites failed. |

Every normal run prints one `SITE-CANARY: PASS/FAIL` summary. The first failing run emits one structured aggregate alert. Continuing failures stay silent. The next all-clear emits one `RECOVERED` alert.

## Alert transports

Set either or both transports in the environment or in an operator-owned env file selected with `--alert-env FILE` or `SITE_CANARY_ALERT_ENV`:

```sh
ALERT_WEBHOOK_URL=https://alerts.example.invalid/hooks/replace-me
TELEGRAM_BOT_TOKEN=replace-me
TELEGRAM_CHAT_ID=replace-me
```

The generic webhook receives `{"text":"..."}` as JSON. Telegram uses HTML parse mode with escaped alert text. Transport requests have a bounded timeout and tokens are never printed. If no transport is configured, the structured alert still goes to stdout and a failing check still exits `2`.

Keep alert env files outside the repository and restrict their permissions. The env file is sourced as trusted shell input.

## Off-host cron

Install on a separate monitoring node so the check covers the public route:

```cron
*/5 * * * * /opt/site-canary/site-canary --config /etc/site-canary/sites.conf --alert-env /etc/site-canary/alert.env --state /var/lib/site-canary/state
```

Use an absolute, persistent state path and ensure its parent directory exists and is writable by the cron user. Capture stdout/stderr in your normal cron logs.

## Safety and limits

- Checks are read-only external GET requests. The tool does not change the monitored sites.
- Configuration and alert env files are trusted operator input; do not let untrusted users write them.
- Secrets come only from the process environment or an explicitly selected env file, never repository configuration.
- Response bodies are held only in a private temporary directory and removed after the run.
- Literal markers establish a useful delivery invariant, not complete application correctness.

## Testing

```sh
shellcheck site-canary tests/run_tests.sh
./tests/run_tests.sh
```

The suite is fully offline and uses a loopback-only synthetic server plus a fake alert transport.

## License

Apache-2.0. See [LICENSE](LICENSE).

Built and maintained by [Gexiro Global Enterprises Ltd](https://gexiro.com).

Part of the [Gexiro open-source toolkit](https://github.com/gexiro-global).
