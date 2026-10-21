# C0 — Infrastructure Ownership, Isolation & Release Contract

**Status:** C0 design baseline · **Not** a Production Implementation Approval  
**Owner review:** [platform-infra Issue #1](https://github.com/ranikun-labs/platform-infra/issues/1)  
**Architecture authority:** `harness-foundation-docs` effective ADRs (especially ADR-0020 and ADR-0022)

This document defines the *minimum architecture and verification obligations*. Nothing here represents actual AWS provisioning, deployed state, CI enforcement or granted IAM. When an effective ADR conflicts with this document, stop and reconcile with the architecture owner before implementing.

## 1. Invariants

1. **Carelog and Finance have independent life cycles.** A Carelog change must not trigger Finance build, test, deploy, restart, rollback, Flyway migration, or infrastructure plan/apply. The reverse also holds. An explicitly approved shared-impact verification job may test consumer compatibility **without deploying** the other product.
2. **Gateway and Platform Core are separate executable/deployment units**, with Shared Identity, Shared AI and Shared Audit hosted in the Core boundary per the current target. Neither Product is a prerequisite for deploying the other.
3. **Share infrastructure only by explicit design**: VPC and private physical PostgreSQL RDS may be common, but a common availability/failure domain remains. Shared infra modification has a separate impact, sequencing and rollback approval.
4. **One physical RDS does not mean shared application ownership**. One application DB can contain `identity`, `carelog`, `finance` and future `audit` schemas with separate runtime/migration roles, schema grants, Flyway history and Domain owners. No cross-service FK or cross-schema OLTP joins. Product reads shared Identity by service contract, not direct table access.
5. **Source Merge ≠ CI PASS ≠ Infra Plan ≠ Infra Apply ≠ DB Migration ≠ Production Deployment ≠ Traffic Cutover.** Each is a separate gate with its own explicit authorization.
6. **`oh-my-ai` V1 is local-first.** Its CLI/Skill/Hook install and release cannot depend on AWS, Carelog or Finance. A future managed Control Plane needs an explicit expansion decision.

## 2. Source-of-truth and changes

| Object | Owner repository | Write/Release boundary |
| --- | --- | --- |
| Product implementation, Dockerfile, local Compose, Gradle/Node tests | `carelog-be`, `carelog-fe`, `finance-harness-be`, `finance-harness-fe` | Each Product independently |
| Gateway/Core source, Dockerfiles, local Compose, contract/E2E tests | `platform-services` | Gateway/Core, without forced Product promotion |
| Shared networking, RDS physical foundation, observability baseline | `platform-infra` Shared | Shared impact review; no automatic Product rollout |
| Per-service compute, security group, service IAM and infra environment | `platform-infra` Platform/Carelog/Finance | Environment × target unit |
| Product database schema, Flyway migration, product-specific grants | Owning Product / Shared Platform source | Explicit DB migration gate, never inferred from Terraform apply |
| Local CLI, Skill registry, adapters, release | `oh-my-ai` | No cloud infrastructure |
| ADR, architecture governance, target topology | `harness-foundation-docs` | ADR/Owner decision; not a runtime inventory |

Avoid moving each Product's Dockerfile or local developer Compose into `platform-infra`. Application version and image digest originate from their respective code repositories.

## 3. Proposed physical target (NOT deployed evidence)

ADR-0022 targets **AWS ap-northeast-2 / V1 EC2 + Docker Compose**:
- EC2 #1 — Gateway, WebFlux.
- EC2 #2 — Platform Core MVC with Identity, Shared AI and Shared Audit logical modules; Valkey co-location is a candidate requiring approval and private binding.
- EC2 #3 — Finance Backend.
- EC2 #4 — Carelog Backend.
- One **private** RDS PostgreSQL physical instance and one application database, service-specific schemas and roles.

EC2 sizes, service networking, common PostgreSQL major, RDS HA, costs, DNS/Tunnel, backups, secrets provider, recovery RPO/RTO and Valkey final placement remain individual implementation/Owner gates. The existence of this topology in an ADR is **not** evidence that any resource exists.

## 4. Proposed repository layout — no automatic scaffolding

```text
README.md
docs/
  ownership-and-isolation.md
  runbooks/                 # only as approved and needed
environments/
  dev/
    shared/ platform/ carelog/ finance/
  prod/
    shared/ platform/ carelog/ finance/
modules/                    # add only for demonstrated reusable infrastructure
.github/workflows/          # C1, after trigger and permission review
```

Keep one `main` canonical branch and short-lived PR branches. Do **not** create permanent Carelog, Finance or dev/prod source branches for environment separation. Environments and IaC state are independent of source branches. Empty directories need not be created.

## 5. State, IAM, secrets, database — binding design tests

When IaC is implemented, each `(environment, unit)` pair, where unit is `shared | platform | carelog | finance`, must have:
- Separate Terraform **state identity/key**, lock, plan/apply context, roles and bounded resource targets. No single apply or destroy operation may mutate both Carelog and Finance.
- Production apply separate from development apply; production **default OFF** and requires explicit Owner approval, plan evidence and a rollback/forward recovery plan.
- Least-privilege credentials and trust boundaries (e.g. scoped OIDC/AssumeRole once chosen); path-based workflow filters alone do not enforce permissions.
- Secrets referenced from a separately reviewed protected source; never store secrets, credential material, Terraform state or live env in Git or PR logs.
- Explicit ownership for PostgreSQL schema creation, migration-role grants, application-role grants and runtime access. Terraform does **not** execute Flyway or implicitly grant schema ownership across products.
- Shared change impact statement listing all possible consumers, migration dependency, validation window, rollback limit and cross-product failure propagation.

**C0 does not choose or configure** a backend provider, bucket, encryption/KMS key, lock mechanism, trust policy, secret manager, or actual cloud credential. Those require C1/C2 review and account/resource ownership evidence.

## 6. CI/CD trigger and deploy matrix

| Change origin | Default verification | Auto build/deploy target | Prohibited side effects |
| --- | --- | --- | --- |
| Carelog code PR | Carelog only | **None**; approved Carelog release later | Finance build/deploy/restart/rollback/migration |
| Finance code PR | Finance only | **None**; approved Finance release later | Carelog build/deploy/restart/rollback/migration |
| Platform code PR | Gateway/Core + impacted consumer contract checks as needed | **None**; Platform release separately | Forced simultaneous Carelog/Finance rollout |
| Infra `environments/*/carelog/**` | Carelog infra plan, scope assertion | **No apply by PR/Merge** | Finance state or deployment |
| Infra `environments/*/finance/**` | Finance infra plan, scope assertion | **No apply by PR/Merge** | Carelog state or deployment |
| Infra `environments/*/platform/**` | Platform infra plan, scope assertion | **No apply by PR/Merge** | Product deployment |
| Infra `environments/*/shared/**` | Shared plan + both product impact assessment | **No apply by PR/Merge** | Implicit all-product rollout |
| `oh-my-ai` release | Install/Skill/CLI fixtures | Only independent local-package release | Cloud resource mutation |

- Required Check names should remain stable even if an internal path matrix skips a non-affected build, to avoid permanently pending mandatory checks.
- GitHub Free **Private** organization repos may have unavailable enforced branch rules; an Owner-reviewed evidence gate is a **process**, not equivalent technical protection.
- A `main` Merge MUST NOT auto-deploy production by default. Confirm native and **external** webhooks/CI/deployment subscriptions before classifying this as verified.
- Container images should be identified by immutable digest; a rollback must restore **compatible versioned image + configuration + credentials + DB/schema compatibility**, not just swap a tag. The image rollback proof is per owning service.
- If introduced, SQS queue/DLQ/IAM resources are isolated across dev/prod. No queue provisioning under C0.

## 7. Negative tests / evidence required before C1

| ID | Attempted counterexample | Expected |
| --- | --- | --- |
| ISO-01 | Carelog PR/change triggers Finance build, deploy, restart or migration | **NO**; workflow graph evidence |
| ISO-02 | Finance plan/apply role can read/write Carelog state or resources | **DENIED**; IAM and state-scope tests |
| ISO-03 | Dev pipeline can mutate Prod backend key, secrets or deploy target | **DENIED** |
| ISO-04 | Shared RDS/VPC modification escapes independent Shared review | **DENIED**; affected consumer impact identified |
| ISO-05 | Platform Auth/Identity change requires immediate Carelog + Finance version bump/deploy | **NO**; compatibility-window evidence |
| ISO-06 | `oh-my-ai` Local V1 requires platform cloud or Product availability | **NO**; offline/install fixtures |
| ISO-07 | `main` merge invokes production deployment without separate explicit approval | **NO**; GitHub/external triggers verified |
| ISO-08 | Rollback changes an unrelated service's image, secret or schema | **NO** |
| ISO-09 | Branch path restriction alone allows writer to modify another service's state | **DENIED** by state/IAM policy |

These are **acceptance criteria, not passing test results**. All remain `NOT_RUN` until applicable infrastructure/workflows and proof exist.

## 8. Phase and authorization boundaries

- **C0 (now):** README + this contract, ADR alignment and independent design review. **Only documentation changes**. Marked `BOOTSTRAPPED / REVIEW_PENDING` until commit readback and Owner contract acceptance.
- **C1 (future):** IaC layout/README/CI no-op validation and state/permission implementation plan; new scope/review required.
- **C2 (future):** Cloud provisioning, IAM trust, actual backend/state, Secret Store, runtime rollout and production cutover. Each requires separate approval, budget and rollback assessment.
- **Jira G2 field migration:** separate session owner, no reads or writes as part of this contract.
- **RPL-116:** Backlog only, not implemented here.

## 9. Canonical references

- [ADR-0022 — AWS V1 MVP Primary Runtime](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0022-aws-v1-mvp-primary-runtime.md)
- [ADR-0020 — PostgreSQL Schema Ownership](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0020-shared-platform-postgresql-schema-ownership.md)
- [AWS V1 MVP Deployment Plan](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/architecture/backend-service-foundation/aws-v1-mvp-deployment-plan.md)
- [Infrastructure implementation tracker #1](https://github.com/ranikun-labs/platform-infra/issues/1)
