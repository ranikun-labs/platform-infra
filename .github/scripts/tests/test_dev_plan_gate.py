import json, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "dev_plan_gate.py")
FIX = os.path.join(HERE, "fixtures")
SECRETS = ["SYNTH-SECRET-VALUE-AAA", "SYNTH-SECRET-VALUE-BBB", "SYNTH-KEY-VALUE-CCC",
           "SYNTH-NAME-DDD", "SYNTH-FIN-NAME", "SYNTH-ROLE", "SYNTH-SECRET-NAME", "123456789012"]
TASKDEF = "module.service.aws_ecs_task_definition.baseline"


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


def rc_row(address, actions, before=None, after=None, previous=None):
    row = {"address": address, "change": {"actions": actions, "before": before, "after": after}}
    if previous:
        row["previous_address"] = previous
    return row


def plan_with(rows, version="1.10.5"):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "plan.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"format_version": "1.2", "terraform_version": version, "resource_changes": rows}, fh)
    return path


def gate_off(rows):
    return run(plan_with(rows), "off")


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

    def test_report_mode_delete_is_reported_not_gated(self):
        rc, out, text = run(plan_with([rc_row("aws_s3_bucket.x", ["delete"], before={})]), "report",
                            root="finance")
        self.assertEqual(rc, 0)
        self.assertIn("delete", text)
        self.assertNotIn("OFF gate", text)

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

    # --- violation kinds: each must fail the OFF gate ---

    def test_delete_fails_gate(self):
        rc, out, text = gate_off([rc_row("aws_s3_bucket.x", ["delete"], before={})])
        self.assertEqual(rc, 2)
        self.assertIn("delete aws_s3_bucket.x", text)

    def test_forget_fails_gate(self):
        rc, out, text = gate_off([rc_row("aws_s3_bucket.x", ["forget"], before={})])
        self.assertEqual(rc, 2)
        self.assertIn("forget aws_s3_bucket.x", text)

    def test_taskdef_update_fails_gate(self):
        # Only a replace of the baseline task definition is allowed, never an in-place update.
        rc, out, text = gate_off([rc_row(TASKDEF, ["update"], before={"family": "f"}, after={"family": "g"})])
        self.assertEqual(rc, 2)
        self.assertIn("OFF gate: FAIL", text)

    def test_moved_plus_update_fails_gate(self):
        rc, out, text = gate_off([rc_row("aws_s3_bucket.new", ["update"], before={"a": 1}, after={"a": 2},
                                         previous="aws_s3_bucket.old")])
        self.assertEqual(rc, 2)
        self.assertIn("update aws_s3_bucket.new", text)

    def test_indexed_taskdef_replace_fails_gate(self):
        # Only the non-indexed baseline is exempt; an indexed revision replace is a violation.
        rc, out, text = gate_off([rc_row(TASKDEF + '["SYNTH-KEY-VALUE-CCC"]', ["create", "delete"],
                                         before={}, after={})])
        self.assertEqual(rc, 2)
        self.assertIn("OFF gate: FAIL", text)
        self.assertNotIn("SYNTH-KEY-VALUE-CCC", text)

    def test_baseline_taskdef_replace_passes(self):
        rc, out, text = gate_off([rc_row(TASKDEF, ["create", "delete"], before={}, after={})])
        self.assertEqual(rc, 0)
        self.assertIn("OFF gate: PASS", text)

    # --- skip paths and AccessDenied ---

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

    def test_skip_s3_state_access_denied_hint(self):
        d = tempfile.mkdtemp()
        log = os.path.join(d, "init.log")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("Error: Failed to get existing workspaces: S3 bucket SYNTH-SECRET-NAME: AccessDenied: Access Denied\n")
        rc, out, text = run("/nonexistent/plan.json", "off", skip="init-failed", logs=[log])
        self.assertEqual(rc, 2)
        self.assertIn("state backend", text)
        self.assertIn("unparsed", text)
        self.assertNotIn("SYNTH-SECRET-NAME", text)

    def test_skip_unauthorized_operation_hint(self):
        d = tempfile.mkdtemp()
        log = os.path.join(d, "plan.log")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("Error: UnauthorizedOperation: You are not authorized to perform this operation.\n")
        rc, out, text = run("/nonexistent/plan.json", "off", skip="plan-failed", logs=[log])
        self.assertIn("EC2 describe/read permission", text)

    def test_skip_scan_failed_code(self):
        rc, out, text = run("/nonexistent/plan.json", "off", skip="scan-failed")
        self.assertEqual(rc, 2)
        self.assertIn("pre-init trust scan", text)

    def test_skip_missing_secret_key_report_mode_exits_zero(self):
        rc, out, text = run("/nonexistent/plan.json", "report", root="finance", skip="missing-secret-key")
        self.assertEqual(rc, 0)
        self.assertIn("preserve secret has no object", text)

    def test_unknown_skip_code_rejected(self):
        rc, out, text = run("/nonexistent/plan.json", "off", skip="made-up")
        self.assertEqual(rc, 3)


if __name__ == "__main__":
    unittest.main()
