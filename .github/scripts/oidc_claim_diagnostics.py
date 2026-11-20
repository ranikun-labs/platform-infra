"""Print an allowlist of GitHub OIDC metadata; never print or persist a JWT.

This diagnoses claim shape only. It does not verify a signature, assume an AWS
role, authorize a caller, or modify any AWS/GitHub configuration.
"""

import base64
import json
import os
import sys
import urllib.parse
import urllib.request

AUDIENCE = "sts.amazonaws.com"
ALLOWED_CLAIMS = (
    "iss", "aud", "sub", "repository", "repository_id",
    "repository_owner_id", "ref", "environment", "workflow_ref",
    "job_workflow_ref", "run_id", "run_attempt",
)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("OIDC request redirect rejected")


def filtered_claims(token):
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("Unexpected token shape")
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
    if not isinstance(claims, dict):
        raise ValueError("Unexpected claim object")
    result = {}
    for key in ALLOWED_CLAIMS:
        value = claims.get(key)
        if value is None or isinstance(value, (str, int, bool)):
            if isinstance(value, str) and len(value) > 4096:
                raise ValueError("Oversized selected claim")
            result[key] = value
        elif key == "aud" and isinstance(value, list) and all(
            isinstance(item, str) and len(item) <= 4096 for item in value
        ) and len(value) <= 16:
            result[key] = value
        else:
            raise ValueError("Unexpected selected claim type")
    return result


def request_url(value):
    parsed = urllib.parse.urlsplit(value)
    host = parsed.hostname or ""
    if (
        parsed.scheme != "https"
        or not host.endswith(".actions.githubusercontent.com")
        or parsed.port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
    ):
        raise ValueError("Unexpected GitHub OIDC endpoint")
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    query = [(key, val) for key, val in query if key != "audience"]
    query.append(("audience", AUDIENCE))
    return urllib.parse.urlunsplit(parsed._replace(query=urllib.parse.urlencode(query)))


def main():
    try:
        url = request_url(os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"])
        request = urllib.request.Request(
            url,
            headers={"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]},
        )
        # No redirects: the request credential must stay on the GitHub endpoint.
        opener = urllib.request.build_opener(NoRedirect())
        with opener.open(request, timeout=20) as response:
            document = json.loads(response.read(65537))
        claims = filtered_claims(document["value"])
    except Exception:
        # Do not include exception text, response bodies, URLs, headers or JWTs.
        print("OIDC claim diagnostics failed; raw response and credentials omitted.", file=sys.stderr)
        return 1
    print(json.dumps({
        "diagnostic_only": True,
        "signature_verified_locally": False,
        "requested_audience": AUDIENCE,
        "claims": claims,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
