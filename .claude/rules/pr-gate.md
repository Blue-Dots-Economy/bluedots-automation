---
paths:
  - ".github/**"
---

# develop-PR docs & release-notes gate

PRs into **`develop`** run `.github/workflows/develop-pr-gate.yml`, which calls the composite action `.github/actions/pr-gate/` (`action.yml` → `check.mjs`). It **fails closed** unless the PR has **both** a non-empty `## Release Notes` section in the body **and** a change to `README.md` or `CLAUDE.md` — each individually waivable via the `no-release-notes` / `no-doc-update` label.

Structure (keep this separation if you touch it):
- **`gate.mjs`** — pure logic, no deps, no IO (`evaluate()` takes the PR body/labels/files and returns pass/fail). This is the only part with unit tests.
- **`check.mjs`** — the IO shell: pulls PR body/labels/files via `gh api` (with a `PR_FILES` env escape hatch for testing) and calls `evaluate()`.
- **`gate.test.mjs`** — runs via `node --test` in the separate `pr-gate-tests` workflow, triggered only on changes under `.github/actions/pr-gate/**`.

The gate only actually blocks a merge once a repo/org ruleset requires the `develop-pr-gate` check on `develop` — the workflow existing isn't sufficient by itself. PR body scaffolding lives in `.github/PULL_REQUEST_TEMPLATE.md`.

If you're editing the gate logic, change `gate.mjs` and add a `gate.test.mjs` case — don't put logic in `check.mjs` (it's deliberately un-unit-tested IO glue).
