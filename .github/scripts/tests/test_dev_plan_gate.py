import json, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "dev_plan_gate.py")
FIX = os.path.join(HERE, "fixtures")
WORKFLOWS = os.path.join(HERE, "..", "..", "workflows")
SECRETS = ["SYNTH-SECRET-VALUE-AAA", "SYNTH-SECRET-VALUE-BBB", "SYNTH-KEY-VALUE-CCC",
           "SYNTH-NAME-DDD", "SYNTH-FIN-NAME", "SYNTH-ROLE", "SYNTH-SECRET-NAME", "123456789012"]


def run(plan, mode, root="carelog", logs=(), skip=None):
    d = tempfile.mkdtemp()
    summary = os.path.join(d, "s.md")
    cmd = [sys.executable, "-I", SCRIPT, "--root", root, "--mode", mode,
           "--plan-json", plan, "--summary", summary]
    for log in logs:
        cmd += ["--log", log]
    if skip is not None:
        cmd += ["--skip-code", skip]
    p = subprocess.run(cmd, capture_output=True, text=True)
    with open(summary, encoding="utf-8") as fh:
        text = fh.read()
    return p.returncode, p.stdout + p.stderr, text


class GateTests(unittest.TestCase):
    def test_off_pass(self):
        rc, out, text = run(os.path.join(FIX, "off_pass.json"), "off")
        self.assertEqual(rc, 0, text)
        self.assertIn("OFF gate: PASS", text)
        self.assertIn("Expected: 1 task-definition", text)
        self.assertIn("moved", text)

    def test_off_fail_masks_values_and_keys(self):
        rc, out, text = run(os.path.join(FIX, "off_fail.json"), "off")
        self.assertEqual(rc, 2)
        self.assertIn("OFF gate: FAIL", text)
        self.assertIn("module.core.aws_ecs_service.service", text)
        self.assertIn("environment (value masked)", text)
        self.assertIn("aws_security_group.extra[key omitted]", text)
        for s in SECRETS:
            self.assertNotIn(s, text)
            self.assertNotIn(s, out)

    def test_report_mode_no_gate(self):
        rc, out, text = run(os.path.join(FIX, "report_finance.json"), "report", root="finance")
        self.assertEqual(rc, 0)
        self.assertNotIn("OFF gate", text)
        self.assertIn("create 2", text)
        for s in SECRETS:
            self.assertNotIn(s, text)

    def test_undeclared_variable_fails_gate(self):
        rc, out, text = run(os.path.join(FIX, "off_pass.json"), "off",
                            logs=[os.path.join(FIX, "undeclared.log")])
        self.assertEqual(rc, 2)
        self.assertIn("OFF gate: FAIL", text)

    def test_bad_terraform_version(self):
        rc, out, text = run(os.path.join(FIX, "bad_version.json"), "off")
        self.assertEqual(rc, 3)

    def test_missing_plan_fails_closed(self):
        rc, out, text = run("/nonexistent/plan.json", "off")
        self.assertEqual(rc, 2)
        self.assertIn("did not complete", text)

    def test_skip_access_denied_reports_action_and_service_only(self):
        rc, out, text = run("/nonexistent/plan.json", "off", skip="plan-failed",
                            logs=[os.path.join(FIX, "access_denied.log")])
        self.assertEqual(rc, 2)
        self.assertIn("Skipped (`plan-failed`)", text)
        self.assertIn("ssm:GetParameter", text)
        self.assertIn("resource service `ssm`", text)
        for s in SECRETS:
            self.assertNotIn(s, text)
            self.assertNotIn(s, out)

    def test_skip_missing_secret_key_report_mode_exits_zero(self):
        rc, out, text = run("/nonexistent/plan.json", "report", root="finance", skip="missing-secret-key")
        self.assertEqual(rc, 0)
        self.assertIn("preserve secret has no object", text)

    def test_unknown_skip_code_rejected(self):
        rc, out, text = run("/nonexistent/plan.json", "off", skip="made-up")
        self.assertEqual(rc, 3)


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import yaml
        with open(os.path.join(WORKFLOWS, "dev-signup-off-plan.yml"), encoding="utf-8") as fh:
            cls.doc = yaml.safe_load(fh)
        with open(os.path.join(WORKFLOWS, "dev-shared-plan.yml"), encoding="utf-8") as fh:
            cls.shared = yaml.safe_load(fh)

    def test_trigger_and_permissions(self):
        on = self.doc.get(True, self.doc.get("on"))
        self.assertEqual(set(on.keys()), {"workflow_dispatch"})
        self.assertEqual(self.doc["permissions"], {})

    def test_jobs_gated_to_main_and_environment(self):
        jobs = self.doc["jobs"]
        self.assertEqual(set(jobs), {"validate", "plan-carelog-platform", "plan-finance"})
        for name, j in jobs.items():
            self.assertIn("refs/heads/main", j["if"], name)
        for name in ("plan-carelog-platform", "plan-finance"):
            self.assertEqual(jobs[name]["environment"], "dev-plan")
            self.assertEqual(jobs[name]["permissions"], {"contents": "read", "id-token": "write"})
            self.assertEqual(jobs[name]["needs"], "validate")

    def test_matrix_serial_and_shared_concurrency(self):
        plan = self.doc["jobs"]["plan-carelog-platform"]
        self.assertEqual(plan["strategy"]["max-parallel"], 1)
        self.assertEqual(plan["concurrency"]["group"], "dev-shared-terraform-plan")
        shared_jobs = self.shared["jobs"]["plan"]
        self.assertEqual(shared_jobs["concurrency"]["group"], plan["concurrency"]["group"])

    def test_oidc_action_pinned_like_dev_shared_plan(self):
        def uses_of(doc, prefix):
            for job in doc["jobs"].values():
                for step in job["steps"]:
                    if str(step.get("uses", "")).startswith(prefix):
                        return step["uses"]
        for prefix in ("aws-actions/configure-aws-credentials@", "hashicorp/setup-terraform@"):
            self.assertEqual(uses_of(self.doc, prefix), uses_of(self.shared, prefix), prefix)

    def test_terraform_pinned(self):
        steps = [s for j in self.doc["jobs"].values() for s in j["steps"]
                 if str(s.get("uses", "")).startswith("hashicorp/setup-terraform@")]
        self.assertTrue(steps)
        for s in steps:
            self.assertEqual(s["with"]["terraform_version"], "1.10.5")

    def test_allowlist_is_present_and_fail_closed_in_file(self):
        validate = self.doc["jobs"]["validate"]
        script = next(s["run"] for s in validate["steps"] if "allowed=(" in s.get("run", ""))
        self.assertIn("(( ${#allowed[@]} > 0 ))", script)


if __name__ == "__main__":
    unittest.main()
