# Carelog DEV enrollment TLS: certificate, key and CA storage design

Status: **design and prep only.** No secret, certificate, key, or CA was created or read in AWS. Nothing was written to the repository. Local tests used throwaway material under the private scratch directory.

Prices below are an **assumption dated 2026-11-24**, based on AWS list prices as I know them. They were not fetched from the Seoul pricing pages in this session. Verify before budgeting: <https://aws.amazon.com/secrets-manager/pricing/>, <https://aws.amazon.com/kms/pricing/>, <https://aws.amazon.com/ecr/pricing/>, <https://aws.amazon.com/private-ca/pricing/>.

## 1. Decision

| Option | Verdict | Reason |
| --- | --- | --- |
| **Secrets Manager, plaintext PEM secrets, self-managed dev CA** | **Chosen** | Matches the candidate's `secrets = [{ name, valueFrom = <ARN> }]` shape exactly. The sidecar and init read whole-secret values. The module passes `valueFrom` through unchanged. Lowest cost and no new AWS service |
| ACM (public) | Rejected | ACM does not export the private key of a public certificate, so nginx cannot read it. Public certs also need a public name and are not for `*.dev.internal` |
| ACM Private CA (general purpose) | Rejected for DEV | About $400/month per CA (assumed), plus per-certificate fees. Overkill for two internal clients. Its exportable private certs can feed nginx, so it stays the fallback if the security review requires a managed CA |
| ACM PCA short-lived mode | Rejected | About $50/month per CA (assumed). Certificates last at most 7 days, which needs an automated reissue loop that does not exist |
| Self-managed CA stored in Secrets Manager | Only the CA certificate is stored there. The CA private key stays offline | Keeping the root key in an AWS secret would let any role that reads it mint trusted certificates. The offline key is a one-time signing step per leaf rotation, done by an operator |

## 2. Recommended secret layout

Three secrets, all **plaintext SecretString** (single PEM value each, not JSON). Names follow the existing `ranikun/dev/<service>/<purpose>` convention (`ranikun/dev/carelog/enrollment-service` already exists).

| Secret name | Content | Read by | Container env name | Access |
| --- | --- | --- | --- | --- |
| `ranikun/dev/carelog/enrollment-tls/server-cert` | Leaf server certificate, PEM (no key) | Carelog execution role (proxy) | `TLS_CERT_PEM` | proxy only |
| `ranikun/dev/carelog/enrollment-tls/server-key` | Leaf private key, PEM (unencrypted, needed by nginx) | Carelog execution role (proxy) | `TLS_KEY_PEM` | proxy only |
| `ranikun/dev/carelog/enrollment-tls/ca-cert` | Dev CA certificate, PEM. **Public. Never the CA key.** | Platform Core execution role (trust-init) | `CARELOG_CA_PEM` | trust-init only |

Secret ARNs get a random 6-character suffix. The Terraform inputs (`enrollment_tls_candidate.secret_arns`, the `secrets` map) must use the **full ARN including suffix**, which is known only after creation. IAM resources use `...-??????` patterns (see `prep-iam-boundary.md`).

Key layout note: the candidate uses bare ARNs, which return the whole secret string. JSON keys with `:key::` would need the `arn:...:secret:NAME-SUFFIX:KEY::` form. The layout above avoids that entirely. If JSON is chosen later, every `valueFrom` in `task-fragments.json` and the tfvars must change to the `:KEY::` form.

Why three secrets and not one: the Core role must not be able to read the server key, and the proxy must not be able to read the CA key (it never has it). Separate ARNs give each role exactly what it needs.

## 3. Certificates

- **CA** (offline, operator workstation): ECDSA P-256, self-signed, `basicConstraints=CA:TRUE`, `keyUsage=keyCertSign,cRLSign`, validity 2 years, subject `CN=ranikun dev carelog enrollment CA`. The CA key is stored offline, not in AWS.
- **Leaf** (proxy): ECDSA P-256, `basicConstraints=CA:FALSE`, `keyUsage=digitalSignature`, `extendedKeyUsage=serverAuth`, validity 180 days. SAN **must** contain `DNS:ranikun-carelog-dev-api.dev.internal` (the Cloud Map name Core connects to, from `platform.tfvars.example`). The IP SAN used in the local test is not needed in production.
- Key type: ECDSA P-256 is supported by nginx and by the Core JDK. The local test used RSA 2048 for the throwaway material. Either works. Pick one and record it.

Checked locally: the leaf verifies against the CA with `openssl verify` (PASS), and the JDK in the Core image trusts it only after the init store includes the CA (PASS, see `prep-images.md` section 4).

## 4. Rotation

**Leaf (server cert and key), every 180 days or on compromise:**
1. Generate a new key and CSR offline, sign with the offline CA, verify the chain and the SAN.
2. Put new `server-cert` and `server-key` versions into the same secrets (`PutSecretValue`, AWSCURRENT). Old versions stay until the rollout finishes.
3. Register a new Carelog task definition revision that references the same ARNs. ECS reads secret values **at task start**, so existing tasks keep the old key until they are replaced. A rolling deployment replaces them.
4. Verify with the proxy health check and a TLS handshake from a Core task. Then remove the old versions (or let them age out).

Rotation has no automatic Lambda in this design. Adding Secrets Manager rotation is possible later but needs a rotation function with its own role, and the cost is not included here.

**CA (dev CA certificate):**
- Core trust-init builds the store from `CARELOG_CA_PEM` at task start. Rotating the CA needs the new CA **and** the old CA trusted during overlap. `trust-init.sh` imports only one certificate today. A two-CA bundle was **not tested** (open question). Until that is tested, the safe option is a single CA with a planned stop-and-replace window in DEV.

**Access for rotation:** only the operator and a reviewer. No role in this design needs `PutSecretValue`.

## 5. KMS

Recommendation: **AWS managed key `aws/secretsmanager`** (the default). The existing `ranikun/dev/*` secrets use it, and no `KmsKeyId` is set on any of them (checked with `list-secrets`, read-only). With this key the execution role needs `secretsmanager:GetSecretValue` only. **No `kms:Decrypt` statement is needed.**

Customer managed key (CMK) only if the security review requires it:
- Cost (assumed): $1.00/month per key plus about $0.03 per 10,000 requests. Requests here are per task start, so the request cost is negligible.
- Changes needed: a key policy that allows the Carelog and Platform execution roles with `kms:ViaService = secretsmanager.ap-northeast-2.amazonaws.com`, and `kms:Decrypt` in each boundary plus the Terraform `execution_kms_key_arns` input (already supported by the module).

## 6. Cost estimate (DEV, per month, assumptions dated 2026-11-24)

| Item | Unit price (assumed) | Quantity | Monthly |
| --- | --- | --- | --- |
| Secrets Manager secrets (3 new) | $0.40 per secret-month | 3 | $1.20 |
| Secrets Manager API calls | $0.05 per 10,000 calls | About 1,000 task starts per month x 3 reads = 3,000 calls | about $0.02 |
| ECR storage, `ranikun/carelog/tls-proxy` (75 MB image) | $0.10 per GB-month | about 0.1 GB with 2 tags kept | about $0.01 |
| ECR storage, `ranikun/platform/core-trust-init` (749 MB, shares the Core base layers) | $0.10 per GB-month | up to about 1 GB with 10 tags, layers mostly shared | about $0.10 (less if layers dedupe) |
| KMS (AWS managed key) | $0 | 1 | $0 |
| Alternative: CMK | $1.00 per key-month | 1 | $1.00 (not recommended) |
| Alternative: ACM PCA general purpose | About $400 per CA-month | 1 | about $400 (rejected) |
| Alternative: ACM PCA short-lived | About $50 per CA-month | 1 | about $50 (rejected) |

Recommended total: about **$1.35 per month**, plus Fargate cost of the sidecar, which is in `prep-aws-changes.md`. One-time cost: $0 (secret creation is free beyond the monthly charge).

## 7. Local end-to-end check (done, throwaway material)

Using the same proxy and trust-init images built in `prep-images.md`:
- nginx `-t` passes with a throwaway leaf and key delivered through `TLS_CERT_PEM` / `TLS_KEY_PEM`.
- HTTPS to 8443 with the correct CA and name reaches the proxied backend. Wrong CA and wrong name fail verification.
- Trust-init imports the throwaway CA into a copy of the Core store (118 entries). A JDK client in the Core image trusts it, rejects a wrong name, and rejects the store without the CA.

This does not test the AWS secret read, the ECS delivery of the secret values, or real DNS. Those need the real resources.

## 8. Missing references (need AWS writes, not done)

- Secret ARNs for `server-cert`, `server-key`, `ca-cert`: **not created**.
- Real leaf certificate and key, real CA certificate: **not generated** (no production material was created).
- Proxy and init image digests: **not pushed**.

## 9. Open questions

1. CA rotation with a two-CA bundle in `trust-init.sh` is untested (section 4).
2. Is ECDSA acceptable to the Core JDK in the production image? Only tested with RSA here. ECDSA P-256 is standard, but test it with the real CA before choosing.
3. Is the CMK requirement a security-review decision? If yes, the boundary and key policy change grows (see `prep-iam-boundary.md`).
4. Who holds the offline CA key and the signing procedure? Not defined in the repo.
