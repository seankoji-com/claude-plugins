#!/usr/bin/env python3
"""Subprocess-level command-surface tests for offload_sidecar.py: the CLI
`status` subcommand and the MCP stdio JSON-RPC loop in `main()`.

Distinct from test_offload_sidecar.py, which loads the module in-process via
importlib and unit-tests its pure functions — this file spawns the script as
a real subprocess (`subprocess.run([sys.executable, ...])`) to exercise the
process boundary itself: argv parsing, stdin/stdout line framing, and the
sys.argv -> cmd_status()/handle_message() -> exit-code/stdout wiring, none
of which the in-process tests touch.

Every subprocess in this file is spawned with a minimal, explicit `env=`
(never inherited from the ambient environment) that neutralizes real
external effects: OLLAMA_HOST points at a loopback port nothing listens on
(so gather_status() fails fast with "connection refused" instead of hanging
or reaching a real LAN host), the three OLLAMA_*TIMEOUT knobs are pinned
small, AGY_BIN points at a path that can't exist (so shutil.which() fails
fast instead of finding a real `agy`), and AGY_QUOTA_STATE is redirected
into a tempdir so quota state never touches ~/.local/state/offload-sidecar.
See _subprocess_env() below — every subprocess.run call site in this file
goes through it.
"""

import ast
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_PLUGIN_DIR = os.path.normpath(os.path.join(_HERE, "..", "..", "plugins", "offload-sidecar"))
_SCRIPT_PATH = os.path.join(_PLUGIN_DIR, "scripts", "offload_sidecar.py")
_MCP_JSON_PATH = os.path.join(_PLUGIN_DIR, ".mcp.json")
_PLUGIN_JSON_PATH = os.path.join(_PLUGIN_DIR, ".claude-plugin", "plugin.json")


def _subprocess_env(quota_dir, extra=None):
    """Minimal, explicit environment for a subprocess spawn — built from
    scratch (not a copy of os.environ) so nothing ambient (a real
    OLLAMA_HOST, AGY_BIN, etc. set in the maintainer's own shell) can leak
    into what the test actually exercises."""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "OLLAMA_HOST": "http://127.0.0.1:1",
        "OLLAMA_STATUS_TIMEOUT": "1",
        "OLLAMA_TIMEOUT": "1",
        "OLLAMA_FAST_TIMEOUT": "1",
        "AGY_BIN": "/nonexistent/offload-sidecar-test-agy",
        "AGY_QUOTA_STATE": os.path.join(quota_dir, "quota.json"),
    }
    if extra:
        env.update(extra)
    return env


def _run_script(args, quota_dir, input_text=None, env_extra=None, cwd=None, timeout=15):
    return subprocess.run(
        [sys.executable, _SCRIPT_PATH] + args,
        input=input_text,
        capture_output=True,
        text=True,
        env=_subprocess_env(quota_dir, env_extra),
        cwd=cwd,
        timeout=timeout,
    )


class CliStatusSubcommandTest(unittest.TestCase):
    """Item 1: `python3 offload_sidecar.py status` as a real subprocess.
    Proves the sys.argv -> cmd_status() -> sys.exit() wiring, not
    gather_status()'s own logic (already covered in-process elsewhere)."""

    def test_status_exits_1_and_reports_unreachable_without_crashing(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = _run_script(["status"], tmp)
        # OLLAMA_HOST is an unreachable loopback port under the pinned env,
        # so gather_status() reports the host down and all_ok is False —
        # cmd_status() must exit 1, not 0.
        self.assertEqual(proc.returncode, 1)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertIn("offload-sidecar status:", proc.stdout)
        self.assertIn("[deep tier]", proc.stdout)
        self.assertIn("reachable:         no", proc.stdout)


class McpStdioLoopTest(unittest.TestCase):
    """Item 2: the MCP stdio JSON-RPC loop in main(), spawned with no argv
    and fed line-delimited JSON on stdin."""

    def _rpc_lines(self, stdout_text):
        return [json.loads(line) for line in stdout_text.splitlines() if line.strip()]

    def test_initialize_ping_tools_list(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "ping"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/list"},
        ]
        stdin_text = "".join(json.dumps(m) + "\n" for m in messages)
        with tempfile.TemporaryDirectory() as tmp:
            proc = _run_script([], tmp, input_text=stdin_text)
        self.assertEqual(proc.returncode, 0)
        responses = self._rpc_lines(proc.stdout)
        self.assertEqual(len(responses), 3)

        init = responses[0]
        self.assertEqual(init["id"], 1)
        self.assertEqual(init["result"]["serverInfo"]["name"], "offload-sidecar")
        self.assertIn("protocolVersion", init["result"])

        ping = responses[1]
        self.assertEqual(ping["id"], 2)
        self.assertEqual(ping["result"], {})

        tools_list = responses[2]
        self.assertEqual(tools_list["id"], 3)
        tool_names = [t["name"] for t in tools_list["result"]["tools"]]
        self.assertEqual(tool_names, ["process_local_file"])

    def test_notification_gets_no_response(self):
        # notifications/initialized has no id — the loop must not emit a
        # response line for it. Bracket it with a ping so we can prove the
        # loop actually processed the notification line (rather than never
        # reading it) instead of just processing the ping alone.
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "ping"},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "ping"},
        ]
        stdin_text = "".join(json.dumps(m) + "\n" for m in messages)
        with tempfile.TemporaryDirectory() as tmp:
            proc = _run_script([], tmp, input_text=stdin_text)
        self.assertEqual(proc.returncode, 0)
        responses = self._rpc_lines(proc.stdout)
        # Exactly two responses (the two pings) — the notification produced
        # zero lines, not an empty/null line.
        self.assertEqual([r["id"] for r in responses], [1, 2])

    def test_malformed_json_line_then_recovery(self):
        stdin_text = (
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}) + "\n"
            + "{this is not valid json\n"
            + json.dumps({"jsonrpc": "2.0", "id": 2, "method": "ping"}) + "\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            proc = _run_script([], tmp, input_text=stdin_text)
        self.assertEqual(proc.returncode, 0)
        responses = self._rpc_lines(proc.stdout)
        self.assertEqual(len(responses), 3)
        self.assertEqual(responses[0], {"jsonrpc": "2.0", "id": 1, "result": {}})
        parse_err = responses[1]
        self.assertIsNone(parse_err["id"])
        self.assertEqual(parse_err["error"]["code"], -32700)
        self.assertEqual(parse_err["error"]["message"], "parse error")
        # The loop kept running after the malformed line: the ping sent
        # after it was still answered.
        self.assertEqual(responses[2], {"jsonrpc": "2.0", "id": 2, "result": {}})

    def test_unknown_method_with_id_is_method_not_found(self):
        messages = [{"jsonrpc": "2.0", "id": 9, "method": "totally/bogus"}]
        stdin_text = "".join(json.dumps(m) + "\n" for m in messages)
        with tempfile.TemporaryDirectory() as tmp:
            proc = _run_script([], tmp, input_text=stdin_text)
        self.assertEqual(proc.returncode, 0)
        responses = self._rpc_lines(proc.stdout)
        self.assertEqual(len(responses), 1)
        self.assertEqual(responses[0]["id"], 9)
        self.assertEqual(responses[0]["error"]["code"], -32601)

    def test_unknown_method_without_id_is_silent(self):
        # No id at all -> treated as an unknown notification, same silence
        # as notifications/initialized. Bracket with pings, same reasoning
        # as test_notification_gets_no_response.
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "ping"},
            {"jsonrpc": "2.0", "method": "totally/bogus/notification"},
            {"jsonrpc": "2.0", "id": 2, "method": "ping"},
        ]
        stdin_text = "".join(json.dumps(m) + "\n" for m in messages)
        with tempfile.TemporaryDirectory() as tmp:
            proc = _run_script([], tmp, input_text=stdin_text)
        self.assertEqual(proc.returncode, 0)
        responses = self._rpc_lines(proc.stdout)
        self.assertEqual([r["id"] for r in responses], [1, 2])


class McpToolsCallDeterministicOpTest(unittest.TestCase):
    """Item 3: one tools/call -> process_local_file round trip on a
    deterministic operation, with the path-containment guard handled
    explicitly (both input_path and output_path, and the subprocess's
    resolved root, must agree — see resolve_root()/_check_within_root()) so
    the call actually exercises the operation instead of silently returning
    an isError-shaped rejection."""

    def _load_operations(self):
        # In-process introspection only (no subprocess): find a
        # kind="deterministic" operation with no external-tool dependency,
        # by reading the OPERATIONS dict from the real module. This does
        # not execute main() or any network/subprocess code — the module's
        # top level only defines functions/dicts.
        import importlib.util

        spec = importlib.util.spec_from_file_location("offload_sidecar_intro", _SCRIPT_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.OPERATIONS

    def test_json_format_round_trip(self):
        operations = self._load_operations()
        op = operations["json_format"]
        self.assertEqual(op["kind"], "deterministic")

        with tempfile.TemporaryDirectory() as tmp:
            input_path = os.path.join(tmp, "in.json")
            output_path = os.path.join(tmp, "out.json")
            with open(input_path, "w", encoding="utf-8") as f:
                f.write('{"b": 2, "a": 1}')

            request = {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {
                    "name": "process_local_file",
                    "arguments": {
                        "operation": "json_format",
                        "input_path": input_path,
                        "output_path": output_path,
                        "params": {"sort_keys": True},
                    },
                },
            }
            stdin_text = json.dumps(request) + "\n"
            # Both routes to resolve_root() pinned at the same tempdir: cwd
            # (the process's own cwd fallback) and SIDECAR_ROOT (the env
            # override resolve_root() reads first) — belt and suspenders so
            # this doesn't silently resolve to some other root.
            proc = _run_script(
                [],
                tmp,
                input_text=stdin_text,
                env_extra={"SIDECAR_ROOT": tmp},
                cwd=tmp,
            )

            self.assertEqual(proc.returncode, 0)
            lines = [json.loads(l) for l in proc.stdout.splitlines() if l.strip()]
            self.assertEqual(len(lines), 1)
            response = lines[0]["result"]

            # Not just "did I get a well-formed response" — isError must be
            # false, i.e. this was not the path-containment guard (or any
            # other error) firing silently underneath a structurally valid
            # envelope.
            self.assertFalse(response["isError"])
            payload = json.loads(response["content"][0]["text"])
            self.assertEqual(payload["status"], "success")
            # realpath on both sides: the server realpath()s output_path
            # internally (e.g. /tmp -> /private/tmp on macOS), and that
            # normalization is not itself under test here.
            self.assertEqual(
                os.path.realpath(payload["output_path"]), os.path.realpath(output_path)
            )

            # The transformed content is not in the RPC payload —
            # deterministic handlers write it to output_path on disk. Read
            # it separately (still inside the tempdir's lifetime) and
            # assert it's the actually-correct transform (sort_keys=True
            # reorders b,a -> a,b), not just "a file exists".
            with open(output_path, "r", encoding="utf-8") as f:
                written = json.load(f)
            self.assertEqual(written, {"a": 1, "b": 2})
            with open(output_path, "r", encoding="utf-8") as f:
                raw = f.read()
            self.assertEqual(list(json.loads(raw).keys()), ["a", "b"])


class ConfigConsistencyTest(unittest.TestCase):
    """Item 4: static cross-file config consistency. No subprocess — pure
    file parsing."""

    def _env_names_read_by_script(self):
        """AST-parse offload_sidecar.py and collect the first string-literal
        argument of every _env(...)/_env_int(...) call site. Deliberately
        NOT a regex over `[A-Z_]*` — that pattern misses names containing
        digits (e.g. an _PER_5H-shaped constant), which an AST walk over
        actual call sites doesn't."""
        with open(_SCRIPT_PATH, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read(), filename=_SCRIPT_PATH)

        names = set()

        class _Visitor(ast.NodeVisitor):
            def visit_Call(self, node):
                if (
                    isinstance(node.func, ast.Name)
                    and node.func.id in ("_env", "_env_int")
                    and node.args
                    and isinstance(node.args[0], ast.Constant)
                    and isinstance(node.args[0].value, str)
                ):
                    names.add(node.args[0].value)
                self.generic_visit(node)

        _Visitor().visit(tree)
        return names

    def test_every_declared_mcp_env_var_is_read_by_the_script(self):
        # Declared -> read direction only (catches "added to .mcp.json,
        # forgot to wire"). Deliberately NOT bidirectional: the script
        # legitimately reads several env vars with defaults that .mcp.json
        # doesn't declare (internal tuning knobs like AGY_NUM_CTX,
        # AGY_TIMEOUT, AGY_QUOTA_STATE, OLLAMA_TIMEOUT,
        # OLLAMA_STATUS_TIMEOUT, OLLAMA_FAST_TIMEOUT) that were never a bug.
        with open(_MCP_JSON_PATH, "r", encoding="utf-8") as f:
            mcp_config = json.load(f)
        declared = set(mcp_config["mcpServers"]["offload-sidecar"]["env"].keys())
        read_by_script = self._env_names_read_by_script()

        missing = declared - read_by_script
        self.assertEqual(
            missing,
            set(),
            f"env vars declared in .mcp.json but never read by offload_sidecar.py: {missing}",
        )

    def test_user_config_keys_match_mcp_json_references_bidirectionally(self):
        # Bidirectional on purpose: declared->referenced catches "added to
        # plugin.json, forgot to wire"; referenced->declared catches a
        # typo'd ${user_config.foo} in a hand-edited .mcp.json that would
        # otherwise silently never interpolate.
        with open(_PLUGIN_JSON_PATH, "r", encoding="utf-8") as f:
            plugin_config = json.load(f)
        user_config_keys = set(plugin_config["userConfig"].keys())

        with open(_MCP_JSON_PATH, "r", encoding="utf-8") as f:
            mcp_text = f.read()
        referenced = set(re.findall(r"\$\{user_config\.([a-zA-Z0-9_]+)\}", mcp_text))

        self.assertEqual(
            user_config_keys,
            referenced,
            f"userConfig keys and .mcp.json ${{user_config.*}} references diverge: "
            f"declared-only={user_config_keys - referenced}, "
            f"referenced-only={referenced - user_config_keys}",
        )


if __name__ == "__main__":
    unittest.main()
