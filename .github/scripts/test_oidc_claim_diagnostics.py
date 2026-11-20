import base64
import contextlib
import importlib.util
import io
import json
import pathlib
import unittest
from unittest import mock


path = pathlib.Path(__file__).with_name("oidc_claim_diagnostics.py")
spec = importlib.util.spec_from_file_location("oidc_claim_diagnostics", path)
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class ClaimDiagnosticsTests(unittest.TestCase):
    def test_only_allowlisted_values_are_returned_and_custom_subject_is_preserved(self):
        subject = "repo:ranikun-labs/platform-infra:environment:dev-plan:repository_id:123"
        payload = base64.urlsafe_b64encode(json.dumps({
            "sub": subject, "aud": ["sts.amazonaws.com"],
            "private_extra_claim": "must-not-be-logged", "jti": "not-needed",
        }).encode()).decode().rstrip("=")
        result = diagnostic.filtered_claims("header." + payload + ".signature")
        self.assertEqual(result["sub"], subject)
        self.assertEqual(result["aud"], ["sts.amazonaws.com"])
        self.assertNotIn("must-not-be-logged", json.dumps(result))
        self.assertNotIn("jti", result)

    def test_request_credential_cannot_be_sent_to_an_unrelated_endpoint(self):
        for url in ["http://vstoken.actions.githubusercontent.com/path", "https://example.com/path",
                    "https://user@vstoken.actions.githubusercontent.com/path"]:
            with self.assertRaises(ValueError):
                diagnostic.request_url(url)

    def test_audience_is_explicit_and_replaces_an_inherited_query_value(self):
        url = diagnostic.request_url("https://vstoken.actions.githubusercontent.com/path?audience=wrong&other=ok")
        self.assertEqual(diagnostic.urllib.parse.parse_qs(diagnostic.urllib.parse.urlsplit(url).query),
                         {"audience": ["sts.amazonaws.com"], "other": ["ok"]})

    def test_failure_does_not_echo_exception_or_credentials(self):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(diagnostic.os.environ, {
            "ACTIONS_ID_TOKEN_REQUEST_URL": "https://vstoken.actions.githubusercontent.com/path",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "synthetic-request-secret",
        }), mock.patch.object(diagnostic.urllib.request, "build_opener",
                              side_effect=RuntimeError("synthetic-request-secret raw-token")), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(diagnostic.main(), 1)
        self.assertEqual(out.getvalue(), "")
        self.assertNotIn("synthetic-request-secret", err.getvalue())
        self.assertNotIn("raw-token", err.getvalue())

    def test_malformed_token_and_redirect_are_rejected(self):
        with self.assertRaises(ValueError):
            diagnostic.filtered_claims("not-a-jwt")
        with self.assertRaises(RuntimeError):
            diagnostic.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://example.com")


if __name__ == "__main__":
    unittest.main()
