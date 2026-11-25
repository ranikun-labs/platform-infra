import os, shutil, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCAN = os.path.join(HERE, "..", "dev_candidate_scan.py")

VERSIONS = '''terraform {
  required_version = "1.10.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.80.0"
    }
  }
  backend "s3" {
    bucket = "ranikun-dev-tfstate-124495093425"
    key    = "dev/carelog/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
'''
MAIN = '''data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "b" {
  bucket = "example-bucket"
}

module "x" {
  source = "../../../modules/x"
}
'''
MODULE = 'resource "aws_iam_role" "r" {\n  name = "example"\n}\n'
LOCK = '# lock\nprovider "registry.terraform.io/hashicorp/aws" {\n  version = "5.80.0"\n}\n'


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def make_tree(base, versions=VERSIONS, main=MAIN, lock=LOCK):
    """Build a repo-shaped checkout: environments/dev/carelog plus modules/x."""
    write(os.path.join(base, "environments/dev/carelog/versions.tf"), versions)
    write(os.path.join(base, "environments/dev/carelog/main.tf"), main)
    write(os.path.join(base, "environments/dev/carelog/.terraform.lock.hcl"), lock)
    write(os.path.join(base, "modules/x/main.tf"), MODULE)


def scan(candidate_mutator=None, trusted_mutator=None):
    tmp = tempfile.mkdtemp()
    cand = os.path.join(tmp, "candidate")
    trusted = os.path.join(tmp, "trusted")
    make_tree(trusted)
    make_tree(cand)
    if candidate_mutator:
        candidate_mutator(cand)
    if trusted_mutator:
        trusted_mutator(trusted)
    summary = os.path.join(tmp, "scan.md")
    p = subprocess.run([sys.executable, "-I", SCAN, "--candidate-root", cand, "--trusted-root", trusted,
                        "--root", "carelog", "--summary", summary], capture_output=True, text=True)
    with open(summary, encoding="utf-8") as fh:
        return p.returncode, p.stdout + p.stderr


def cand_file(cand, rel, text):
    write(os.path.join(cand, rel), text)


ROOT = "environments/dev/carelog"


class ScanTests(unittest.TestCase):
    def assertFails(self, rc_text, needle):
        rc, text = rc_text
        self.assertEqual(rc, 2, text)
        self.assertIn("Scan: FAIL", text)
        self.assertIn(needle, text)

    def test_clean_candidate_passes(self):
        rc, text = scan()
        self.assertEqual(rc, 0, text)
        self.assertIn("Scan: PASS", text)

    def test_data_external_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf",
                                                  'data "external" "x" {\n  program = ["sh"]\n}\n')),
                         "data source type 'external' not allowed")

    def test_data_http_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf",
                                                  'data "http" "x" {\n  url = "https://example.com"\n}\n')),
                         "data source type 'http' not allowed")

    def test_null_resource_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf",
                                                  'resource "null_resource" "x" {}\n')),
                         "resource type 'null_resource' not allowed")

    def test_provisioner_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf",
                                                  'resource "aws_s3_bucket" "b" {\n  bucket = "x"\n'
                                                  '  provisioner "local-exec" {\n    command = "true"\n  }\n}\n')),
                         "provisioner not allowed")

    def test_extra_provider_in_required_providers_rejected(self):
        bad = VERSIONS.replace('  required_providers {\n',
                               '  required_providers {\n    http = {\n      source = "hashicorp/http"\n    }\n')
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/versions.tf", bad)),
                         "required provider 'http' not allowed")

    def test_provider_block_other_than_aws_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", 'provider "local" {}\n')),
                         "provider 'local' not allowed")

    def test_non_local_module_source_rejected(self):
        bad = MAIN.replace('../../../modules/x', 'git::https://example.com/mod.git')
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/main.tf", bad)),
                         "non-local module source not allowed")

    def test_module_source_escaping_checkout_rejected(self):
        def outside(c):
            os.makedirs(os.path.join(os.path.dirname(c), "outside"), exist_ok=True)
            write(os.path.join(os.path.dirname(c), "outside/main.tf"), MODULE)
            cand_file(c, ROOT + "/main.tf", MAIN.replace('../../../modules/x', '../../../../outside'))
        self.assertFails(scan(outside), "escapes the candidate checkout")

    def test_symlink_rejected(self):
        def link(c):
            os.symlink("/etc/hostname", os.path.join(c, ROOT, "link.tf"))
        self.assertFails(scan(link), "symlink not allowed")

    def test_tf_json_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf.json", "{}")), "*.tf.json not allowed")

    def test_committed_terraform_dir_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/.terraform/x", "x")),
                         "committed .terraform/ directory not allowed")

    def test_tfvars_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/prod.auto.tfvars", "a = 1")),
                         "tfvars file")

    def test_override_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/main_override.tf", "")), "override files")

    def test_cloud_block_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf",
                                                  'terraform {\n  cloud {\n    organization = "x"\n  }\n}\n')),
                         "cloud block not allowed")

    def test_lock_file_must_match_main(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/.terraform.lock.hcl", LOCK + "# extra\n")),
                         ".terraform.lock.hcl differs from main")

    def test_backend_key_change_rejected(self):
        changed = VERSIONS.replace("dev/carelog/terraform.tfstate", "dev/platform/terraform.tfstate")
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/versions.tf", changed)),
                         "s3 backend block differs from main")

    def test_backend_outside_versions_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf",
                                                  'terraform {\n  backend "local" {}\n}\n')),
                         "backend 'local' outside versions.tf or not s3")


if __name__ == "__main__":
    unittest.main()
