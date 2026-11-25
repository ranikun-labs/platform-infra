import os, re, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
WORKFLOWS = os.path.join(HERE, "..", "..", "workflows")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PLAN_JOBS = ("plan-carelog-platform", "plan-finance")
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
            self.assertEqual(jobs[name]["environment"], "dev-plan")
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

    def test_allowlist_present_and_fail_closed(self):
        validate = self.doc["jobs"]["validate"]
        script = next(s["run"] for s in validate["steps"] if "allowed=(" in s.get("run", ""))
        self.assertIn("(( ${#allowed[@]} > 0 ))", script)
