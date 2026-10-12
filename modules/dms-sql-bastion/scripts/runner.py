#!/usr/bin/env python3
"""dms-sql-bastion runner.

Runs one SQL or shell script, a named runbook, or a manifest from S3: an
ordered list of steps, each against one of the configured database targets.
Started by the SSM document's launcher, which writes this file and config.json
to a private work directory and passes the document parameters as DMS_*
environment variables.

Python 3.9 standard library only (Amazon Linux 2023 ships 3.9). AWS calls go
through the AWS CLI, which the AMI carries anyway, so the system Python needs
no boto3.

Exit codes:
  0 ok
  1 unexpected error in the runner itself
  2 a client or shell step reported an error (or a step with on_error=continue
    failed and the run carried on)
  3 integrity: a script's SHA-256 is not the expected one
  4 configuration: bad parameter, manifest, secret, missing client or bundle
  5 interrupted (SIGTERM, e.g. the document's TimeoutSeconds)
  6 a step exceeded its timeout_seconds

The database password never reaches argv, and every line of client output is
masked against it before it is printed.
"""

import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

EXIT_OK = 0
EXIT_UNEXPECTED = 1
EXIT_SCRIPT = 2
EXIT_INTEGRITY = 3
EXIT_CONFIG = 4
EXIT_INTERRUPTED = 5
EXIT_TIMEOUT = 6

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,511}$")
SHA_RE = re.compile(r"^[a-f0-9]{64}$")
VAR_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
# No quote, $, backslash, ; or = : a value lands inside SQL (SET @x = '...',
# DEFINE x = "...") and inside the Variables parameter's k=v;k=v syntax.
VAR_VALUE_RE = re.compile(r"^[A-Za-z0-9 _.,:/@+%-]{0,256}$")

STEP_KEYS = {
    "name", "target", "script", "sha256", "type", "transaction",
    "timeout_seconds", "on_error", "variables",
}
MANIFEST_KEYS = {"description", "steps"}
TYPES = ("sql", "shell")
TRANSACTIONS = ("auto", "single", "none")
ON_ERROR = ("stop", "continue")
MAX_STEPS = 200
MAX_TIMEOUT = 172800

PROBES = {
    "postgres": "SELECT current_user, current_database(), version();\n",
    "mysql": "SELECT CURRENT_USER(), DATABASE(), VERSION();\n",
    "oracle": "SELECT USER, SYS_CONTEXT('USERENV', 'DB_NAME') FROM dual;\n",
}


class RunError(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


class Masker:
    """Replaces every registered secret in text, longest first."""

    def __init__(self):
        self._secrets = []

    def add(self, value):
        if value and value not in self._secrets:
            self._secrets.append(value)
            self._secrets.sort(key=len, reverse=True)

    def mask(self, text):
        for s in self._secrets:
            text = text.replace(s, "****")
        return text


MASK = Masker()


def log(message):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(MASK.mask("%s %s" % (stamp, message)), flush=True)


# ---------------------------------------------------------------------------
# Configuration and parameters
# ---------------------------------------------------------------------------


def parse_variables(text, where):
    out = {}
    if not text:
        return out
    for pair in text.split(";"):
        if "=" not in pair:
            raise RunError("%s: %r is not name=value" % (where, pair), EXIT_CONFIG)
        name, value = pair.split("=", 1)
        check_variable(name, value, where)
        out[name] = value
    return out


def check_variable(name, value, where):
    if not VAR_NAME_RE.match(name):
        raise RunError("%s: variable name %r is not an identifier" % (where, name), EXIT_CONFIG)
    if not isinstance(value, str) or not VAR_VALUE_RE.match(value):
        raise RunError(
            "%s: variable %s has a value with a character outside letters, digits, space and _ . , : / @ + %% -" % (where, name),
            EXIT_CONFIG,
        )


def normalize_step(raw, index, cfg, where):
    """One step from a runbook or manifest, checked and with defaults applied."""
    if not isinstance(raw, dict):
        raise RunError("%s: step %d is not an object" % (where, index + 1), EXIT_CONFIG)
    unknown = set(raw) - STEP_KEYS
    if unknown:
        raise RunError("%s: step %d has unknown keys %s" % (where, index + 1, sorted(unknown)), EXIT_CONFIG)

    name = raw.get("name") or "step-%d" % (index + 1)
    if not NAME_RE.match(name):
        raise RunError("%s: step name %r is invalid" % (where, name), EXIT_CONFIG)
    target = raw.get("target", "")
    if target not in cfg["targets"]:
        raise RunError("%s: step %s names unknown target %r" % (where, name, target), EXIT_CONFIG)
    script = raw.get("script", "")
    if not KEY_RE.match(script) or ".." in script:
        raise RunError("%s: step %s has an invalid script key %r" % (where, name, script), EXIT_CONFIG)
    sha = raw.get("sha256", "")
    if sha and not SHA_RE.match(sha):
        raise RunError("%s: step %s sha256 is not 64 lowercase hex characters" % (where, name), EXIT_CONFIG)
    stype = raw.get("type") or ("shell" if script.endswith(".sh") else "sql")
    if stype not in TYPES:
        raise RunError("%s: step %s type must be one of %s" % (where, name, TYPES), EXIT_CONFIG)
    if stype == "shell" and not cfg["allow_shell_steps"]:
        raise RunError("%s: step %s is a shell step and allow_shell_steps is off" % (where, name), EXIT_CONFIG)
    transaction = raw.get("transaction", "auto")
    if transaction not in TRANSACTIONS:
        raise RunError("%s: step %s transaction must be one of %s" % (where, name, TRANSACTIONS), EXIT_CONFIG)
    timeout = raw.get("timeout_seconds", cfg["default_timeout_seconds"])
    if not isinstance(timeout, int) or isinstance(timeout, bool) or not 1 <= timeout <= MAX_TIMEOUT:
        raise RunError("%s: step %s timeout_seconds must be an integer from 1 to %d" % (where, name, MAX_TIMEOUT), EXIT_CONFIG)
    on_error = raw.get("on_error", "stop")
    if on_error not in ON_ERROR:
        raise RunError("%s: step %s on_error must be one of %s" % (where, name, ON_ERROR), EXIT_CONFIG)
    variables = raw.get("variables", {}) or {}
    if not isinstance(variables, dict):
        raise RunError("%s: step %s variables must be an object" % (where, name), EXIT_CONFIG)
    for k, v in variables.items():
        check_variable(k, v, "%s step %s" % (where, name))

    return {
        "name": name,
        "target": target,
        "script": script,
        "sha256": sha,
        "type": stype,
        "transaction": transaction,
        "timeout_seconds": timeout,
        "on_error": on_error,
        "variables": variables,
    }


def normalize_steps(raw_steps, cfg, where):
    if not isinstance(raw_steps, list) or not raw_steps:
        raise RunError("%s: steps must be a non-empty list" % where, EXIT_CONFIG)
    if len(raw_steps) > MAX_STEPS:
        raise RunError("%s: more than %d steps" % (where, MAX_STEPS), EXIT_CONFIG)
    steps = [normalize_step(s, i, cfg, where) for i, s in enumerate(raw_steps)]
    names = [s["name"] for s in steps]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        raise RunError("%s: duplicate step names %s" % (where, dupes), EXIT_CONFIG)
    return steps


# ---------------------------------------------------------------------------
# AWS, through the CLI
# ---------------------------------------------------------------------------


def aws(args, what):
    try:
        p = subprocess.run(["aws"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except FileNotFoundError:
        raise RunError("aws is not installed on this AMI", EXIT_CONFIG)
    if p.returncode != 0:
        raise RunError("%s: %s" % (what, MASK.mask(p.stderr.decode(errors="replace").strip())), EXIT_CONFIG)
    return p.stdout.decode().strip()


def fetch_object(cfg, key, dest):
    """Downloads prefix+key; returns (version id, sha256)."""
    if not KEY_RE.match(key) or ".." in key:
        raise RunError("invalid object key %r" % key, EXIT_CONFIG)
    full = cfg["scripts_prefix"] + key
    version = aws(
        ["s3api", "get-object", "--bucket", cfg["scripts_bucket"], "--key", full, dest, "--query", "VersionId", "--output", "text"],
        "could not read s3://%s/%s" % (cfg["scripts_bucket"], full),
    )
    with open(dest, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    return full, version, sha


class Credentials:
    """Reads each target's secret once per run."""

    def __init__(self):
        self._cache = {}

    def get(self, target_name, target):
        if target_name not in self._cache:
            raw = aws(
                ["secretsmanager", "get-secret-value", "--secret-id", target["secret_arn"], "--query", "SecretString", "--output", "text"],
                "could not read the secret for %s" % target_name,
            )
            try:
                doc = json.loads(raw)
            except ValueError:
                raise RunError("the secret for %s is not JSON" % target_name, EXIT_CONFIG)
            user, password = doc.get("username"), doc.get("password")
            if not user or not password:
                raise RunError("the secret for %s needs \"username\" and \"password\"" % target_name, EXIT_CONFIG)
            MASK.add(str(password))
            self._cache[target_name] = (str(user), str(password))
        return self._cache[target_name]


# ---------------------------------------------------------------------------
# Running a client
# ---------------------------------------------------------------------------

_current = {"proc": None}


def _kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def _on_signal(signum, frame):
    proc = _current["proc"]
    if proc is not None and proc.poll() is None:
        _kill_group(proc)
    log("FAILED: interrupted by signal %d; the database rolls back the open transaction when the connection drops" % signum)
    sys.exit(EXIT_INTERRUPTED)


def need(binary):
    if shutil.which(binary) is None:
        raise RunError("%s is not installed on this AMI" % binary, EXIT_CONFIG)


def client_env(target, extra):
    """A minimal environment: the client gets nothing it was not given."""
    passthrough = (
        "PATH", "HOME", "LANG", "LC_ALL", "TZ", "ORACLE_HOME", "LD_LIBRARY_PATH", "TNS_ADMIN",
        # A shell step that calls the AWS CLI (to upload what it generated)
        # needs the region; the instance role supplies the credentials.
        "AWS_REGION", "AWS_DEFAULT_REGION",
    )
    env = {k: os.environ[k] for k in passthrough if k in os.environ}
    env.update(target.get("env", {}))
    env.update(extra)
    return env


def run_client(argv, env, timeout, cwd, stdin_data=None, stdin_path=None):
    """Runs argv in its own process group, streams masked output, returns rc."""
    stdin = subprocess.DEVNULL
    fh = None
    if stdin_path is not None:
        fh = open(stdin_path, "rb")
        stdin = fh
    elif stdin_data is not None:
        stdin = subprocess.PIPE
    try:
        proc = subprocess.Popen(
            argv, env=env, cwd=cwd, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
        )
    except FileNotFoundError:
        raise RunError("%s is not installed on this AMI" % argv[0], EXIT_CONFIG)
    _current["proc"] = proc

    def pump():
        for line in iter(proc.stdout.readline, b""):
            sys.stdout.write(MASK.mask(line.decode(errors="replace")))
            sys.stdout.flush()

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    try:
        if stdin_data is not None:
            try:
                proc.stdin.write(stdin_data.encode())
                proc.stdin.close()
            except BrokenPipeError:
                pass
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            reader.join(timeout=5)
            raise RunError("exceeded timeout_seconds=%d; the client was stopped" % timeout, EXIT_TIMEOUT)
        reader.join(timeout=5)
        return rc
    finally:
        _current["proc"] = None
        if fh is not None:
            fh.close()


_mysql_flavour = {}


def mysql_is_mariadb():
    if "mariadb" not in _mysql_flavour:
        # Captured, not piped into grep: under a pipeline an early-exiting
        # reader turns a successful --version into a failure.
        p = subprocess.run(["mysql", "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        _mysql_flavour["mariadb"] = "mariadb" in p.stdout.decode(errors="replace").lower()
    return _mysql_flavour["mariadb"]


def mysql_ssl_flags(target):
    mode, ca = target["ssl_mode"], target["ca_bundle_path"]
    if mysql_is_mariadb():
        return {
            "verify-full": ["--ssl", "--ssl-ca=" + ca, "--ssl-verify-server-cert"],
            "verify-ca": ["--ssl", "--ssl-ca=" + ca, "--ssl-verify-server-cert"],
            "require": ["--ssl"],
            "disable": ["--skip-ssl"],
        }[mode]
    return {
        "verify-full": ["--ssl-mode=VERIFY_IDENTITY", "--ssl-ca=" + ca],
        "verify-ca": ["--ssl-mode=VERIFY_CA", "--ssl-ca=" + ca],
        "require": ["--ssl-mode=REQUIRED"],
        "disable": ["--ssl-mode=DISABLED"],
    }[mode]


def write_mysql_option_file(path, user, password):
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')

    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write('[client]\nuser="%s"\npassword="%s"\n' % (esc(user), esc(password)))


def resolve_transaction(step, family):
    tx = step["transaction"]
    if tx == "auto":
        return "none" if family == "mysql" else "single"
    if tx == "single" and family == "mysql":
        raise RunError(
            "step %s: transaction=single is refused on a MySQL-family target: DDL commits implicitly and would not roll back" % step["name"],
            EXIT_CONFIG,
        )
    return tx


def execute(step, script_path, cfg, creds, work):
    """Runs one fetched step; returns the client's exit code."""
    tname = step["target"]
    target = cfg["targets"][tname]
    family = target["family"]
    if target["ca_bundle_path"] and not os.access(target["ca_bundle_path"], os.R_OK):
        raise RunError("CA bundle %s is not on this AMI" % target["ca_bundle_path"], EXIT_CONFIG)
    user, password = creds.get(tname, target)
    variables = dict(target.get("variables", {}))
    variables.update(step["variables"])
    timeout = step["timeout_seconds"]
    opts = list(target.get("client_options", []))

    if step["type"] == "shell":
        need("bash")
        extra = {
            "DMS_TARGET": tname,
            "DB_ENGINE": family,
            "DB_HOST": target["host"],
            "DB_PORT": str(target["port"]),
            "DB_NAME": target["database"],
            "DB_USER": user,
            "DB_PASSWORD": password,
            "DB_SSL_MODE": target["ssl_mode"],
            "DB_CA_BUNDLE": target["ca_bundle_path"],
            # Where scripts live, so a step can write one for a later step:
            # aws s3 cp out.sql "s3://$DMS_SCRIPTS_BUCKET/$DMS_SCRIPTS_PREFIX<key>"
            "DMS_SCRIPTS_BUCKET": cfg["scripts_bucket"],
            "DMS_SCRIPTS_PREFIX": cfg["scripts_prefix"],
        }
        if family == "postgres":
            extra.update({
                "PGHOST": target["host"], "PGPORT": str(target["port"]), "PGDATABASE": target["database"],
                "PGUSER": user, "PGPASSWORD": password, "PGSSLMODE": target["ssl_mode"],
            })
            if target["ca_bundle_path"]:
                extra["PGSSLROOTCERT"] = target["ca_bundle_path"]
        if family == "mysql":
            cnf = os.path.join(work, "client.cnf")
            write_mysql_option_file(cnf, user, password)
            extra["DB_MYSQL_DEFAULTS_FILE"] = cnf
        extra.update(variables)
        return run_client(["bash", script_path], client_env(target, extra), timeout, work)

    tx = resolve_transaction(step, family)

    if family == "postgres":
        need("psql")
        argv = [
            "psql", "--no-psqlrc", "--host", target["host"], "--port", str(target["port"]),
            "--username", user, "--dbname", target["database"],
            "--set", "ON_ERROR_STOP=1", "--set", "VERBOSITY=verbose", "--echo-errors",
        ]
        if tx == "single":
            argv.append("--single-transaction")
        for k in sorted(variables):
            argv += ["--set", "%s=%s" % (k, variables[k])]
        argv += opts + ["--file", script_path]
        extra = {"PGPASSWORD": password, "PGSSLMODE": target["ssl_mode"], "PGCONNECT_TIMEOUT": "15", "PGAPPNAME": "dms-sql-bastion"}
        if target["ca_bundle_path"]:
            extra["PGSSLROOTCERT"] = target["ca_bundle_path"]
        return run_client(argv, client_env(target, extra), timeout, work)

    if family == "mysql":
        need("mysql")
        cnf = os.path.join(work, "client.cnf")
        write_mysql_option_file(cnf, user, password)
        body = os.path.join(work, "mysql-input.sql")
        with open(body, "w") as out:
            for k in sorted(variables):
                out.write("SET @%s = '%s';\n" % (k, variables[k]))
            with open(script_path) as src:
                out.write(src.read())
        argv = ["mysql", "--defaults-extra-file=" + cnf, "--host=" + target["host"], "--port=%d" % target["port"],
                "--database=" + target["database"], "--batch", "--show-warnings", "--line-numbers", "--connect-timeout=15"]
        argv += mysql_ssl_flags(target) + opts
        return run_client(argv, client_env(target, {}), timeout, work, stdin_path=body)

    if family == "oracle":
        need("sqlplus")
        if '"' in password:
            raise RunError("an Oracle password containing a double quote cannot be passed to CONNECT", EXIT_CONFIG)
        lines = [
            "WHENEVER OSERROR EXIT FAILURE ROLLBACK",
            "WHENEVER SQLERROR EXIT FAILURE ROLLBACK",
            "SET ECHO OFF",
            "SET SQLBLANKLINES ON",
            "SET FEEDBACK ON",
        ]
        if variables:
            lines.append("SET DEFINE ON")
            lines += ['DEFINE %s = "%s"' % (k, variables[k]) for k in sorted(variables)]
        else:
            lines.append("SET DEFINE OFF")
        lines.append('CONNECT %s/"%s"@//%s:%d/%s' % (user, password, target["host"], target["port"], target["database"]))
        # SQL*Plus does not autocommit by default: single holds everything to
        # the final COMMIT, and an error rolls back to the last COMMIT in the
        # script. none commits statement by statement.
        lines.append("SET AUTOCOMMIT ON" if tx == "none" else "SET AUTOCOMMIT OFF")
        lines += ['@"%s"' % script_path, "COMMIT;", "EXIT SUCCESS", ""]
        argv = ["sqlplus", "-S", "-L"] + opts + ["/nolog"]
        return run_client(argv, client_env(target, {}), timeout, work, stdin_data="\n".join(lines))

    raise RunError("unknown engine family %r" % family, EXIT_CONFIG)


# ---------------------------------------------------------------------------
# Building the step list
# ---------------------------------------------------------------------------


def check_step(target_name, cfg):
    return {
        "name": "check-%s" % target_name, "target": target_name, "script": "", "sha256": "", "type": "check",
        "transaction": "none", "timeout_seconds": 120, "on_error": "continue", "variables": {},
    }


def build_steps(params, cfg, work):
    mode = params["mode"]
    if mode == "check":
        names = [params["target"]] if params["target"] else sorted(cfg["targets"])
        for n in names:
            if n not in cfg["targets"]:
                raise RunError("unknown target %r" % n, EXIT_CONFIG)
        return "check", [check_step(n, cfg) for n in names]

    if mode == "run":
        if not params["target"]:
            raise RunError("Target is required when Mode=run", EXIT_CONFIG)
        if not params["script_key"]:
            raise RunError("ScriptKey is required when Mode=run", EXIT_CONFIG)
        raw = {
            "name": "run",
            "target": params["target"],
            "script": params["script_key"],
            "sha256": params["expected_sha256"],
            "transaction": params["transaction"],
            "variables": parse_variables(params["variables"], "Variables"),
        }
        # StepTimeoutSeconds=0 means "the default", which main() has already
        # folded into default_timeout_seconds when it is set.
        return "run", normalize_steps([raw], cfg, "Mode=run")

    if mode == "runbook":
        name = params["runbook"]
        if name not in cfg["runbooks"]:
            raise RunError("unknown runbook %r; configured: %s" % (name, sorted(cfg["runbooks"])), EXIT_CONFIG)
        return "runbook %s" % name, normalize_steps(cfg["runbooks"][name]["steps"], cfg, "runbook %s" % name)

    if mode == "manifest":
        if not cfg["allow_s3_manifests"]:
            raise RunError("manifests from S3 are disabled (allow_s3_manifests = false); use a runbook", EXIT_CONFIG)
        key = params["manifest_key"]
        if not key:
            raise RunError("ManifestKey is required when Mode=manifest", EXIT_CONFIG)
        path = os.path.join(work, "manifest.json")
        full, version, sha = fetch_object(cfg, key, path)
        log("manifest=s3://%s/%s version=%s sha256=%s" % (cfg["scripts_bucket"], full, version, sha))
        if params["expected_sha256"] and params["expected_sha256"] != sha:
            raise RunError("manifest SHA-256 mismatch: expected %s - not the reviewed manifest" % params["expected_sha256"], EXIT_INTEGRITY)
        try:
            with open(path) as f:
                doc = json.load(f)
        except ValueError as e:
            raise RunError("manifest is not valid JSON: %s" % e, EXIT_CONFIG)
        if not isinstance(doc, dict):
            raise RunError("manifest must be a JSON object", EXIT_CONFIG)
        unknown = set(doc) - MANIFEST_KEYS
        if unknown:
            raise RunError("manifest has unknown keys %s" % sorted(unknown), EXIT_CONFIG)
        return "manifest %s" % key, normalize_steps(doc.get("steps"), cfg, "manifest")

    raise RunError("unknown Mode %r" % mode, EXIT_CONFIG)


def apply_start_at(steps, start_at):
    if not start_at:
        return steps
    for i, s in enumerate(steps):
        if s["name"] == start_at:
            if i:
                log("StartAt=%s: skipping %s" % (start_at, ", ".join(x["name"] for x in steps[:i])))
            return steps[i:]
    raise RunError("StartAt=%s matches no step; steps are %s" % (start_at, [s["name"] for s in steps]), EXIT_CONFIG)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def read_params():
    def env(name, default=""):
        return os.environ.get("DMS_" + name, default)

    try:
        timeout = int(env("TIMEOUT_SECONDS", "0") or "0")
    except ValueError:
        raise RunError("TimeoutSeconds is not an integer", EXIT_CONFIG)
    return {
        "mode": env("MODE", "run"),
        "target": env("TARGET"),
        "script_key": env("SCRIPT_KEY"),
        "expected_sha256": env("EXPECTED_SHA256"),
        "transaction": env("TRANSACTION", "auto"),
        "variables": env("VARIABLES"),
        "runbook": env("RUNBOOK"),
        "manifest_key": env("MANIFEST_KEY"),
        "start_at": env("START_AT"),
        "dry_run": env("DRY_RUN", "false") == "true",
        "timeout_seconds": timeout,
    }


def describe(step):
    if step["type"] == "check":
        return "%s: check %s" % (step["name"], step["target"])
    return "%s: %s %s on %s (transaction=%s, timeout=%ds, on_error=%s%s)" % (
        step["name"], step["type"], step["script"], step["target"], step["transaction"], step["timeout_seconds"],
        step["on_error"], ", variables=" + ",".join(sorted(step["variables"])) if step["variables"] else "",
    )


def main():
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    with open(os.environ["DMS_CONFIG"]) as f:
        cfg = json.load(f)
    params = read_params()
    if params["timeout_seconds"] > 0:
        # The document-level timeout bounds a single run step too.
        cfg = dict(cfg, default_timeout_seconds=params["timeout_seconds"])

    work = tempfile.mkdtemp(prefix="dms-sql.", dir="/tmp")
    try:
        return run(params, cfg, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(params, cfg, work):
    what, steps = build_steps(params, cfg, work)
    steps = apply_start_at(steps, params["start_at"])
    if params["dry_run"] and what != "check":
        # Verify every script, then prove every target the steps touch is
        # reachable with its credential. Nothing is executed.
        seen = []
        for st in steps:
            if st["target"] not in seen:
                seen.append(st["target"])
        steps = steps + [check_step(t, cfg) for t in seen]
    log("%s%s: %d step(s)" % (what, " (dry run)" if params["dry_run"] else "", len(steps)))
    for s in steps:
        log("  " + describe(s))

    creds = Credentials()
    results = []
    first_failure = EXIT_OK
    for idx, step in enumerate(steps):
        started = time.time()
        log("--- %s" % describe(step))
        status, code, detail = "ok", EXIT_OK, ""
        try:
            script_path = os.path.join(work, "step-%03d" % idx)
            if step["type"] == "check":
                target = cfg["targets"][step["target"]]
                with open(script_path, "w") as f:
                    f.write(PROBES[target["family"]])
                probe = dict(step, type="sql")
                rc = execute(probe, script_path, cfg, creds, work)
            else:
                full, version, sha = fetch_object(cfg, step["script"], script_path)
                detail = "version=%s sha256=%s" % (version, sha)
                log("script=s3://%s/%s %s" % (cfg["scripts_bucket"], full, detail))
                if step["sha256"] and step["sha256"] != sha:
                    raise RunError("SHA-256 mismatch: expected %s - not the reviewed script" % step["sha256"], EXIT_INTEGRITY)
                if params["dry_run"]:
                    status = "verified"
                    rc = 0
                else:
                    rc = execute(step, script_path, cfg, creds, work)
            if rc != 0:
                raise RunError("%s exited %d" % ("the script" if step["type"] == "shell" else "the client", rc), EXIT_SCRIPT)
        except RunError as e:
            status, code = "FAILED", e.code
            log("FAILED %s: %s" % (step["name"], e))
        results.append((step, status, time.time() - started, detail))

        if code != EXIT_OK:
            if first_failure == EXIT_OK:
                first_failure = code
            if step["on_error"] == "stop":
                remaining = [s["name"] for s in steps[idx + 1:]]
                if remaining:
                    log("stopped; not run: %s" % ", ".join(remaining))
                if what.startswith(("runbook", "manifest")):
                    log("to resume after fixing the cause: rerun with StartAt=%s" % step["name"])
                break
            log("on_error=continue: carrying on")

    log("=== summary")
    for step, status, seconds, detail in results:
        log("  %-8s %-24s %-12s %6.1fs %s" % (status, step["name"], step["target"], seconds, detail))
    if first_failure == EXIT_OK:
        log("OK: %s" % what)
    else:
        log("FAILED: %s (exit %d)" % (what, first_failure))
    return first_failure


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RunError as e:
        log("FAILED: %s" % e)
        sys.exit(e.code)
    except SystemExit:
        raise
    except Exception as e:  # the runner itself, not a step
        log("FAILED: unexpected %s: %s" % (type(e).__name__, e))
        sys.exit(EXIT_UNEXPECTED)
