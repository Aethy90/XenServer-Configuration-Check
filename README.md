# XenServer Configuration Checker — v0.12.0

This package contains four files:

- `xenserver-check.sh` — copy this one file to XenServer for collection.
- `xenserver-review.pyz` — keep this one file on the workstation for analysis.
- `README.md` — this guide.
- `SHA256SUMS` — checksums for those three files.

The `.pyz` is a standard Python application containing the checker modules and rules. It needs Python 3.10+ on the workstation and no third-party packages. XenServer collection uses Bash 4+, root, xe/OpenSSH and existing GNU utilities; no Python installation or invocation is required on the host.

## 1. Collect

Copy `xenserver-check.sh` to an approved directory on the host, then run:

```bash
bash xenserver-check.sh --dry-run
bash xenserver-check.sh --output-root /var/tmp --case-id REVIEW-001
```

A one-host topology selects local collection. A multi-host interactive launch asks whether to collect this host or the pool. Noninteractive launches require `--scope host` or `--scope pool`. Full pool collection starts on the coordinator and requires existing root SSH access and verified member host keys; the tool does not establish access.

```bash
bash xenserver-check.sh --scope pool --output-root /var/tmp --case-id POOL-001 --ssh-key /root/.ssh/existing-key --known-hosts /root/.ssh/known_hosts
```

Use existing authorized paths. The launcher temporarily unpacks its three internal Bash stages into a private directory in `/var/tmp`, checks their hashes and removes those script copies on exit. Collection results and member output remain for manual cleanup. `/var/tmp` uses Dom0 disk; choose an approved existing output directory and observation window. Dry-run checks discovery, not member transport or production load. Collection does not change XenServer or syslog settings.

Transfer the printed `.tar.gz` bundle and its `.sha256` sidecar securely to the workstation. Preserve them as the original evidence. No host data is uploaded to an external service.

## 2. Review

```bash
python3 xenserver-review.pyz review bundle.tar.gz --out new-review
```

Open `new-review/report.html`. The output folder contains just:

- `report.html` — self-contained customer report, including grouped findings, asset details, coverage and per-host syslog configuration.
- `actions.csv` — action groups for follow-up.
- `technical-details.zip` — complete generated technical reports, per-host views, JSON/CSV, rule catalogue, available logs/manifest and evidence references.

Extract the technical ZIP before opening its HTML reports; an included text guide identifies the entry point. It preserves the full generated output, not a replacement copy of the original collection bundle. Keep that bundle and checksum separately. Treat report files and the technical ZIP as sensitive configuration data.

Use `--full-output` if you need the original expanded technical directory instead:

```bash
python3 xenserver-review.pyz review bundle.tar.gz --out expanded-review --full-output
```

## 3. Compare

Keep the same selected scope and approved evaluation inputs:

```bash
python3 xenserver-review.pyz compare --before baseline.tar.gz --after retest.tar.gz --out new-comparison
```

The folder contains `comparison.html`, `changes.csv` and `technical-details.zip`. The HTML separates configuration differences, assessment/exception changes, coverage and uncertain chronology. Baseline/retest assessments and all transition exports are in the technical ZIP. Add `--full-output` for expanded results.

## Inputs and interpretation

Use `COMMAND --help` for options, including `--as-of`, `--policy`, `--profile`, `--exceptions`, `--before-exceptions`, `--vendor-reference` and `--update-metadata` where supported. Optional empty templates can be created when needed:

```bash
python3 xenserver-review.pyz templates --out customer-inputs
```

Omit policy fields without an approved baseline. Missing evidence stays Not assessed; grouped records remain individually traceable. Accepted exceptions retain raw gaps/severity. A configured syslog destination does not prove receiver-side delivery or retention. Different network UUIDs do not prove isolation. No compliance percentage is calculated.

## Manual collection without pool SSH

Run on each authorized host:

```bash
bash xenserver-check.sh --snapshot --output-root /var/tmp --case-id HOST-001
```

Transfer each raw snapshot/checksum, then combine on the workstation:

```bash
python3 xenserver-review.pyz review-pool --pool-snapshot coordinator.tar.gz --members member02.tar.gz member03.tar.gz --out manual-review
```

A single raw snapshot can be reviewed using `review-host`. Do not use `--no-pool-config` for snapshots to combine. Missing selected members remain unknown. These commands also default to three output files.

## Validation and support limits

Collection has been exercised on one XenServer 9 lab node. Real multi-host operation, migration/failover, representative pool scale and independent customer delivery remain unvalidated. The release is for an assisted pilot; production-pool readiness is not asserted. Workstation runtime tests cover macOS and the Linux lab; Windows and Python 3.10 runtime remain untested. Use `py -3` instead of `python3` on Windows if available.

Exit 0 means processing/retrieval completed, not that every configuration is appropriate. Exit 1 means retained partial/coverage/consistency results; read the report. Exit 2 means invalid input or failure. Unverified host clocks withhold verified remediation chronology. Diagnostics use `--debug` and remain separate from transport data.

Editable modules, tests, full guides and the build recipe are supplied in the separate Source ZIP. The customer package omits development tests, historical records and generated examples. Existing releases and original lab evidence remain separate.
