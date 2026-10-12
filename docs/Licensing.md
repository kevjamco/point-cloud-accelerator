# Licensing and activation

pcax is free to evaluate and needs a commercial license for every other use
([LICENSE](../LICENSE)). The binary enforces this with a license check before
every `pcax run`: it asks the Advanced Algorithms license server for a signed
*grant*, and runs only when it gets one. Everything else — `validate`,
`analyze`, `info`, `convert`, `serve`, `--version` — runs without a license.

## Evaluation: activate once with your email

```bash
pcax activate you@example.com     # emails a 6-digit code
# enter the code at the prompt (or: pcax activate you@example.com --code 123456)
pcax run pipeline.yaml
```

Activation prints the disclosure below, binds the evaluation to this
machine, and stores a token in `~/.config/pcax/credentials.json`
(mode 0600). Each `pcax run` then contacts the license server for a grant
valid for one hour and refreshed every ten minutes while a long run is in
progress. **An evaluation needs network access to the license server on
every run**; there is no offline mode for evaluations.

`pcax license status` shows the account, tier and lease state;
`pcax license deactivate` removes the stored credentials;
`pcax license privacy` prints the disclosure.

## Commercial licenses

A commercial license is issued as a token for your account, bound either
to one machine or to your organization (for containers, clusters and
ephemeral hosts, where a machine fingerprint is not stable). Install it with
`PCAX_LICENSE_TOKEN=<token>` in the environment or by writing it with
`pcax activate --token <token>`.

Commercial accounts can also fetch an **offline lease**:

```bash
pcax license lease        # stores ~/.config/pcax/lease.json, valid for weeks
```

A valid lease is used without any network access; `pcax run` contacts the
server again only when the lease has expired. Air-gapped sites receive the
lease file from Advanced Algorithms and point `PCAX_LICENSE_LEASE` at it.

## What is sent, and when

The disclosure printed by `pcax activate` and `pcax license privacy`:

- **At activation:** your email, a fingerprint of the machine (a SHA-256
  hash of the OS machine id; the id itself never leaves the machine), the
  pcax version.
- **At every run:** the fingerprint, pcax version, operating system and
  architecture, GPU device name, and the list of stage *types* in the
  pipeline (for example `read.las, filter.smrf, writer.gdal_gpu`).
- **After the run:** input and output point counts, duration, exit code.
- **Seen by the server:** your IP address, as with any HTTPS request.

Never sent: file names or paths, point data, stage options, hostnames,
pipeline variables. Every run is logged on the server with the data above;
this is how evaluation use and licensed use are told apart. Each run prints
one line on stderr, `licensed: you@example.com (evaluation) — run metadata
reported, see 'pcax license privacy'`, so the reporting is visible in logs.
stdout contracts (`--json`, `--batch-out`) are unchanged.

## Environment variables

| Variable | Meaning |
|---|---|
| `PCAX_LICENSE_TOKEN` | Use this token instead of `credentials.json` (CI, containers). |
| `PCAX_LICENSE_LEASE` | Path of a lease file to use instead of `lease.json`. |
| `PCAX_LICENSE_DIR` | Directory for `credentials.json`/`lease.json` (default `$XDG_CONFIG_HOME/pcax` or `~/.config/pcax`). |
| `PCAX_LICENSE_SERVER` | License server base URL (default `https://license.adv-algos.net`); for a proxy or relay. Responses are signed, so a wrong server cannot grant anything. |

## Exit code 4 and network requirements

`pcax run` exits with **4** when no grant could be obtained: not activated,
token revoked, evaluation used on another machine, lease expired, or the
license server unreachable. The message says which, and what to run.

Allow outbound HTTPS (TCP 443) to `license.adv-algos.net`. The client
times out after 10 seconds and retries twice; a grant stays valid for the
rest of a run once obtained, so a brief outage mid-run does not stop it.

## How the check works, briefly

Every grant and lease is signed by the license server (Ed25519) over a
nonce the client chose, the machine fingerprint and an expiry; the binary
verifies the signature against a public key compiled into it and checks the
grant again inside the pipeline executor before each stage. A server that
does not hold the private key, including a redirected or spoofed one, cannot
produce an acceptable grant. pcax is distributed as a binary only
([Install.md](Install.md)).
