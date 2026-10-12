#!/usr/bin/env python3
"""Tests for scripts/runner.py and scripts/launcher.sh.tftpl.

The runner runs for real against a fake AWS CLI (S3 objects from a directory,
a secret from a file) and stub psql / mysql / sqlplus / bash-step clients that
record their argv, environment, stdin and any option file. What this proves:
step building and ordering, StartAt, DryRun, on_error, manifests, exit codes,
SHA-256 refusal, timeouts and SIGTERM, per-engine argv and transactions,
variables, and that the password never reaches argv or output. What it does
not: client behaviour against a live server.

    python3 tests/runner/test_runner.py            # all
    python3 tests/runner/test_runner.py -k oracle  # some

The launcher test needs terraform (and uses shellcheck when installed).
"""

import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.abspath(os.path.join(HERE, "..", ".."))
RUNNER = os.path.join(MODULE, "scripts", "runner.py")

PASSWORD = 'p@ss"w\\0rd$X'
ORACLE_PASSWORD = "Ora$Pass1#x"

FAKE_AWS = r"""#!/bin/bash
# Fake AWS CLI: S3 objects from $ROOT/s3, the secret from $ROOT/secret.json.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "$1 $2" in
  "s3api get-object")
    shift 2; key=""; out=""
    while [ $# -gt 0 ]; do
      case "$1" in --bucket|--query|--output) shift ;; --key) key="$2"; shift ;; *) out="$1" ;; esac
      shift
    done
    [ -f "$ROOT/s3/$key" ] || { echo "An error occurred (NoSuchKey): $key" >&2; exit 254; }
    cp "$ROOT/s3/$key" "$out"; echo "v-123" ;;
  "secretsmanager get-secret-value") cat "$ROOT/secret.json" ;;
  "s3 cp")
    src="$3"; dst="$4"; key="${dst#s3://*/}"
    mkdir -p "$(dirname "$ROOT/s3/$key")"; cp "$src" "$ROOT/s3/$key" ;;
  *) echo "unexpected: aws $*" >&2; exit 99 ;;
esac
"""

# Clients get a minimal environment from the runner, so a stub finds its
# record directory from its own path, and its behaviour from files there.
STUB = r"""#!/bin/bash
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REC="$ROOT/rec"
n=$(basename "$0")
if [ "${1:-}" = "--version" ]; then cat "$REC/$n.version" 2>/dev/null || echo "mysql  Ver 15.1 Distrib 10.5.22-MariaDB"; exit 0; fi
i=$(ls "$REC" | grep -c '\.argv$')
base="$REC/$(printf '%02d' "$i")-$n"
printf '%s\n' "$@" >"$base.argv"
env >"$base.env"
cat >"$base.stdin"
prev=""
for a in "$@"; do
  case "$a" in --defaults-extra-file=*) cp "${a#*=}" "$base.cnf" ;; esac
  if [ "$prev" = "--file" ]; then cp "$a" "$base.sql"; fi
  prev="$a"
done
if [ "$n" = bash ]; then
  cp "$1" "$base.sh"
  if [ -f "$REC/really-run-shell" ]; then exec "$ROOT/sys/realbash" "$@"; fi
fi
[ -f "$REC/print" ] && cat "$REC/print"
[ -f "$REC/sleep" ] && sleep "$(cat "$REC/sleep")"
if [ -f "$REC/fail-on" ] && cat "$base.sql" "$base.stdin" "$base.sh" 2>/dev/null | grep -qF -e "$(cat "$REC/fail-on")"; then exit 3; fi
exit "$(cat "$REC/exit" 2>/dev/null || echo 0)"
"""

SYSTEM_TOOLS = ["cat", "cp", "env", "printf", "basename", "dirname", "ls", "grep", "sleep", "mkdir", "mktemp", "rm", "wc", "sha256sum", "cut"]

# pg_dump stand-in: writes a recognisable schema to --file.
FAKE_PG_DUMP = r"""#!/bin/bash
out=""; section=""
for a in "$@"; do case "$a" in --file=*) out="${a#*=}" ;; --section=*) section="${a#*=}" ;; esac; done
printf -- '-- %s for %s as %s\nCREATE TABLE app.t (id int);\n' "$section" "$PGDATABASE" "$PGUSER" >"$out"
"""


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


class Env:
    """One sandbox: fake AWS, stubs, a scripts bucket, a record directory."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="sqlb-test.")
        for d in ("bin", "stubs", "sys", "s3/migrations", "rec"):
            os.makedirs(os.path.join(self.root, d))
        self._write("bin/aws", FAKE_AWS, executable=True)
        for c in ("psql", "mysql", "sqlplus", "bash"):
            self._write("stubs/" + c, STUB, executable=True)
        self._write("sys/pg_dump", FAKE_PG_DUMP.replace("#!/bin/bash", "#!" + shutil.which("bash"), 1), executable=True)
        for t in SYSTEM_TOOLS:
            os.symlink(shutil.which(t), os.path.join(self.root, "sys", t))
        # The stubs themselves run under the real bash.
        os.symlink(shutil.which("bash"), os.path.join(self.root, "sys", "realbash"))
        for c in ("psql", "mysql", "sqlplus", "bash"):
            p = os.path.join(self.root, "stubs", c)
            with open(p) as f:
                body = f.read().replace("#!/bin/bash", "#!" + shutil.which("bash"), 1)
            with open(p, "w") as f:
                f.write(body)
        self.secret("migrator", PASSWORD)

    def _write(self, rel, text, executable=False):
        p = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        if executable:
            os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
        return p

    def put(self, key, text):
        self._write("s3/migrations/" + key, text)
        return sha(text)

    def secret(self, user, password):
        doc = {"host": "ignored"}
        if user is not None:
            doc["username"] = user
        if password is not None:
            doc["password"] = password
        self._write("secret.json", json.dumps(doc))

    def behave(self, **kw):
        for k, v in kw.items():
            self._write("rec/" + k.replace("_", "-"), str(v))

    def remove_client(self, name):
        os.remove(os.path.join(self.root, "stubs", name))

    def calls(self):
        rec = os.path.join(self.root, "rec")
        out = []
        for f in sorted(os.listdir(rec)):
            if f.endswith(".argv"):
                base = os.path.join(rec, f[:-5])
                call = {"client": f[3:-5]}
                for ext in ("argv", "env", "stdin", "cnf", "sql", "sh"):
                    if os.path.exists(base + "." + ext):
                        with open(base + "." + ext) as fh:
                            call[ext] = fh.read()
                call["argv"] = call["argv"].splitlines()
                out.append(call)
        return out

    def config(self, **over):
        cfg = {
            "scripts_bucket": "mig-scripts",
            "scripts_prefix": "migrations/",
            "default_timeout_seconds": 60,
            "allow_shell_steps": False,
            "allow_s3_manifests": True,
            "targets": {
                "aurora": {"family": "postgres", "host": "127.0.0.1", "port": 5432, "database": "core",
                           "secret_arn": "arn:aws:secretsmanager:eu-west-1:111122223333:secret:a-AbC",
                           "ssl_mode": "disable", "ca_bundle_path": "", "client_options": [], "env": {}, "variables": {}},
                "shop": {"family": "mysql", "host": "127.0.0.1", "port": 3306, "database": "shop",
                         "secret_arn": "arn:aws:secretsmanager:eu-west-1:111122223333:secret:m-AbC",
                         "ssl_mode": "disable", "ca_bundle_path": "", "client_options": [], "env": {}, "variables": {}},
                "legacy": {"family": "oracle", "host": "10.0.0.5", "port": 1521, "database": "CORE.example",
                           "secret_arn": "arn:aws:secretsmanager:eu-west-1:111122223333:secret:o-AbC",
                           "ssl_mode": "none", "ca_bundle_path": "", "client_options": [], "env": {}, "variables": {}},
                "tls": {"family": "postgres", "host": "db.example", "port": 5432, "database": "core",
                        "secret_arn": "arn:aws:secretsmanager:eu-west-1:111122223333:secret:t-AbC",
                        "ssl_mode": "verify-full", "ca_bundle_path": "/nonexistent/ca.pem", "client_options": [], "env": {}, "variables": {}},
            },
            "runbooks": {},
        }
        cfg.update(over)
        return self._write("config.json", json.dumps(cfg))

    def path(self):
        return ":".join(os.path.join(self.root, d) for d in ("bin", "stubs", "sys"))

    def run(self, cfg_path=None, wait=True, **params):
        cfg_path = cfg_path or self.config()
        env = {"PATH": self.path(), "HOME": self.root, "DMS_CONFIG": cfg_path, "AWS_REGION": "eu-west-1"}
        for k, v in params.items():
            env["DMS_" + k.upper()] = v
        proc = subprocess.Popen([sys.executable, RUNNER], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if not wait:
            return proc
        out, _ = proc.communicate(timeout=120)
        return proc.returncode, out.decode()

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.addCleanup(self.e.close)

    def assertNoPassword(self, text, password=PASSWORD):
        self.assertNotIn(password, text)

    def run_ok(self, **params):
        rc, out = self.e.run(**params)
        self.assertEqual(rc, 0, out)
        self.assertNoPassword(out)
        return out

    def run_fails(self, code, **params):
        rc, out = self.e.run(**params)
        self.assertEqual(rc, code, out)
        self.assertNoPassword(out)
        return out


class PostgresTest(RunnerTest):
    def test_run_passes_the_password_in_the_environment_only(self):
        digest = self.e.put("w1/01.sql", "CREATE TABLE t (id int);\n")
        self.run_ok(mode="run", target="aurora", script_key="w1/01.sql", expected_sha256=digest)
        [call] = self.e.calls()
        self.assertEqual(call["client"], "psql")
        self.assertNotIn(PASSWORD, "\n".join(call["argv"]))
        self.assertIn("PGPASSWORD=" + PASSWORD, call["env"].splitlines())
        self.assertIn("--single-transaction", call["argv"])
        self.assertIn("ON_ERROR_STOP=1", call["argv"])
        self.assertIn("CREATE TABLE t", call["sql"])

    def test_transaction_none_is_not_one_transaction(self):
        self.e.put("w1/01.sql", "SELECT 1;\n")
        self.run_ok(mode="run", target="aurora", script_key="w1/01.sql", transaction="none")
        self.assertNotIn("--single-transaction", self.e.calls()[0]["argv"])

    def test_variables_become_psql_set(self):
        self.e.put("w1/01.sql", "CREATE SCHEMA :\"schema\";\n")
        self.run_ok(mode="run", target="aurora", script_key="w1/01.sql", variables="schema=core;owner=app_owner")
        argv = self.e.calls()[0]["argv"]
        self.assertIn("schema=core", argv)
        self.assertIn("owner=app_owner", argv)

    def test_target_options_env_and_default_variables_reach_the_client(self):
        self.e.put("w1/01.sql", "SELECT 1;\n")
        cfg = json.load(open(self.e.config()))
        cfg["targets"]["aurora"].update(client_options=["--quiet"], env={"PGOPTIONS": "-c lock_timeout=30s"}, variables={"schema": "core"})
        path = self.e._write("config.json", json.dumps(cfg))
        rc, out = self.e.run(cfg_path=path, mode="run", target="aurora", script_key="w1/01.sql", variables="schema=override")
        self.assertEqual(rc, 0, out)
        call = self.e.calls()[0]
        self.assertIn("--quiet", call["argv"])
        self.assertIn("PGOPTIONS=-c lock_timeout=30s", call["env"].splitlines())
        self.assertIn("schema=override", call["argv"])
        self.assertNotIn("schema=core", call["argv"])

    def test_client_gets_a_minimal_environment(self):
        self.e.put("w1/01.sql", "SELECT 1;\n")
        self.run_ok(mode="run", target="aurora", script_key="w1/01.sql")
        names = {l.split("=", 1)[0] for l in self.e.calls()[0]["env"].splitlines()}
        self.assertNotIn("DMS_CONFIG", names)
        self.assertNotIn("DMS_SCRIPT_KEY", names)

    def test_client_output_is_masked(self):
        self.e.put("w1/01.sql", "SELECT 1;\n")
        self.e.behave(print="the password is %s\n" % PASSWORD)
        out = self.run_ok(mode="run", target="aurora", script_key="w1/01.sql")
        self.assertIn("the password is ****", out)

    def test_check_runs_a_probe(self):
        self.run_ok(mode="check", target="aurora")
        self.assertIn("SELECT current_user", self.e.calls()[0]["sql"])

    def test_sha_mismatch_is_refused(self):
        self.e.put("w1/01.sql", "SELECT 1;\n")
        self.run_fails(3, mode="run", target="aurora", script_key="w1/01.sql", expected_sha256="a" * 64)
        self.assertEqual(self.e.calls(), [])

    def test_missing_object(self):
        self.run_fails(4, mode="run", target="aurora", script_key="w1/nope.sql")

    def test_dotdot_is_refused(self):
        self.run_fails(4, mode="run", target="aurora", script_key="w1/../x.sql")

    def test_run_needs_a_key_and_a_target(self):
        self.run_fails(4, mode="run", target="aurora")
        self.run_fails(4, mode="run", script_key="w1/01.sql")

    def test_client_error(self):
        self.e.put("w1/01.sql", "SELECT 1;\n")
        self.e.behave(exit=3)
        self.run_fails(2, mode="run", target="aurora", script_key="w1/01.sql")

    def test_missing_client(self):
        self.e.remove_client("psql")
        out = self.run_fails(4, mode="check", target="aurora")
        self.assertIn("psql is not installed", out)

    def test_missing_ca_bundle(self):
        out = self.run_fails(4, mode="check", target="tls")
        self.assertIn("CA bundle", out)

    def test_secret_without_password(self):
        self.e.secret("u", None)
        self.run_fails(4, mode="check", target="aurora")

    def test_unknown_target(self):
        self.run_fails(4, mode="check", target="nope")

    def test_bad_variable_is_refused(self):
        self.e.put("w1/01.sql", "SELECT 1;\n")
        self.run_fails(4, mode="run", target="aurora", script_key="w1/01.sql", variables="x=a'b")


class MysqlTest(RunnerTest):
    def test_mariadb_client(self):
        digest = self.e.put("w1/01.sql", "CREATE TABLE t (id int);\n")
        self.run_ok(mode="run", target="shop", script_key="w1/01.sql", expected_sha256=digest, variables="tenant=acme")
        call = self.e.calls()[0]
        self.assertNotIn(PASSWORD, "\n".join(call["argv"]))
        self.assertTrue(call["argv"][0].startswith("--defaults-extra-file="))
        self.assertIn("--skip-ssl", call["argv"])
        self.assertIn("SET @tenant = 'acme';", call["stdin"])
        self.assertIn("CREATE TABLE t", call["stdin"])
        line = [l for l in call["cnf"].splitlines() if l.startswith("password=")][0]
        raw = line[len("password="):][1:-1].replace('\\"', '"').replace("\\\\", "\\")
        self.assertEqual(raw, PASSWORD)

    def test_mysql_client(self):
        self.e.behave(**{"mysql.version": "mysql  Ver 8.0.36 for Linux on x86_64"})
        self.run_ok(mode="check", target="shop")
        self.assertIn("--ssl-mode=DISABLED", self.e.calls()[0]["argv"])

    def test_single_transaction_is_refused(self):
        self.e.put("w1/01.sql", "SELECT 1;\n")
        self.run_fails(4, mode="run", target="shop", script_key="w1/01.sql", transaction="single")


class OracleTest(RunnerTest):
    def setUp(self):
        super().setUp()
        self.e.secret("MIGRATOR", ORACLE_PASSWORD)

    def test_connects_on_stdin(self):
        digest = self.e.put("w1/01.sql", "CREATE TABLE t (id NUMBER);\n")
        rc, out = self.e.run(mode="run", target="legacy", script_key="w1/01.sql", expected_sha256=digest)
        self.assertEqual(rc, 0, out)
        self.assertNoPassword(out, ORACLE_PASSWORD)
        call = self.e.calls()[0]
        self.assertNotIn(ORACLE_PASSWORD, "\n".join(call["argv"]))
        stdin = call["stdin"].splitlines()
        self.assertIn('CONNECT MIGRATOR/"%s"@//10.0.0.5:1521/CORE.example' % ORACLE_PASSWORD, stdin)
        self.assertIn("WHENEVER SQLERROR EXIT FAILURE ROLLBACK", stdin)
        self.assertIn("SET DEFINE OFF", stdin)
        self.assertIn("SET AUTOCOMMIT OFF", stdin)
        self.assertEqual(stdin[-2:], ["COMMIT;", "EXIT SUCCESS"])

    def test_variables_become_defines(self):
        self.e.put("w1/01.sql", "SELECT '&schema' FROM dual;\n")
        rc, out = self.e.run(mode="run", target="legacy", script_key="w1/01.sql", variables="schema=CORE")
        self.assertEqual(rc, 0, out)
        stdin = self.e.calls()[0]["stdin"].splitlines()
        self.assertIn("SET DEFINE ON", stdin)
        self.assertIn('DEFINE schema = "CORE"', stdin)

    def test_transaction_none_autocommits(self):
        self.e.put("w1/01.sql", "SELECT 1 FROM dual;\n")
        rc, out = self.e.run(mode="run", target="legacy", script_key="w1/01.sql", transaction="none")
        self.assertEqual(rc, 0, out)
        self.assertIn("SET AUTOCOMMIT ON", self.e.calls()[0]["stdin"].splitlines())

    def test_quote_in_password_is_refused(self):
        self.e.secret("MIGRATOR", 'bad"pass')
        rc, out = self.e.run(mode="check", target="legacy")
        self.assertEqual(rc, 4, out)
        self.assertIn("double quote", out)


class RunbookTest(RunnerTest):
    def cfg(self, steps, **over):
        return self.e.config(runbooks={"pre": {"description": "", "steps": steps}}, **over)

    def three(self):
        for n in ("a", "b", "c"):
            self.e.put("w1/%s.sql" % n, "-- step %s\nSELECT 1;\n" % n)
        return [{"name": n, "target": "aurora", "script": "w1/%s.sql" % n} for n in ("a", "b", "c")]

    def test_steps_run_in_order(self):
        rc, out = self.e.run(cfg_path=self.cfg(self.three()), mode="runbook", runbook="pre")
        self.assertEqual(rc, 0, out)
        self.assertEqual([c["sql"].splitlines()[0] for c in self.e.calls()], ["-- step a", "-- step b", "-- step c"])

    def test_a_failing_step_stops_the_run_and_says_how_to_resume(self):
        self.e.behave(fail_on="-- step b")
        rc, out = self.e.run(cfg_path=self.cfg(self.three()), mode="runbook", runbook="pre")
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(self.e.calls()), 2)
        self.assertIn("not run: c", out)
        self.assertIn("StartAt=b", out)

    def test_on_error_continue_runs_the_rest_and_still_fails(self):
        steps = self.three()
        steps[1]["on_error"] = "continue"
        self.e.behave(fail_on="-- step b")
        rc, out = self.e.run(cfg_path=self.cfg(steps), mode="runbook", runbook="pre")
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(self.e.calls()), 3)

    def test_start_at_skips_earlier_steps(self):
        rc, out = self.e.run(cfg_path=self.cfg(self.three()), mode="runbook", runbook="pre", start_at="b")
        self.assertEqual(rc, 0, out)
        self.assertEqual([c["sql"].splitlines()[0] for c in self.e.calls()], ["-- step b", "-- step c"])

    def test_unknown_start_at(self):
        rc, out = self.e.run(cfg_path=self.cfg(self.three()), mode="runbook", runbook="pre", start_at="zz")
        self.assertEqual(rc, 4, out)

    def test_dry_run_verifies_and_connects_but_executes_nothing(self):
        steps = self.three()
        rc, out = self.e.run(cfg_path=self.cfg(steps), mode="runbook", runbook="pre", dry_run="true")
        self.assertEqual(rc, 0, out)
        calls = self.e.calls()
        self.assertEqual(len(calls), 1, "only the connectivity probe")
        self.assertIn("SELECT current_user", calls[0]["sql"])

    def test_dry_run_catches_a_changed_script(self):
        steps = self.three()
        steps[2]["sha256"] = "b" * 64
        rc, out = self.e.run(cfg_path=self.cfg(steps), mode="runbook", runbook="pre", dry_run="true")
        self.assertEqual(rc, 3, out)

    def test_per_step_timeout(self):
        steps = self.three()[:1]
        steps[0]["timeout_seconds"] = 1
        self.e.behave(sleep=30)
        started = time.time()
        rc, out = self.e.run(cfg_path=self.cfg(steps), mode="runbook", runbook="pre")
        self.assertEqual(rc, 6, out)
        self.assertLess(time.time() - started, 25)

    def test_sigterm_stops_the_client_and_exits_5(self):
        self.e.behave(sleep=60)
        proc = self.e.run(cfg_path=self.cfg(self.three()[:1]), wait=False, mode="runbook", runbook="pre")
        for _ in range(100):
            if self.e.calls():
                break
            time.sleep(0.1)
        proc.send_signal(signal.SIGTERM)
        out, _ = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 5, out.decode())
        leftover = subprocess.run(["pgrep", "-f", os.path.join(self.e.root, "stubs")], stdout=subprocess.PIPE)
        self.assertEqual(leftover.stdout.strip(), b"", "the client process group must be gone")

    def test_steps_can_mix_targets(self):
        self.e.put("w1/pg.sql", "SELECT 1;\n")
        self.e.put("w1/ora.sql", "SELECT 1 FROM dual;\n")
        self.e.secret("MIGRATOR", ORACLE_PASSWORD)
        steps = [{"target": "aurora", "script": "w1/pg.sql"}, {"target": "legacy", "script": "w1/ora.sql"}]
        rc, out = self.e.run(cfg_path=self.cfg(steps), mode="runbook", runbook="pre")
        self.assertEqual(rc, 0, out)
        self.assertEqual([c["client"] for c in self.e.calls()], ["psql", "sqlplus"])

    def test_unknown_runbook(self):
        rc, out = self.e.run(cfg_path=self.cfg(self.three()), mode="runbook", runbook="nope")
        self.assertEqual(rc, 4, out)

    def test_shell_step_refused_unless_enabled(self):
        self.e.put("tools/dump.sh", "echo hi\n")
        rc, out = self.e.run(cfg_path=self.cfg([{"target": "aurora", "script": "tools/dump.sh"}]), mode="runbook", runbook="pre")
        self.assertEqual(rc, 4, out)
        self.assertIn("allow_shell_steps", out)

    def test_shell_step_gets_the_connection_in_its_environment(self):
        self.e.put("tools/dump.sh", "pg_dump --schema-only\n")
        steps = [{"target": "aurora", "script": "tools/dump.sh", "variables": {"SCHEMA": "core"}}]
        rc, out = self.e.run(cfg_path=self.cfg(steps, allow_shell_steps=True), mode="runbook", runbook="pre")
        self.assertEqual(rc, 0, out)
        self.assertNoPassword(out)
        call = self.e.calls()[0]
        self.assertEqual(call["client"], "bash")
        self.assertNotIn(PASSWORD, "\n".join(call["argv"]))
        env = call["env"].splitlines()
        for want in ("DB_HOST=127.0.0.1", "DB_PORT=5432", "DB_NAME=core", "DB_USER=migrator", "PGHOST=127.0.0.1",
                     "DB_PASSWORD=" + PASSWORD, "PGPASSWORD=" + PASSWORD, "SCHEMA=core", "DMS_TARGET=aurora",
                     "DMS_SCRIPTS_BUCKET=mig-scripts", "DMS_SCRIPTS_PREFIX=migrations/", "AWS_REGION=eu-west-1"):
            self.assertIn(want, env)
        self.assertIn("pg_dump", call["sh"])


class GeneratedScriptTest(RunnerTest):
    """A shell step writes a script to S3; the next step runs exactly that."""

    def test_the_postgres_example_dump_feeds_the_next_step(self):
        example = os.path.join(MODULE, "examples", "postgres-to-aurora", "tools", "dump-schema.sh")
        with open(example) as f:
            self.e.put("tools/dump-schema.sh", f.read())
        self.e.behave(really_run_shell=1)
        steps = [
            {"name": "dump", "target": "aurora", "script": "tools/dump-schema.sh",
             "variables": {"section": "pre-data", "schemas": "app", "out_key": "generated/pre-data.sql"}},
            {"name": "apply", "target": "aurora", "script": "generated/pre-data.sql"},
        ]
        cfg = self.e.config(runbooks={"pre": {"description": "", "steps": steps}}, allow_shell_steps=True)
        rc, out = self.e.run(cfg_path=cfg, mode="runbook", runbook="pre")
        self.assertEqual(rc, 0, out)
        self.assertNoPassword(out)
        self.assertIn("uploaded s3://mig-scripts/migrations/generated/pre-data.sql", out)
        apply = [c for c in self.e.calls() if c["client"] == "psql"][-1]
        self.assertIn("-- pre-data for core as migrator", apply["sql"])
        self.assertIn("CREATE TABLE app.t", apply["sql"])


class ManifestTest(RunnerTest):
    def manifest(self, doc):
        text = json.dumps(doc)
        return self.e.put("w1/manifest.json", text)

    def test_manifest_runs_its_steps(self):
        self.e.put("w1/a.sql", "-- a\n")
        self.e.put("w1/b.sql", "-- b\n")
        digest = self.manifest({"description": "w1", "steps": [
            {"name": "a", "target": "aurora", "script": "w1/a.sql"},
            {"name": "b", "target": "aurora", "script": "w1/b.sql", "transaction": "none"},
        ]})
        out = self.run_ok(mode="manifest", manifest_key="w1/manifest.json", expected_sha256=digest)
        self.assertIn("manifest=s3://mig-scripts/migrations/w1/manifest.json", out)
        calls = self.e.calls()
        self.assertEqual(len(calls), 2)
        self.assertNotIn("--single-transaction", calls[1]["argv"])

    def test_manifest_sha_mismatch(self):
        self.manifest({"steps": [{"target": "aurora", "script": "w1/a.sql"}]})
        self.run_fails(3, mode="manifest", manifest_key="w1/manifest.json", expected_sha256="c" * 64)

    def test_unknown_keys_are_refused(self):
        self.manifest({"steps": [{"target": "aurora", "script": "w1/a.sql", "trasnaction": "none"}]})
        out = self.run_fails(4, mode="manifest", manifest_key="w1/manifest.json")
        self.assertIn("trasnaction", out)

    def test_duplicate_names_are_refused(self):
        self.manifest({"steps": [{"name": "x", "target": "aurora", "script": "a.sql"}, {"name": "x", "target": "aurora", "script": "b.sql"}]})
        self.run_fails(4, mode="manifest", manifest_key="w1/manifest.json")

    def test_invalid_json(self):
        self.e.put("w1/manifest.json", "{not json")
        self.run_fails(4, mode="manifest", manifest_key="w1/manifest.json")

    def test_manifests_can_be_disabled(self):
        self.manifest({"steps": [{"target": "aurora", "script": "w1/a.sql"}]})
        rc, out = self.e.run(cfg_path=self.e.config(allow_s3_manifests=False), mode="manifest", manifest_key="w1/manifest.json")
        self.assertEqual(rc, 4, out)

    def test_a_manifest_cannot_smuggle_a_bad_variable(self):
        self.manifest({"steps": [{"target": "aurora", "script": "w1/a.sql", "variables": {"x": "'; DROP TABLE t; --"}}]})
        self.run_fails(4, mode="manifest", manifest_key="w1/manifest.json")


class CheckAllTest(RunnerTest):
    def test_check_without_a_target_checks_every_target_and_carries_on(self):
        self.e.secret("migrator", "plain-Pass1")
        rc, out = self.e.run(mode="check")
        # tls has no CA bundle on this machine: it fails, the others still run.
        self.assertEqual(rc, 4, out)
        self.assertEqual(sorted(c["client"] for c in self.e.calls()), ["mysql", "psql", "sqlplus"])


@unittest.skipUnless(shutil.which("terraform"), "terraform not installed")
class LauncherTest(unittest.TestCase):
    """Renders the real launcher, substitutes SSM parameters, runs it."""

    @classmethod
    def setUpClass(cls):
        cls.e = Env()
        cfg_path = cls.e.config()
        with open(cfg_path) as f:
            cfg_json = f.read()
        work = tempfile.mkdtemp(prefix="sqlb-render.")
        cls.addClassCleanup(shutil.rmtree, work, True)
        shutil.copy(os.path.join(HERE, "render", "main.tf"), work)
        with open(os.path.join(work, "main.tf")) as f:
            body = f.read().replace("${path.module}/../../../scripts", os.path.join(MODULE, "scripts"))
        with open(os.path.join(work, "main.tf"), "w") as f:
            f.write(body)
        with open(os.path.join(work, "terraform.tfvars.json"), "w") as f:
            json.dump({"config_json": cfg_json}, f)
        for cmd in (["terraform", "init", "-input=false"], ["terraform", "apply", "-auto-approve", "-input=false"]):
            subprocess.run(cmd, cwd=work, check=True, stdout=subprocess.DEVNULL)
        cls.rendered = subprocess.run(["terraform", "output", "-raw", "script"], cwd=work, check=True, stdout=subprocess.PIPE).stdout.decode()

    @classmethod
    def tearDownClass(cls):
        cls.e.close()

    def substituted(self, **params):
        defaults = {"Mode": "run", "Target": "", "ScriptKey": "", "ExpectedSha256": "", "Transaction": "auto", "Variables": "",
                    "Runbook": "", "ManifestKey": "", "StartAt": "", "DryRun": "false", "StepTimeoutSeconds": "0"}
        defaults.update(params)
        text = self.rendered
        for k, v in defaults.items():
            text = text.replace("{{ %s }}" % k, v)
        self.assertNotIn("{{", text, "an undeclared parameter is left in the launcher")
        return text

    def test_shellcheck(self):
        if not shutil.which("shellcheck"):
            self.skipTest("shellcheck not installed")
        path = os.path.join(self.e.root, "launcher.sh")
        with open(path, "w") as f:
            f.write(self.substituted())
        p = subprocess.run(["shellcheck", "-s", "bash", path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(p.returncode, 0, p.stdout.decode())

    def test_launcher_runs_the_embedded_runner(self):
        digest = self.e.put("w1/01.sql", "SELECT 42;\n")
        path = os.path.join(self.e.root, "launcher.sh")
        with open(path, "w") as f:
            f.write(self.substituted(Mode="run", Target="aurora", ScriptKey="w1/01.sql", ExpectedSha256=digest))
        sysdir = os.path.join(self.e.root, "py")
        os.makedirs(sysdir, exist_ok=True)
        for t in ("python3", "mktemp", "rm", "cat"):
            dst = os.path.join(sysdir, t)
            if not os.path.exists(dst):
                os.symlink(sys.executable if t == "python3" else shutil.which(t), dst)
        env = {"PATH": self.e.path() + ":" + sysdir, "HOME": self.e.root}
        p = subprocess.run([shutil.which("bash"), path], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = p.stdout.decode()
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn(PASSWORD, out)
        self.assertIn("SELECT 42", self.e.calls()[-1]["sql"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
