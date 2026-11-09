#!/usr/bin/env python3
"""Run tests/rewriter through the candidate's rewriter, in front of PostgREST over the run's clone.

    reptracker_rewriter.py OUT_DIR

As CI's rewriter-test runs them, against the postgrest-rewriter image built from the
candidate's Dockerfile.rewriter. The checks have no docker daemon, so the image is
assembled instead of built: Dockerfile.rewriter's FROM must be the base the runtime
image carries at REPTRACKER_REWRITER_ROOT, its COPY instructions are applied to a
scratch tree beside that base, and its CMD (docker/rewriter_entrypoint.sh) runs with
the image's absolute paths pointed at that tree, starting the base's own OpenResty
through its musl loader. The rendered template's `listen` addresses and its PostgREST
upstream are moved to loopback ports, the one change a shared network namespace needs.

First scripts/openapi_rewrite.sh regenerates the rewrite rules and the argument map in
a scratch copy, with the process_openapi.py the runtime image carries at
REPTRACKER_PROCESS_OPENAPI; endpoints/rewrite_rules.conf and endpoints/rpc_arguments.lua,
which Dockerfile.rewriter copies, must be what it generates.

Writes OUT_DIR/rewriter.xml (one junit case per test) and OUT_DIR/rewriter-nginx.log (the
rewriter's output), and exits with pytest's status, 1 when the rewriter cannot be
assembled or started, or SKIP when the runtime image carries no rewriter base.
"""
import difflib
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

from postgrest import serving

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
TESTS = os.path.join(REPO, "tests", "rewriter")
DOCKERFILE = os.path.join(REPO, "Dockerfile.rewriter")
GENERATED = ("rewrite_rules.conf", "rpc_arguments.lua")
OPENRESTY = "/usr/local/openresty"
UPSTREAM = "http://reputation-tracker-postgrest:3000"
LISTEN = re.compile(r"(\blisten\s+)[0-9.]+:(\d+)\b")
WORKERS = "4"
STARTUP_TIMEOUT_S = 60
SKIP = 77


class RewriterError(Exception):
    """The candidate's rewriter cannot be assembled or does not start."""


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port: int = sock.getsockname()[1]
        return port


def _instructions(path: str) -> list[tuple[str, str]]:
    with open(path, encoding="utf-8") as handle:
        text = re.sub(r"\\\n", " ", handle.read())
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            word, _, rest = line.partition(" ")
            out.append((word.upper(), rest.strip()))
    return out


def _check_generated(work: str) -> None:
    """scripts/openapi_rewrite.sh in a scratch copy must write what endpoints/ holds."""
    stage = os.path.join(work, "openapi")
    for name in ("endpoints", "scripts"):
        shutil.copytree(os.path.join(REPO, name), os.path.join(stage, name))
    script = os.path.join(stage, "scripts", "openapi_rewrite.sh")
    with open(script, encoding="utf-8") as handle:
        ref = re.search(r'COMMON_CI_REF="\$\{COMMON_CI_REF:-([0-9a-f]+)\}"', handle.read())
    have = os.environ["REPTRACKER_PROCESS_OPENAPI_COMMIT"]
    if ref is None or ref.group(1) != have:
        raise RewriterError(f"scripts/openapi_rewrite.sh's COMMON_CI_REF is not {have}, the process_openapi.py "
                            "the runtime image carries: move PROCESS_OPENAPI_COMMIT in .aidev/runtime/Dockerfile")
    shutil.copy(os.environ["REPTRACKER_PROCESS_OPENAPI"], os.path.join(stage, "scripts", "process_openapi.py"))
    subprocess.run(["bash", script], cwd=os.path.join(stage, "scripts"), check=True)
    stale = []
    for name in GENERATED:
        with open(os.path.join(stage, "endpoints_openapi", name), encoding="utf-8") as handle:
            generated = handle.read().splitlines(keepends=True)
        with open(os.path.join(REPO, "endpoints", name), encoding="utf-8") as handle:
            committed = handle.read().splitlines(keepends=True)
        if generated != committed:
            sys.stdout.writelines(difflib.unified_diff(committed, generated, f"endpoints/{name}", "generated"))
            stale.append(f"endpoints/{name}")
    if stale:
        raise RewriterError(f"{', '.join(stale)} differ from what scripts/openapi_rewrite.sh generates: rerun it")
    print("endpoints/rewrite_rules.conf and endpoints/rpc_arguments.lua are what scripts/openapi_rewrite.sh generates")


def _assemble(root: str, tree: str) -> list[str]:
    """Apply Dockerfile.rewriter over the base at root into tree; return its CMD as run from tree."""
    base, cmd = os.environ["REPTRACKER_REWRITER_BASE"], None
    for word, rest in _instructions(DOCKERFILE):
        if word == "FROM":
            if rest != base:
                raise RewriterError(f"Dockerfile.rewriter builds FROM {rest}, the runtime image carries {base}: "
                                    "move REWRITER_BASE in .aidev/runtime/Dockerfile")
            shutil.copytree(f"{root}{OPENRESTY}/nginx/conf", f"{tree}{OPENRESTY}/nginx/conf")
            os.makedirs(f"{tree}{OPENRESTY}/nginx/logs")
        elif word == "COPY":
            *sources, dest = shlex.split(rest)
            if any(s.startswith("--") for s in sources):
                raise RewriterError(f"COPY {rest}: flags are not supported without docker")
            for src in sources:
                target = tree + (os.path.join(dest, os.path.basename(src)) if dest.endswith("/") else dest)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if os.path.isdir(os.path.join(REPO, src)):
                    shutil.copytree(os.path.join(REPO, src), target, dirs_exist_ok=True)
                else:
                    shutil.copy2(os.path.join(REPO, src), target)
        elif word == "CMD":
            cmd = json.loads(rest)
        elif word not in ("ARG", "LABEL"):
            raise RewriterError(f"Dockerfile.rewriter: {word} is not supported without docker")
    if not cmd or not cmd[0].startswith("/") or not os.path.isfile(tree + cmd[0]):
        raise RewriterError(f"Dockerfile.rewriter's CMD {cmd} is not an exec-form script the Dockerfile copies")
    return [tree + cmd[0], *cmd[1:]]


def _relocate(root: str, tree: str, entrypoint: str, postgrest: str) -> int:
    """Point the entrypoint's absolute paths at tree and the template's addresses at loopback.

    Returns the port the template's :80 listens on.
    """
    prefix = f"{tree}{OPENRESTY}/nginx"
    with open(entrypoint, encoding="utf-8") as handle:
        text = handle.read()
    with open(entrypoint, "w", encoding="utf-8") as handle:
        handle.write(text.replace(OPENRESTY + "/", f"{tree}{OPENRESTY}/"))
    template = f"{prefix}/conf/nginx.conf.template"
    with open(template, encoding="utf-8") as handle:
        text = handle.read()
    ports: dict[str, int] = {}
    text = LISTEN.sub(lambda m: f"{m.group(1)}127.0.0.1:{ports.setdefault(m.group(2), _free_port())}", text)
    if "80" not in ports or UPSTREAM not in text:
        raise RewriterError(f"docker/reputation_tracker_nginx.conf.template no longer listens on :80 "
                            f"or proxies to {UPSTREAM}")
    with open(template, "w", encoding="utf-8") as handle:
        handle.write(text.replace(UPSTREAM, postgrest))
    lib = ":".join(f"{root}{d}" for d in (f"{OPENRESTY}/luajit/lib", f"{OPENRESTY}/pcre2/lib",
                                          f"{OPENRESTY}/openssl3/lib", "/lib", "/usr/lib"))
    wrapper = f"{tree}{OPENRESTY}/bin/openresty"
    os.makedirs(os.path.dirname(wrapper), exist_ok=True)
    with open(wrapper, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\n"
                     f"exec {root}/lib/ld-musl-x86_64.so.1 --library-path {lib} "
                     f"{root}{OPENRESTY}/nginx/sbin/nginx -p {prefix}/ \"$@\"\n")
    os.chmod(wrapper, 0o755)
    return ports["80"]


def _lua_env(root: str) -> dict[str, str]:
    lualib = [f"{root}{OPENRESTY}/site/lualib", f"{root}{OPENRESTY}/lualib"]
    return dict(os.environ,
                LUA_PATH=";".join(f"{d}/{p}" for d in lualib for p in ("?.ljbc", "?/init.ljbc", "?.lua", "?/init.lua")),
                LUA_CPATH=";".join(f"{d}/?.so" for d in lualib))


def _wait(base: str, proc: subprocess.Popen[bytes], log_path: str) -> None:
    deadline = time.monotonic() + STARTUP_TIMEOUT_S
    while True:
        try:
            with urllib.request.urlopen(base + "/version", timeout=5) as resp:
                print(f"{base}/version: {resp.status} {resp.read().decode(errors='replace')}")
                return
        except (urllib.error.URLError, OSError):
            pass
        if proc.poll() is not None:
            raise RewriterError(f"the rewriter exited with {proc.returncode}; see {log_path}")
        if time.monotonic() > deadline:
            raise RewriterError(f"the rewriter did not answer /version within {STARTUP_TIMEOUT_S}s; see {log_path}")
        time.sleep(1)


def _tail(path: str, lines: int = 40) -> None:
    with open(path, encoding="utf-8", errors="replace") as handle:
        print("".join(handle.readlines()[-lines:]), end="")


def main(out: str) -> int:
    root = os.environ.get("REPTRACKER_REWRITER_ROOT", "")
    if not (root and os.path.isfile(f"{root}{OPENRESTY}/nginx/sbin/nginx")
            and os.path.isfile(os.environ.get("REPTRACKER_PROCESS_OPENAPI", ""))):
        print("skipped: this runtime image carries no rewriter base (REPTRACKER_REWRITER_ROOT) "
              "and no docker daemon to build Dockerfile.rewriter")
        return SKIP
    os.makedirs(out, exist_ok=True)
    log_path = os.path.abspath(os.path.join(out, "rewriter-nginx.log"))
    with tempfile.TemporaryDirectory() as work:
        try:
            _check_generated(work)
            with serving(os.path.join(out, "postgrest-rewriter.log")) as postgrest:
                tree = os.path.join(work, "image")
                cmd = _assemble(root, tree)
                port = _relocate(root, tree, cmd[0], postgrest)
                with open(log_path, "w") as log:
                    proc = subprocess.Popen(cmd, env=_lua_env(root), stdout=log, stderr=subprocess.STDOUT,
                                            start_new_session=True)
                try:
                    _wait(f"http://127.0.0.1:{port}", proc, log_path)
                    host, pg_port = postgrest.removeprefix("http://").rsplit(":", 1)
                    env = dict(os.environ, REPTRACKER_ADDRESS=host, REPTRACKER_PORT=pg_port, REWRITER_PORT=str(port))
                    rc = subprocess.run(
                        [sys.executable, "-m", "pytest", "-n", WORKERS, "-p", "no:cacheprovider",
                         "--junitxml", os.path.abspath(os.path.join(out, "rewriter.xml")), "."],
                        cwd=TESTS, env=env, check=False,
                    ).returncode
                finally:
                    os.killpg(proc.pid, signal.SIGTERM)
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
        except (RewriterError, RuntimeError, subprocess.CalledProcessError) as err:
            print(err)
            rc = 1
    if rc != 0 and os.path.isfile(log_path):
        print("== the rewriter's output (tail)")
        _tail(log_path)
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} OUT_DIR")
    sys.exit(main(sys.argv[1]))
