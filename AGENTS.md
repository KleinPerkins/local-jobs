<!-- doc-warden:begin -->
## Documentation governance

This repo's documentation structure is governed by `doc-warden`.

| Artifact type | Location |
|---|---|
| Plans | `docs/plans/` — index at `docs/plans/README.md` |
| ADRs | `docs/adr/` — index at `docs/adr/README.md` |
| Runbooks | `docs/runbooks/` |
| Glossary | `docs/GLOSSARY.md` (created when genuine terminology ambiguity arises) |

**Policy:** `~/dev/_ops/doc-warden/POLICY.md`
**Engine:** `~/dev/_ops/bin/doc-warden.sh check local-jobs` (read-only health check)
<!-- doc-warden:end -->

## CI and PR delivery

Run `python3 -I -B scripts/verify.py local`. CI has three closed shards: the real fixture-only installer/handler contract on macOS, account review/creation tests, and App/CI failure-path tests. Production jobs, credentials, archive execution and the retired controller are never test dependencies.

The authoring agent automatically captures fresh independent review from the PR-creation Codex account with `scripts/local_review.py`, creates the PR with `scripts/create_review_pr.py`, then publishes the unedited review receipt prefixed `<!-- g1-review-receipt:v1 -->`. Repeat after head, current base or trusted policy changes. Prefer a qualified enrolled same-account cloud route; otherwise use that account's enrolled local adapter. Shared GitHub identity does not establish origin; missing origin or unavailable review blocks the PR without cross-account or human technical-review fallback.

The trusted-main Chaos Scheduler App is the only authorized approver/merger and supplies its own approval and native squash request after matching origin, review, exact CI run and controls. App-only delivery is an operating rule, not atomic technical exclusivity: another write-capable actor can arm auto-merge between the App's final check and approval. The operator accepts this limited race; observed foreign or unknown auto-merge requests still reject. Other approvals do not substitute for App evidence, and unsolicited coexisting approvals are not inherently prohibited. Initial source admission is owner-controlled; source presence alone does not authorize activation. Agents never manually merge, manipulate auto-merge, bypass checks or install runtime jobs as part of CI delivery.

The authorized G1 transition adopts meaningful sharded standard-hosted Actions for this repository, superseding the inherited runnerless-only default and ShadowSync-only hosted-runner exception for the accepted cohort. The installed controller is abandoned. SECURITY.md is copied byte-for-byte from the approved Dev successor owner seed `2118b0ff669bedc9a4a9267600ecfec7df4afc6c` with its managed markers; these approved source bytes are not a claim of Dev publication, admission or installation.
