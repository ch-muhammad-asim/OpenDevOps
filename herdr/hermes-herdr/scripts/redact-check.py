# Runs INSIDE herdr-hermes (piped in by e2e-redaction.sh test 16, offline, no model): feeds FAKE secret-shaped values
# through Hermes's own redactor (agent.redact.redact_sensitive_text, unforced, so it follows the redaction switch) and
# prints only per-pattern masked yes/no plus counts. Never prints an input or output value.
import os
import random
import string
import sys

sys.path.insert(0, "/opt/hermes")
from agent import redact  # noqa: E402

rng = random.SystemRandom()


def rand(n, alphabet=string.ascii_letters + string.digits):
    return "".join(rng.choice(alphabet) for _ in range(n))


fake = {
    "sk-test": "sk-test-" + rand(30),
    "nvapi": "nvapi-FAKE" + rand(30),
    "ghp": "ghp_" + rand(36),
    "password": "FakePass" + rand(3, string.digits),
    "bearer": "FAKE" + rand(36),
}
cases = {
    "sk-test": "TEST_API_KEY=%s" % fake["sk-test"],
    "nvapi": "export NVIDIA_API_KEY=%s" % fake["nvapi"],
    "ghp": "token %s in a sentence" % fake["ghp"],
    "password": "password=%s" % fake["password"],
    "bearer": "Authorization: Bearer %s" % fake["bearer"],
}

# Effective switch: the redactor's import-time snapshot (HERMES_REDACT_SECRETS) and the managed config value.
cfg = "unknown"
try:
    from hermes_constants import get_hermes_home
    from hermes_cli.config_effective import load_user_config_effective

    path = get_hermes_home() / "config.yaml"
    if path.exists():
        cfg = str((load_user_config_effective(path).get("security") or {}).get("redact_secrets"))
    else:
        cfg = "no-config"
except Exception as exc:  # report only the exception type, never its text
    cfg = "error:" + type(exc).__name__

masked = 0
for name, text in cases.items():
    out = redact.redact_sensitive_text(text)
    ok = fake[name] not in out
    masked += ok
    print("%-8s masked=%s" % (name, "yes" if ok else "no"))
# Info only, not counted: mid-line `key=value` after other words (upstream masks line-start/export/--flag forms only).
info = redact.redact_sensitive_text("mysql -u root password=%s" % fake["password"])
print("info: mid-line 'cmd ... password=' masked=%s (not counted)" % ("yes" if fake["password"] not in info else "no"))
print("redactor enabled=%s; security.redact_secrets=%s; env HERMES_REDACT_SECRETS=%s"
      % ("yes" if redact._redact_enabled() else "no", cfg, os.environ.get("HERMES_REDACT_SECRETS", "unset")))
print("masked %d/%d" % (masked, len(cases)))
