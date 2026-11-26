import copy, os, re, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
WORKFLOWS = os.path.join(HERE, "..", "..", "workflows")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PLAN_JOBS = ("plan-carelog-platform", "plan-finance")
PLAN_ENVIRONMENT = "dev-signup-off-plan"
PLAN_ROLE_ARN = "arn:aws:iam::124495093425:role/ranikun-dev-signup-off-plan"
PLAN_ROLE_SESSION = "arn:aws:sts::124495093425:assumed-role/ranikun-dev-signup-off-plan/*"
CANDIDATE_B = "865138736fa38a18171cb566720a12e21ec587c6"
CANDIDATE_TERRAFORM_STEPS = ("Terraform init", "Plan")


def load(name):
    import yaml
    with open(os.path.join(WORKFLOWS, name), encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def step_names(job):
    return [s.get("name", "") for s in job["steps"]]


def index_of(job, prefix):
    for i, s in enumerate(job["steps"]):
        if str(s.get("name", "")).startswith(prefix):
            return i
    raise AssertionError(f"no step starting with {prefix!r}")


class PlanWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc = load("dev-signup-off-plan.yml")
        cls.shared = load("dev-shared-plan.yml")

    def test_trigger_and_permissions(self):
        on = self.doc.get(True, self.doc.get("on"))
        self.assertEqual(set(on.keys()), {"workflow_dispatch"})
        self.assertEqual(self.doc["permissions"], {})

    def test_jobs_gated_to_main_and_environment(self):
        jobs = self.doc["jobs"]
        self.assertEqual(set(jobs), {"validate", "plan-carelog-platform", "plan-finance"})
        for name, j in jobs.items():
            self.assertIn("refs/heads/main", j["if"], name)
        for name in PLAN_JOBS:
            self.assertEqual(jobs[name]["environment"], PLAN_ENVIRONMENT)
            self.assertEqual(jobs[name]["permissions"], {"contents": "read", "id-token": "write"})
            self.assertEqual(jobs[name]["concurrency"]["group"], "dev-signup-off-plan")
        self.assertEqual(jobs["plan-carelog-platform"]["needs"], "validate")
        self.assertEqual(jobs["plan-finance"]["needs"], ["validate", "plan-carelog-platform"])

    def test_matrix_serial_and_own_concurrency_group(self):
        plan = self.doc["jobs"]["plan-carelog-platform"]
        self.assertEqual(plan["strategy"]["max-parallel"], 1)
        self.assertNotEqual(plan["concurrency"]["group"], "dev-shared-terraform-plan")

    def test_no_inputs_interpolated_in_run_blocks(self):
        for name, job in self.doc["jobs"].items():
            for step in job["steps"]:
                self.assertNotIn("${{ inputs", str(step.get("run", "")), f"{name}: {step.get('name')}")

    def test_oidc_after_candidate_checkout_and_scan(self):
        for name in PLAN_JOBS:
            job = self.doc["jobs"][name]
            cand = index_of(job, "Check out candidate")
            scan = index_of(job, "Pre-init trust scan")
            oidc = next(i for i, s in enumerate(job["steps"])
                        if str(s.get("uses", "")).startswith("aws-actions/configure-aws-credentials@"))
            self.assertLess(cand, scan, name)
            self.assertLess(scan, oidc, name)

    def test_oidc_role_duration_is_900(self):
        for name in PLAN_JOBS:
            job = self.doc["jobs"][name]
            oidc = next(s for s in job["steps"]
                        if str(s.get("uses", "")).startswith("aws-actions/configure-aws-credentials@"))
            self.assertEqual(str(oidc["with"]["role-duration-seconds"]), "900", name)

    def test_candidate_terraform_steps_blank_oidc_token_env(self):
        for name in PLAN_JOBS:
            job = self.doc["jobs"][name]
            for step in job["steps"]:
                if str(step.get("name", "")).startswith(CANDIDATE_TERRAFORM_STEPS):
                    env = step.get("env", {})
                    self.assertEqual(env.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN"), "", f"{name}: {step['name']}")
                    self.assertEqual(env.get("ACTIONS_ID_TOKEN_REQUEST_URL"), "", f"{name}: {step['name']}")
                    self.assertIn("env -u GITHUB_STEP_SUMMARY", step["run"], step["name"])

    def test_preserve_masks_scalars_and_umask_set(self):
        for name in PLAN_JOBS:
            job = self.doc["jobs"][name]
            run = next(s["run"] for s in job["steps"] if str(s.get("name", "")).startswith("Materialize"))
            self.assertIn("umask 077", run, name)
            self.assertIn("::add-mask::", run, name)
            self.assertIn("scalars", run, name)
            self.assertIn("is not valid JSON", run, name)

    def test_trusted_tools_hash_verified_before_each_run(self):
        for name in PLAN_JOBS:
            job = self.doc["jobs"][name]
            for step in job["steps"]:
                run = str(step.get("run", ""))
                if str(step.get("name", "")).startswith("Record"):
                    continue  # records the hashes; the check happens in each run step
                if "dev_plan_gate.py" in run or "dev_candidate_scan.py" in run:
                    self.assertIn("sha256sum -c", step["run"], f"{name}: {step.get('name')}")
                    self.assertIn("env -i PATH=/usr/bin:/bin /usr/bin/python3 -I", step["run"], step["name"])

    def test_always_cleanup_removes_plans_and_terraform_dir(self):
        for name in PLAN_JOBS:
            job = self.doc["jobs"][name]
            cleanup = [s for s in job["steps"] if str(s.get("name", "")).startswith("Cleanup")]
            self.assertEqual(len(cleanup), 1, name)
            self.assertEqual(cleanup[0].get("if"), "always()", name)
            self.assertIn("*.tfplan", cleanup[0]["run"], name)
            self.assertIn(".terraform", cleanup[0]["run"], name)

    def test_all_uses_pinned_like_dev_shared_plan(self):
        # Compare every uses: in the new workflow against the same action in dev-shared-plan.yml.
        def uses_set(doc, prefix):
            return {s["uses"] for job in doc["jobs"].values() for s in job["steps"]
                    if str(s.get("uses", "")).startswith(prefix)}
        for prefix in ("aws-actions/configure-aws-credentials@", "hashicorp/setup-terraform@",
                       "actions/checkout@"):
            new = uses_set(self.doc, prefix)
            shared = uses_set(self.shared, prefix)
            self.assertTrue(new, prefix)
            for u in new:
                # The pin is the 40-hex SHA before the version comment.
                self.assertRegex(u.split("@", 1)[1].split()[0], SHA_RE, u)
            self.assertEqual(new, shared, prefix)

    def test_terraform_pinned(self):
        for job in self.doc["jobs"].values():
            for s in job["steps"]:
                if str(s.get("uses", "")).startswith("hashicorp/setup-terraform@"):
                    self.assertEqual(s["with"]["terraform_version"], "1.10.5")

    def test_plan_role_and_identity_check_are_dedicated(self):
        # The OFF plan must assume only the dedicated role, never the shared plan role.
        for name in PLAN_JOBS:
            job = self.doc["jobs"][name]
            oidc = next(s for s in job["steps"]
                        if str(s.get("uses", "")).startswith("aws-actions/configure-aws-credentials@"))
            self.assertEqual(oidc["with"]["role-to-assume"], PLAN_ROLE_ARN, name)
            verify = next(s["run"] for s in job["steps"] if s.get("name") == "Verify AWS identity")
            self.assertIn(PLAN_ROLE_SESSION, verify, name)
        self.assertNotIn("ranikun-dev-shared-plan", open(os.path.join(WORKFLOWS, "dev-signup-off-plan.yml"),
                                                       encoding="utf-8").read())

    def test_candidate_b_documented_but_not_allowlisted(self):
        raw = open(os.path.join(WORKFLOWS, "dev-signup-off-plan.yml"), encoding="utf-8").read()
        self.assertEqual(raw.count(CANDIDATE_B), 1)
        comment = [line for line in raw.splitlines() if CANDIDATE_B in line]
        self.assertTrue(all(line.lstrip().startswith("#") for line in comment))

    def test_allowlist_present_and_fail_closed(self):
        validate = self.doc["jobs"]["validate"]
        script = next(s["run"] for s in validate["steps"] if "allowed=(" in s.get("run", ""))
        self.assertIn("(( ${#allowed[@]} > 0 ))", script)


# --- egress precondition (MANDATORY before the first allowlisted SHA) ---

HARDEN_PREFIX = "step-security/harden-runner@"
GENERIC_S3_RE = re.compile(r"^s3[.-]")
FAKE_SHA = "a" * 40
BUCKET_HOST = "tfstate-bucket.s3.ap-northeast-2.amazonaws.com:443"


def allowlist_shas(doc):
    script = next(s["run"] for s in doc["jobs"]["validate"]["steps"] if "allowed=(" in s.get("run", ""))
    body = re.search(r"allowed=\((.*?)\)", script, re.S).group(1)
    # Bash comments inside the array are not entries; a commented plan must not count as pinned.
    body = "\n".join(line.split("#", 1)[0] for line in body.splitlines())
    return re.findall(r"\b[0-9a-f]{40}\b", body)


def egress_violations(doc):
    """Empty allowlist: nothing to enforce. Non-empty: every plan job must start with a pinned
    harden-runner step in block mode whose allowlist names only the bucket-specific S3 host."""
    if not allowlist_shas(doc):
        return []
    problems = []
    for name in PLAN_JOBS:
        steps = doc["jobs"][name]["steps"]
        hardens = [s for s in steps if str(s.get("uses", "")).startswith(HARDEN_PREFIX)]
        if not hardens:
            problems.append(f"{name}: no harden-runner step (egress precondition)")
            continue
        harden = hardens[0]
        if steps[0] is not harden:
            problems.append(f"{name}: harden-runner must be the first step")
        if not re.fullmatch(r"[0-9a-f]{40}", harden["uses"].split("@", 1)[1]):
            problems.append(f"{name}: harden-runner is not pinned to a full SHA")
        cfg = harden.get("with") or {}
        if str(cfg.get("egress-policy")) != "block":
            problems.append(f"{name}: harden-runner egress-policy must be block")
        hosts = [e.split(":", 1)[0] for e in str(cfg.get("allowed-endpoints", "")).split()]
        if not hosts:
            problems.append(f"{name}: harden-runner allowed-endpoints missing")
        if any("*" in h for h in hosts):
            problems.append(f"{name}: wildcard egress host not allowed")
        if any(GENERIC_S3_RE.match(h) for h in hosts):
            problems.append(f"{name}: generic regional S3 host not allowed; use the bucket-specific host")
        if not any(h.endswith(".s3.ap-northeast-2.amazonaws.com") and not GENERIC_S3_RE.match(h) for h in hosts):
            problems.append(f"{name}: no bucket-specific S3 host in egress allowlist")
    return problems


def with_allowlist(doc, sha=FAKE_SHA):
    d = copy.deepcopy(doc)
    step = next(s for s in d["jobs"]["validate"]["steps"] if "allowed=(" in s.get("run", ""))
    step["run"] = re.sub(r"allowed=\((.*?)\)", lambda m: f"allowed=(\n  {sha}\n)", step["run"], count=1, flags=re.S)
    return d


def harden_step(uses_ref=FAKE_SHA, **overrides):
    cfg = {"egress-policy": "block", "allowed-endpoints": " ".join([
        "sts.ap-northeast-2.amazonaws.com:443", "registry.terraform.io:443",
        "releases.hashicorp.com:443", BUCKET_HOST])}
    cfg.update(overrides)
    return {"name": "Harden runner egress", "uses": f"{HARDEN_PREFIX}{uses_ref}", "with": cfg}


class EgressPreconditionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc = load("dev-signup-off-plan.yml")

    def test_empty_allowlist_has_no_egress_requirement(self):
        self.assertEqual(allowlist_shas(self.doc), [])
        self.assertEqual(egress_violations(self.doc), [])

    def test_nonempty_allowlist_without_harden_runner_fails(self):
        d = with_allowlist(self.doc)
        self.assertEqual(allowlist_shas(d), [FAKE_SHA])
        problems = egress_violations(d)
        for name in PLAN_JOBS:
            self.assertIn(f"{name}: no harden-runner step (egress precondition)", problems)

    def test_nonempty_allowlist_with_first_block_harden_passes(self):
        d = with_allowlist(self.doc)
        for name in PLAN_JOBS:
            d["jobs"][name]["steps"].insert(0, harden_step())
        self.assertEqual(egress_violations(d), [])

    def test_harden_runner_after_checkout_fails(self):
        d = with_allowlist(self.doc)
        for name in PLAN_JOBS:
            d["jobs"][name]["steps"].insert(1, harden_step())
        problems = egress_violations(d)
        for name in PLAN_JOBS:
            self.assertIn(f"{name}: harden-runner must be the first step", problems)

    def test_audit_mode_fails(self):
        d = with_allowlist(self.doc)
        for name in PLAN_JOBS:
            d["jobs"][name]["steps"].insert(0, harden_step(**{"egress-policy": "audit"}))
        self.assertTrue(all("egress-policy must be block" in p for p in egress_violations(d)))
        self.assertEqual(len(egress_violations(d)), len(PLAN_JOBS))

    def test_generic_regional_s3_host_fails(self):
        d = with_allowlist(self.doc)
        for name in PLAN_JOBS:
            d["jobs"][name]["steps"].insert(0, harden_step(**{
                "allowed-endpoints": BUCKET_HOST + " s3.ap-northeast-2.amazonaws.com:443"}))
        self.assertTrue(any("generic regional S3 host" in p for p in egress_violations(d)))

    def test_missing_bucket_specific_host_fails(self):
        d = with_allowlist(self.doc)
        for name in PLAN_JOBS:
            d["jobs"][name]["steps"].insert(0, harden_step(**{
                "allowed-endpoints": "sts.ap-northeast-2.amazonaws.com:443 registry.terraform.io:443"}))
        self.assertTrue(any("no bucket-specific S3 host" in p for p in egress_violations(d)))

    def test_wildcard_host_fails(self):
        d = with_allowlist(self.doc)
        for name in PLAN_JOBS:
            d["jobs"][name]["steps"].insert(0, harden_step(**{"allowed-endpoints": "*.amazonaws.com:443"}))
        self.assertTrue(any("wildcard" in p for p in egress_violations(d)))

    def test_unpinned_harden_runner_fails(self):
        d = with_allowlist(self.doc)
        for name in PLAN_JOBS:
            d["jobs"][name]["steps"].insert(0, harden_step(uses_ref="v2"))
        self.assertTrue(any("not pinned to a full SHA" in p for p in egress_violations(d)))

    def test_real_workflow_precondition_state_is_enforced(self):
        # The committed workflow must satisfy the precondition in whatever state it is in. Today the
        # allowlist is empty, so this is a no-op; the first SHA added makes it enforce the egress step.
        self.assertEqual(egress_violations(self.doc), [])
