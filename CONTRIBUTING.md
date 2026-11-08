# Contributing to OpenDevOps

Thank you for helping make practical DevOps, SRE, and platform-engineering examples easier to reuse.

## Before contributing

- Read the relevant project README and identify whether its status is **tested**, **lab-only**, or **planned**.
- Open a GitHub issue for nontrivial changes to agree on scope before implementation.
- For security vulnerabilities, **do not** open a public issue. Follow [SECURITY.md](SECURITY.md).
- Respect the licenses of external projects and services. Do not submit proprietary or third-party material without redistribution rights.

## Pull request workflow

1. Fork the repository, create a descriptive branch, and keep each PR focused on one issue or area.
2. Add or update tests and documentation for behavior changes; include exact reproduction and verification commands.
3. Never commit secrets, access tokens, private keys, kubeconfigs, customer data, internal hostnames, or live credentials. Use sanitized examples and placeholder values.
4. Keep Kubernetes and cloud access **least privilege**. Prefer read-only workflows and explicit human authorization for mutations.
5. Run the tests in the project-specific README and the repository quality check: `python3 .github/scripts/check_repo_health.py`.
6. Explain what was tested, where it was tested (local Docker, kind, GKE, etc.), and what has **not** been validated.

A PR should include a short purpose, implementation summary, evidence of testing, security/cost impact, and any rollback considerations. Maintainers may request revisions before merging.

## Community expectations

Be respectful, constructive, and inclusive. Give actionable technical feedback; don't share other people's sensitive information. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Automated checks and test boundaries

The repository uses **path-scoped CI** so a change to one project does not require credentials or running another project's live cloud environment.

| Scope | Automated checks | Deliberately not performed in routine PR CI |
|---|---|---|
| Root OSS docs | Required files and relative link resolution | External link health / license ownership review |
| `docker-agent/` | Image builds, smoke checks, Trivy configuration/secret checks | Live model calls and production cluster operations |
| `sandbox/` | Lint, secret/config checks, OpenShell policy proof; scheduled image scanning | Live sandbox proofs requiring the server, paid LLM calls |
| `hermes-grafana-tempo/` + `herdr/hermes-herdr/` | Python / JSON / Bash syntax, Node source syntax, selected Kubernetes Kustomize renders | GKE deploys, actual node readiness, paid models, runtime integration tests, Helm dependency downloads |

Run `python3 .github/scripts/check_repo_health.py` for root documentation checks. Run project-specific validation from its README when changing infrastructure behavior.

**Do not describe syntax checks or manifest renders as production security validation.** The CI jobs are intentionally offline with no cloud credentials, and real end-to-end validation remains a separate, explicitly approved operation.

## Areas where help is welcome

- Reproducing documented labs and reporting discrepancies
- More targeted CI checks and end-to-end smoke tests
- Helm/Kubernetes/Terraform validation with safe test credentials
- Security reviews, observability improvements, and resource-efficiency experiments
- Fixes to documentation, architecture diagrams, and cross-platform instructions

See [the issue tracker](https://github.com/ch-muhammad-asim/OpenDevOps/issues) for current work.
