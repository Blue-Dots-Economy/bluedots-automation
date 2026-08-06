# ci-templates/

Staging area for shared CI workflow(s) for the Sec-Audit A2 rollout (signals-dpg#300).

## security-scan.yml — reusable security-scan workflow

A `workflow_call` reusable workflow (Trivy fs/deps/image/IaC + gitleaks, SARIF → Security tab).
Full rationale + per-repo callers: signals-dpg `docs/operations/security-scanning-a2*.md`.

### Activation (one step — needs `workflow` scope)
It is staged here rather than under `.github/workflows/` because that path requires a token
with the GitHub Actions `workflow` scope. To activate, a maintainer with that scope (or via the
GitHub web UI, which permits workflow files) moves it into place:

```bash
git mv ci-templates/security-scan.yml .github/workflows/security-scan.yml
git commit -m "ci: activate reusable security-scan workflow (#300)"
```

Until then, per-repo callers should reference the ref where it currently lives (e.g. `@feature`);
promote it through feature → develop → main so callers can pin `@main`.
