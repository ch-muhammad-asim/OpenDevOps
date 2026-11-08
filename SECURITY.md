# Security Policy — OpenDevOps

OpenDevOps includes educational and production-style infrastructure examples. They may involve Kubernetes, IAM, public endpoints, AI tools, and cloud resources. **Do not deploy an example unchanged into production without a project-specific security review.**

## Reporting a vulnerability privately

**Please do not create a public issue or pull request that reveals a security flaw, secret, or working exploit.**

1. Visit the repository's [Security tab](https://github.com/ch-muhammad-asim/OpenDevOps/security) and use **Report a vulnerability** / private vulnerability reporting *if the maintainer has enabled it*.
2. If private reporting is unavailable, contact the repository owner through their [GitHub profile](https://github.com/ch-muhammad-asim) to request a confidential reporting channel. Do not send exploitation details in a public comment.
3. Include the affected path and revision, impact, reproduction steps using **synthetic data**, and your proposed remediation if available. Never include live passwords, tokens, or customer data.

Reports will be reviewed and triaged by the maintainer; remediation timelines depend on severity, reproducibility, and upstream dependencies. No formal security SLA is promised.

## Scope and protections

- This policy covers project-authored code, images, manifests, and documentation.
- Upstream vulnerabilities in third-party projects should also be reported to their respective maintainers.
- Current CI covers selected areas (Docker Agent and the Hermes OpenShell sandbox); it is **not** a claim that every example is continuously scanned or penetration-tested.
- For the detailed Hermes sandbox threat model and risk register, see [sandbox/SECURITY.md](sandbox/SECURITY.md).
- Never treat a model prompt, AI approval message, or read-only CLI wrapper as a substitute for independent Kubernetes RBAC, GCP/AWS IAM, network restrictions, and human review.

Security issues can also be raised in a **sanitized public issue** once sensitive details are removed and disclosure is coordinated.
