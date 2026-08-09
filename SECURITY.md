# Security Policy

## Supported Versions

`site-canary` v0.x is maintained on the latest v0.x release line.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting if enabled on this repository, otherwise email `admin@gexiro.com`.

Do not include real tokens, alert endpoints, private hostnames, or production response bodies. Use synthetic fixtures in reports and reproductions.

## Threat model

The monitor performs read-only HTTP GET requests and writes only its local state file and private temporary response files. Configuration and alert env files are trusted operator input. The alert env file is sourced as shell syntax, so it must be owned and writable only by a trusted operator.

URLs cause outbound requests and may reach internal addresses accessible from the monitoring node. Do not accept configuration from untrusted parties. Response content is treated as data and compared with literal fixed strings.
