# Ranikun Labs — Platform Infrastructure

**Status: C0 / Documentation-only** · Private organization repository.  
**Issue:** https://github.com/ranikun-labs/platform-infra/issues/1

This repository will own **shared cloud infrastructure and environment-specific infrastructure definitions** for the Ranikun Labs product ecosystem. It does **not** own Product source code, local Dockerfiles/Compose, domain data migrations, or `oh-my-ai` Local CLI releases.

> **Bootstrap ≠ Provisioning.** The presence of this repository or a merged document is not approval for AWS provisioning, Terraform plan/apply/destroy, production deployment, database migration, Product cutover, or a GitHub deployment trigger.

## Current stage

- C0: repository ownership/isolation contract (documentation only).
- C1: versioned infrastructure skeleton and validation workflow — **not started; separate review required**.
- C2: AWS resources, state backend, roles, secrets, and service deployment — **not authorized**.
- No deployed infrastructure or cloud resource is evidenced by this repository.

## Ownership boundaries

| Boundary | Code owner | Infrastructure ownership | Release boundary |
| --- | --- | --- | --- |
| Shared network / physical RDS foundation | N/A | `platform-infra` / Shared | Separately approved shared change |
| Gateway / Platform Core (Identity, Shared AI, Audit) | `platform-services` | `platform-infra` / Platform | Platform, independent from Products |
| Carelog backend/frontend | `carelog-be` / `carelog-fe` | `platform-infra` / Carelog | Carelog only |
| Finance backend/frontend | `finance-harness-be` / `finance-harness-fe` | `platform-infra` / Finance | Finance only |
| Local Skills, Hooks, CLI | `oh-my-ai` | No cloud dependency in V1 | Local release |
| Architecture / decisions | `harness-foundation-docs` | Canonical ADRs, not live resource evidence | Owner decision |

**Invariant:** A Carelog change must never automatically build, deploy, restart, roll back, migrate the database of, or apply infrastructure for Finance. The inverse is equally prohibited. Shared Platform changes are independently released and must preserve consumer contract compatibility.

## Intended boundaries (not yet created)

```text
docs/
  ownership-and-isolation.md
  runbooks/                   # only when approved
environments/
  dev/{shared,platform,carelog,finance}/
  prod/{shared,platform,carelog,finance}/
modules/                      # only when genuine reuse is demonstrated
.github/workflows/            # only after C1 CI approval
```

Use one `main` source-of-truth branch plus short-lived feature PRs; `dev` and `prod` are **environments and separate state/permissions**, not long-lived product branches. No empty directories or scaffolding are created in C0.

## Guardrails

1. **Separate environments and blast radii**: dev/prod × Shared/Platform/Carelog/Finance have separate IaC state keys, locking, plan/apply authority, IAM and secrets scopes when implemented. Path filters alone are insufficient authorization boundaries.
2. **Independent release pipelines**: application build/tests, Dockerfiles and local Compose stay in the source repositories. Infra pipelines may only target explicitly selected environment×service and must not deploy every service on `main` push.
3. **Shared services remain shared-failure risks**: the target V1 architecture shares VPC and one private PostgreSQL RDS instance; separate schemas/roles/migration ownership prevent cross-product write ownership but **not physical RDS outage propagation**.
4. **No automatic production**: Source Merge, CI PASS, Infrastructure Plan, Apply, DB Migration, Product Cutover and Production Rollout are separate gates.
5. **Secrets are never committed**: no credential, Terraform state, key material, live environment file or production user data in Git.
6. **Rollback and compatibility**: service-owned image digest and rollback contract; Shared Identity changes cannot force simultaneous Carelog/Finance rollout. Dev/prod SQS, DLQ and IAM must be isolated if implemented.

See [Ownership and Isolation Contract](docs/ownership-and-isolation.md) for the normative C0 design and evidence checklist.

## Canonical architectural inputs

- [ADR-0022 — AWS V1 MVP Primary Runtime](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0022-aws-v1-mvp-primary-runtime.md)
- [ADR-0020 — PostgreSQL Schema Ownership](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0020-shared-platform-postgresql-schema-ownership.md)
- [AWS V1 MVP Deployment Plan](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/architecture/backend-service-foundation/aws-v1-mvp-deployment-plan.md)

These are target/ownership decisions, **not evidence of running AWS resources**. Any conflict or change in effective ADR authority requires a new review.
