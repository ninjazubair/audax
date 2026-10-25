"""Run: /usr/bin/python3 test_providers.py"""
import contextlib
import datetime
import io
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

import providers

# The version comes from the VERSION file, so no release edits this test.
UA = providers.USER_AGENT
assert UA.startswith("AUDAX/") and UA == "AUDAX/" + providers.APP_VERSION
assert providers.COPILOT_HEADERS["Editor-Version"] == "audax/" + providers.APP_VERSION
assert providers.APP_VERSION != "dev"  # the repo's VERSION file was found and read
assert providers.read_version(Path(tempfile.mkdtemp()) / "VERSION") == "dev"  # missing: no raise
REAL_POST_JSON = providers.post_json  # the tests below replace it; the 0.4.0 wire test needs it
assert providers.ENV_FILE == Path.home() / ".config/audax/.env"
providers.ENV_FILE = Path(tempfile.mkdtemp()) / ".env"  # never the user's real .env
ENVIRON = dict(os.environ)  # no secret ever goes into the environment


def raising(exc):
    """A stand-in that raises exc, whatever it is called with."""
    def fake(*args, **kwargs):
        raise exc
    return fake


url, h, b = providers.claude_request({"model": "claude-opus-5-5", "api_key": "k"}, "SYS", "USR")
assert url == "https://api.anthropic.com/v1/messages" and h["x-api-key"] == "k"
assert h["anthropic-version"] == "2023-06-01"
assert h["anthropic-beta"] == "server-side-fallback-2026-07-01"
assert h["content-type"] == "application/json" and h["User-Agent"] == UA
assert b["system"] == "SYS" and b["messages"] == [{"role": "user", "content": "USR"}]
assert b["output_config"] == {"effort": "low"} and b["fallbacks"] == "default"
assert b["max_tokens"] == 2048
assert b == {"model": "claude-opus-5-5", "max_tokens": 2048, "system": "SYS",
             "messages": [{"role": "user", "content": "USR"}],
             "output_config": {"effort": "low"}, "fallbacks": "default"}

url, h, b = providers.openai_request({"model": "gpt-4.1", "api_key": "k"}, "SYS", "USR")
assert url == "https://api.openai.com/v1/chat/completions"
assert h["Authorization"] == "Bearer k" and b["temperature"] == 0
assert h["content-type"] == "application/json" and h["User-Agent"] == UA
assert b == {"model": "gpt-4.1", "temperature": 0, "messages": [
    {"role": "system", "content": "SYS"}, {"role": "user", "content": "USR"}]}

url, h, b = providers.ollama_request({"model": "gemma4"}, "SYS", "USR")
assert url == "http://127.0.0.1:11434/api/chat" and h["User-Agent"] == UA
assert "Authorization" not in h and "x-api-key" not in h  # local: no key ever sent
assert b == {"model": "gemma4", "stream": False, "think": False, "keep_alive": "1h",
             "options": {"temperature": 0}, "messages": [
                 {"role": "system", "content": "SYS"}, {"role": "user", "content": "USR"}]}
assert providers.ollama_request({"model": "m", "url": "http://x/y"}, "S", "U")[0] == "http://x/y"

# A pasted key loses surrounding whitespace; one with a line break or non-ASCII character is
# refused with an error that does not quote it (http.client would quote it).
assert providers.claude_request({"model": "m", "api_key": " k\n"}, "S", "U")[1]["x-api-key"] == "k"
for bad in ("sk-SECRET\nx", "sk-SECRET—x"):
    try:
        providers.openai_request({"model": "m", "api_key": bad}, "S", "U")
        assert False
    except ValueError as e:
        assert "SECRET" not in repr(e)

assert providers.extract_text("claude", {"content": [
    {"type": "text", "text": "A"}, {"type": "text", "text": "B"}]}) == "AB"
assert providers.extract_text("claude", {"content": [
    {"type": "thinking", "thinking": "hmm"}, {"type": "text", "text": "A"}]}) == "A"
assert providers.extract_text("claude", {"content": []}) == ""
assert providers.extract_text("openai", {"choices": [{"message": {"content": "X"}}]}) == "X"
assert providers.extract_text("ollama", {"message": {"content": "Y"}}) == "Y"

# post_json: POST, JSON body, the caller's headers plus User-Agent, the given timeout.
seen = {}


def fake_urlopen(req, timeout):
    seen.update(url=req.full_url, method=req.get_method(), body=req.data and json.loads(req.data),
                ua=req.get_header("User-agent"), key=req.get_header("X-api-key"), timeout=timeout)
    return io.BytesIO(b'{"ok": 1}')


real_urlopen = urllib.request.urlopen
urllib.request.urlopen = fake_urlopen
assert providers.post_json("http://x/y", {"x-api-key": "k"}, {"q": 1}, 7) == {"ok": 1}
assert seen == {"url": "http://x/y", "method": "POST", "body": {"q": 1}, "ua": UA, "key": "k",
                "timeout": 7}
assert providers.get_json("http://x/z", {"x-api-key": "k"}, 10) == {"ok": 1}  # the GET sibling
assert seen == {"url": "http://x/z", "method": "GET", "body": None, "ua": UA, "key": "k",
                "timeout": 10}
urllib.request.urlopen = real_urlopen

# GitHub Copilot: the token comes from the GitHub CLI on every call; only the host is cached.
assert providers.GH_PATHS == ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
assert providers.COPILOT_HEADERS["Copilot-Integration-Id"] == "audax"
assert providers.HOST_CACHE == Path.home() / ".cache/mac-dictation/copilot_host.json"
providers.HOST_CACHE = Path(tempfile.mkdtemp()) / "host.json"  # never the real one
BIZ = "https://api.business.githubcopilot.com"
assert providers.gh_token(run=lambda *a, **k: type(
    "R", (), {"stdout": " gho_x \n", "returncode": 0})()) == "gho_x"
assert providers.gh_token(run=raising(FileNotFoundError())) == ""
tmp = Path(tempfile.mkdtemp()) / "host.json"
calls = []


def fake_get(url, headers, timeout):
    calls.append(url)
    return {"chat_enabled": True, "endpoints": {"api": "https://api.business.githubcopilot.com"}}


assert providers.copilot_api_host("t", get=fake_get, cache=tmp) == BIZ
assert providers.copilot_api_host("t", get=fake_get, cache=tmp) == BIZ and len(calls) == 1  # cached


def evil_get(url, headers, timeout):
    return {"chat_enabled": True, "endpoints": {"api": "https://evil.example.com"}}


assert providers.copilot_api_host("t", get=evil_get, cache=Path(tempfile.mkdtemp()) / "h.json"
                                  ) == "https://api.githubcopilot.com"
url, h, b = providers.copilot_request({"model": "gpt-4.1", "_token": "t", "_host": BIZ}, "S", "U")
assert url == "https://api.business.githubcopilot.com/chat/completions"
assert h["Authorization"] == "Bearer t" and h["Copilot-Integration-Id"] == "audax"
assert "gho" not in str(json.loads(tmp.read_text()))  # host cache holds no token

R = type("R", (), {})


def gh_out(by_path):
    def run(cmd, **k):
        assert cmd[0] in providers.GH_PATHS and k["timeout"] == 3
        assert cmd[1:] == ["auth", "token", "--hostname", "github.com"]
        r = R()
        r.stdout, r.returncode = by_path[cmd[0]], 0
        return r
    return run


paths = providers.GH_PATHS  # second gh used when the first prints nothing; odd output refused
assert providers.gh_token(run=gh_out({paths[0]: "", paths[1]: "gho_y\n"})) == "gho_y"
assert providers.gh_token(run=gh_out({paths[0]: "warn\ngho_y\n", paths[1]: ""})) == ""


def bad_bytes(cmd, **k):  # text=True on a non-UTF-8 byte: the error's repr holds the token
    raise UnicodeDecodeError("utf-8", b"gho_FAKE\xff", 8, 9, "bad")


assert providers.gh_token(run=bad_bytes) == ""
assert calls[0] == "https://api.github.com/copilot_internal/user"
assert set(json.loads(tmp.read_text())) == {"api", "at"} and tmp.stat().st_mode & 0o777 == 0o600
tmp.write_text(json.dumps({"api": "https://api.business.githubcopilot.com", "at": 0}))
providers.copilot_api_host("t", get=fake_get, cache=tmp)
assert len(calls) == 2  # older than 24 h: asked again
tmp.write_text(json.dumps({"api": BIZ, "at": time.time() + 3600}))
assert providers.read_host_cache(tmp) is None  # dated in the future (clock moved back): stale
d = Path(tempfile.mkdtemp())
(d / "h.json").mkdir()  # os.replace onto a directory fails
providers.write_host_cache(d / "h.json", BIZ)  # best effort: no exception
assert [p.name for p in d.iterdir()] == ["h.json"]  # and its own temp file is gone
(d / "f").write_text("")
providers.write_host_cache(d / "f" / "h.json", BIZ)  # parent is a file: mkdir fails, no exception
for api in ("http://api.githubcopilot.com", "https://githubcopilot.com.evil.example", 5, None,
            "https://[x.githubcopilot.com", "https://evilgithubcopilot.com"):
    got = providers.copilot_api_host("t", get=lambda u, h, t: {"endpoints": {"api": api}},
                                     cache=Path(tempfile.mkdtemp()) / "h.json")
    assert got == "https://api.githubcopilot.com", api
try:
    providers.copilot_api_host("t", get=lambda u, h, t: {"chat_enabled": False},
                               cache=Path(tempfile.mkdtemp()) / "h.json")
    assert False
except RuntimeError:
    pass
assert b == {"model": "gpt-4.1", "temperature": 0, "messages": [
    {"role": "system", "content": "S"}, {"role": "user", "content": "U"}]}

# Copilot models: the seat's list picks the route; /responses gets its own body and reader.
assert providers.MODELS_CACHE == Path.home() / ".cache/mac-dictation/copilot_models.json"
assert providers.MODELS_CACHE_SECONDS == 600
providers.MODELS_CACHE = Path(tempfile.mkdtemp()) / "models.json"  # never the real one
mods = [{"id": "gpt-6.1-sol", "name": "GPT-6.1 Sol", "route": "/responses"}, {"id": "gpt-4.1", "name": "GPT-4.1", "route": "/chat/completions"}]
assert providers.copilot_route("gpt-6.1-sol", mods) == "/responses"
assert providers.copilot_route("gpt-4.1", mods) == "/chat/completions"
assert providers.copilot_route("unknown", mods) == "/chat/completions"   # test_copilot_route_unknown
assert providers.copilot_route("gpt-6.2-sol", []) == "/responses"  # not listed: by its id
assert providers.copilot_route("gpt-4.1", []) == "/chat/completions"
assert providers.copilot_route("gpt-5.3-codex", []) == "/responses"
assert providers.copilot_route("my-codex", []) == "/responses"
assert providers.copilot_route("claude-opus-5.5", []) == "/chat/completions"
assert providers.copilot_route("gpt-5-x", [{"id": "gpt-5-x", "route": "/chat/completions"}]
                               ) == "/chat/completions"  # a listed route beats the guess
assert providers.copilot_route("gpt-4.1", [5, {"id": "gpt-4.1"}, {"id": "gpt-4.1", "route": ""}]
                               ) == "/chat/completions"  # a foreign cache shape: by the id
url, h, b = providers.copilot_request({"model": "gpt-6.1-sol", "_token": "t", "_host": "https://api.business.githubcopilot.com", "_models": mods}, "S", "U")
assert url.endswith("/responses") and b == {"model": "gpt-6.1-sol", "instructions": "S", "input": [{"role": "user", "content": [{"type": "input_text", "text": "U"}]}], "store": False}
assert h["Authorization"] == "Bearer t" and h["Copilot-Integration-Id"] == "audax"
url, h, b = providers.copilot_request({"model": "gpt-4.1", "_token": "t", "_host": "https://x.githubcopilot.com", "_models": mods}, "S", "U")
assert url.endswith("/chat/completions") and b["messages"][1] == {"role": "user", "content": "U"}
assert providers.extract_text("copilot", {"output": [{"type": "message", "content": [{"type": "output_text", "text": "A"}, {"type": "output_text", "text": "B"}]}]}) == "AB"
assert providers.extract_text("copilot", {"choices": [{"message": {"content": "C"}}]}) == "C"
assert providers.extract_text("copilot", {"output": []}) == ""
assert providers.extract_text("copilot", {"output": [  # reasoning items and refusals skipped
    {"type": "reasoning", "summary": []},
    {"type": "message", "content": [{"type": "refusal", "refusal": "no"},
                                    {"type": "output_text", "text": "D"}]}]}) == "D"
raw = {"data": [{"id": "gpt-6.1-sol", "name": "GPT-6.1 Sol", "model_picker_enabled": True, "supported_endpoints": ["/responses", "ws:/responses"]}, {"id": "gpt-4.1", "model_picker_enabled": False, "supported_endpoints": []}, {"id": "emb", "model_picker_enabled": False, "supported_endpoints": ["/embeddings"]}, {"id": "ws-only", "model_picker_enabled": True, "supported_endpoints": ["ws:/responses"]}]}
tmp = Path(tempfile.mkdtemp()) / "m.json"
got = providers.copilot_models("t", "https://h.githubcopilot.com", get=lambda u, h, t: raw, cache=tmp)
assert [m["id"] for m in got] == ["gpt-6.1-sol", "gpt-4.1"] and got[0]["route"] == "/responses" and got[1]["route"] == "/chat/completions"
assert "t" not in json.loads(tmp.read_text()).get("token", "") and '"token"' not in tmp.read_text()
assert got[1]["name"] == "gpt-4.1"  # no name: the id
assert set(json.loads(tmp.read_text())) == {"at", "models"} and tmp.stat().st_mode & 0o777 == 0o600
seen_get = []
raw2 = {"data": [  # sorted: gpt-6.1-sol first, then by name, any case; no endpoints listed: chat
    {"id": "b", "name": "beta", "model_picker_enabled": True},
    {"id": "a", "name": "Alpha", "model_picker_enabled": True,
     "supported_endpoints": ["/chat/completions", "/responses"]},
    {"id": "gpt-6.1-sol", "name": "Zed", "model_picker_enabled": True,
     "supported_endpoints": ["/responses"]}]}
fresh = Path(tempfile.mkdtemp()) / "m.json"
got = providers.copilot_models("t", "https://h.githubcopilot.com", cache=fresh,
                               get=lambda u, h, t: seen_get.append((u, h, t)) or raw2)
assert [(m["id"], m["route"]) for m in got] == [
    ("gpt-6.1-sol", "/responses"), ("a", "/chat/completions"), ("b", "/chat/completions")]
assert seen_get[0][0] == "https://h.githubcopilot.com/models"
assert seen_get[0][1]["Authorization"] == "Bearer t" and seen_get[0][1]["Copilot-Integration-Id"]
assert providers.copilot_models("t", "https://h.githubcopilot.com", cache=fresh,
                                get=lambda u, h, t: seen_get.append(u) or raw) == got
assert len(seen_get) == 1  # within 10 minutes: the cache, no call


def down(url, headers, timeout):
    raise urllib.error.URLError("offline")


saved = json.loads(fresh.read_text())
fresh.write_text(json.dumps({"at": 0, "models": saved["models"]}))  # stale
assert providers.copilot_models("t", "https://h.githubcopilot.com", get=down, cache=fresh) == got
for bad in (down, lambda u, h, t: {"nope": 1}, lambda u, h, t: {"data": [5]},
            raising(ValueError("not JSON"))):
    assert providers.copilot_models("t", "https://h.githubcopilot.com", get=bad,
                                    cache=Path(tempfile.mkdtemp()) / "m.json") == []  # never raises
partial = {"data": [{"name": "no id", "model_picker_enabled": True}, 5,
                    {"id": "gpt-4.1", "supported_endpoints": []}]}
assert [m["id"] for m in providers.copilot_models(  # a malformed entry: skipped, not the list
    "t", "https://h.githubcopilot.com", get=lambda u, h, t: partial,
    cache=Path(tempfile.mkdtemp()) / "m.json")] == ["gpt-4.1"]

calls = []  # complete dispatches to the provider's builder and calls the module's post_json


def fake_post(url, headers, body, timeout):
    calls.append((url, body["model"], timeout))
    return {"content": [{"type": "text", "text": "hi"}]}


providers.post_json = fake_post
assert providers.complete("claude", {"model": "m", "api_key": "k"}, "S", "U") == "hi"
assert calls == [("https://api.anthropic.com/v1/messages", "m", 20)]


def boom(url, headers, body, timeout):
    raise urllib.error.HTTPError(url, 401, "nope", {}, io.BytesIO(b""))


providers.post_json = boom
try:
    providers.complete("claude", {"model": "m", "api_key": "k"}, "S", "U")
    assert False
except urllib.error.HTTPError as e:
    assert e.code == 401  # test_complete_http_error_raises: the caller decides

providers.gh_token = lambda: ""  # copilot without a GitHub sign-in
try:
    providers.complete("copilot", {"model": "m"}, "S", "U")
    assert False
except RuntimeError as e:
    assert "not signed in" in str(e) and "--git-protocol https" in str(e)
providers.gh_token = lambda: "gho_t"
providers.copilot_api_host = lambda token: "https://api.business.githubcopilot.com"


def no_fetch(*a, **k):  # a dictation never fetches the model list; only the CLI refreshes it
    raise AssertionError("model list fetched on the dictation path")


real_copilot_models = providers.copilot_models
providers.copilot_models = no_fetch
providers.get_json = no_fetch
assert providers.with_copilot_auth({})["_models"] == []  # no cache: [], and no fetch
sent = []
providers.post_json = lambda url, headers, body, timeout: (
    sent.append((url, headers["Authorization"], timeout))
    or {"choices": [{"message": {"content": "hi"}}]})
mine = {"model": "gpt-4.1"}
assert providers.complete("copilot", mine, "S", "U") == "hi"
assert sent == [("https://api.business.githubcopilot.com/chat/completions", "Bearer gho_t", 20)]
assert mine == {"model": "gpt-4.1"}  # the caller's dict never gets the token

providers.write_cache(providers.MODELS_CACHE, {"at": 0, "models": mods})  # stale: used
assert providers.with_copilot_auth({})["_models"] == mods
sent = []
providers.post_json = lambda url, headers, body, timeout: (
    sent.append((url, body)) or {"output": [{"type": "message", "content": [
        {"type": "output_text", "text": "clean"}]}]})
assert providers.complete("copilot", {"model": "gpt-6.1-sol"}, "S", "U") == "clean"
assert sent[0][0] == "https://api.business.githubcopilot.com/responses"
assert sent[0][1]["instructions"] == "S" and "messages" not in sent[0][1]

# CLI for the app: main's real path (with_copilot_auth, then copilot_models(token, host)), only
# the GET faked; the list as a JSON array on stdout; signed out: exit 1, one stderr line.
providers.copilot_models = real_copilot_models  # the CLI is the one path that refreshes
urllib.request.urlopen = no_fetch  # and still never reaches the network
prior_cache = providers.MODELS_CACHE
gets = []
providers.get_json = lambda url, headers, timeout: (
    gets.append((url, headers["Authorization"], timeout)) or raw)
providers.MODELS_CACHE = Path(tempfile.mkdtemp()) / "models.json"
out, err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
    assert providers.main(["--copilot-models"]) == 0
    providers.gh_token = lambda: ""
    assert providers.main(["--copilot-models"]) == 1
    providers.gh_token = lambda: "gho_t"
    providers.MODELS_CACHE = Path(tempfile.mkdtemp()) / "models.json"
    providers.get_json = lambda url, headers, timeout: {"data": []}
    assert providers.main(["--copilot-models"]) == 1
assert gets == [(BIZ + "/models", "Bearer gho_t", 10)]  # token and host in the right order
assert [m["id"] for m in json.loads(out.getvalue())] == ["gpt-6.1-sol", "gpt-4.1"]
assert "gho" not in out.getvalue() + err.getvalue()
assert "not signed in" in err.getvalue() and len(err.getvalue().splitlines()) == 2
out, err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
    assert providers.main(["--models"]) == 2 and providers.main([]) == 2  # usage
    providers.copilot_api_host = raising(OSError("bad gho_t"))  # the token in its text
    assert providers.main(["--copilot-models"]) == 1  # any other failure: its type name only
assert out.getvalue() == ""
assert err.getvalue().splitlines() == ["usage: providers.py --copilot-models | --test"] * 2 + [
    "copilot: model list unavailable (OSError)"]
urllib.request.urlopen, providers.MODELS_CACHE = real_urlopen, prior_cache
providers.copilot_api_host = lambda token: "https://api.business.githubcopilot.com"
providers.copilot_models = no_fetch
providers.get_json = no_fetch


def http_error(code):
    def post(url, headers, body, timeout):
        raise urllib.error.HTTPError(url, code, "x", {}, io.BytesIO(b""))
    return post


# A 401/403/404 from Copilot (e.g. gh switched account) marks the cached host stale; others don't.
# Any Copilot failure after the token is read comes back as a RuntimeError, token redacted.
for code, stale in ((403, True), (401, True), (404, True), (500, False)):
    providers.write_host_cache(providers.HOST_CACHE, BIZ)
    providers.post_json = http_error(code)
    try:
        providers.complete("copilot", {"model": "m"}, "S", "U")
        assert False
    except RuntimeError as e:
        assert str(code) in str(e), (code, e)
    saved = json.loads(providers.HOST_CACHE.read_text())
    assert saved["api"] == BIZ, (code, saved)
    assert saved["at"] == 0 if stale else saved["at"] > 0, (code, saved)
for echo in (urllib.error.HTTPError(BIZ + "/chat/completions", 401, "bad gho_t", {},
                                    io.BytesIO(b"")), OSError("refused for gho_t")):
    providers.post_json = raising(echo)  # the server (or a proxy) quotes the token
    try:
        providers.complete("copilot", {"model": "m"}, "S", "U")
        assert False
    except RuntimeError as e:
        assert "gho_t" not in repr(e) and "<redacted>" in repr(e), repr(e)
providers.post_json = raising(NameError("name 'oops' is not defined"))  # a bug, not a failure:
try:  # not wrapped, so dictate.py exits 1 for it, as for the other providers
    providers.complete("copilot", {"model": "m"}, "S", "U")
    assert False
except NameError:
    pass
providers.copilot_api_host = raising(OSError("host lookup quoted gho_t"))  # the GET in flight
try:
    providers.complete("copilot", {"model": "m"}, "S", "U")
    assert False
except RuntimeError as e:
    assert "gho_t" not in repr(e) and "host lookup" in repr(e), repr(e)
providers.copilot_api_host = lambda token: "https://api.business.githubcopilot.com"

# 0.4.0: Amazon Bedrock, Microsoft Foundry, OpenAI- and Anthropic-compatible gateways, and the
# ~/.config/audax/.env file that overrides the app's settings.
KEY = "sk-v4-NEVER-SHOW-1234"
AK, SK = "AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"  # AWS's documented example
CHAT = [{"role": "system", "content": "SYS"}, {"role": "user", "content": "USR"}]
NOW = datetime.datetime(2026, 10, 24, 12, 0, 0, tzinfo=datetime.timezone.utc)
UTC = datetime.timezone.utc

# load_env_file: KEY=VALUE, comments, blank lines, export, quotes, "=" inside values, no expansion.
d = Path(tempfile.mkdtemp())
(d / ".env").write_text(
    "﻿# AUDAX settings\n\n   # indented comment\nAUDAX_PROVIDER=foundry\n"
    "export AUDAX_MODEL = gpt-5-mini \nAZURE_OPENAI_API_KEY=\"abc=def\"\n"
    "AUDAX_BASE_URL='https://x.example/v1'\nAWS_SECRET_ACCESS_KEY=a/b+c==\nNO_EQUALS\n=nokey\n"
    "EMPTY=\nHALF=\"open\nAUDAX_API_VERSION=$HOME\r\nexport  SPACED=1\n", encoding="utf-8")
assert providers.load_env_file(d / ".env") == {
    "AUDAX_PROVIDER": "foundry", "AUDAX_MODEL": "gpt-5-mini", "AZURE_OPENAI_API_KEY": "abc=def",
    "AUDAX_BASE_URL": "https://x.example/v1", "AWS_SECRET_ACCESS_KEY": "a/b+c==", "EMPTY": "",
    "AUDAX_API_VERSION": "$HOME", "SPACED": "1"}  # HALF: no closing quote, ignored
# The grammar Swift's EnvFile shares (0.4.0 ruling), one rule per line.
(d / "grammar.env").write_bytes((
    "﻿BOM=1\r\n"  # a UTF-8 BOM, then CRLF
    "CR=2\rAFTER_CR=3\n"  # a bare CR ends a line too
    "export\tTABBED=4\n"
    "INLINE=plain value # a comment\n"
    "TABHASH=v\t# a comment after a tab\n"
    "HASHED=a#b\n"  # no blank before the "#": part of the value
    "DQ=\"kept # inside\"  # a comment\n"
    "SQ='x'#c\n"
    "KEEP=one\nKEEP=\"two\" junk\n"  # junk after the closing quote: the line is ignored
    "DUP=first\nDUP=last\n"
    "NOBREAK=1 x\x0cy\n"  # only \n, \r\n and \r end a line
    "export=5\n").encode("utf-8"))
assert providers.load_env_file(d / "grammar.env") == {
    "BOM": "1", "CR": "2", "AFTER_CR": "3", "TABBED": "4", "INLINE": "plain value",
    "TABHASH": "v", "HASHED": "a#b", "DQ": "kept # inside", "SQ": "x", "KEEP": "one",
    "DUP": "last", "NOBREAK": "1 x\x0cy", "export": "5"}, providers.load_env_file(
        d / "grammar.env")
assert providers.load_env_file(str(d / ".env"))["AUDAX_PROVIDER"] == "foundry"  # str or Path
assert providers.load_env_file(d / "missing.env") == {}
assert providers.load_env_file(d) == {}  # a directory
(d / "latin1.env").write_bytes(b"AUDAX_API_KEY=caf\xe9\n")
assert providers.load_env_file(d / "latin1.env") == {}  # not UTF-8: unreadable
(d / "locked.env").write_text("AUDAX_PROVIDER=claude\n")
os.chmod(d / "locked.env", 0)
assert providers.load_env_file(d / "locked.env") == {}  # no permission
os.chmod(d / "locked.env", 0o600)
assert providers.load_env_file(None) == {}  # never raises

# apply_env: generic keys, then the resulting provider's own keys; empty values never override.
base = {"provider": "ollama", "model": "gemma4", "api_key": "", "region": "eu-west-1"}
got = providers.apply_env(base, {
    "AUDAX_PROVIDER": "bedrock", "AUDAX_MODEL": "", "AWS_DEFAULT_REGION": "us-west-2",
    "AWS_REGION": "us-east-1", "AWS_BEARER_TOKEN_BEDROCK": "tok", "AWS_ACCESS_KEY_ID": "AK",
    "AWS_SECRET_ACCESS_KEY": "SK", "AWS_PROFILE": "p", "AZURE_OPENAI_API_KEY": "az",
    "OPENAI_API_KEY": "o", "ANTHROPIC_API_KEY": "a"})
assert got == {"provider": "bedrock", "model": "gemma4", "api_key": "tok", "region": "us-east-1",
               "aws_auth": "api_key"}, got  # bearer beats access keys and profile; AZURE_* ignored
assert base == {"provider": "ollama", "model": "gemma4", "api_key": "", "region": "eu-west-1"}
assert providers.apply_env({"provider": "bedrock", "aws_auth": "api_key"}, {
    "AWS_ACCESS_KEY_ID": "AK", "AWS_SECRET_ACCESS_KEY": "SK", "AWS_SESSION_TOKEN": "ST",
    "AWS_PROFILE": "p", "AWS_DEFAULT_REGION": "us-west-2", "AWS_BEARER_TOKEN_BEDROCK": ""}) == {
    "provider": "bedrock", "aws_auth": "access_key", "aws_access_key_id": "AK",
    "aws_secret_access_key": "SK", "aws_session_token": "ST", "region": "us-west-2"}
assert providers.apply_env({"provider": "bedrock", "aws_auth": "access_key"}, {
    "AWS_PROFILE": "work", "AWS_ACCESS_KEY_ID": ""}) == {
    "provider": "bedrock", "aws_auth": "profile", "aws_profile": "work"}
assert providers.apply_env({"provider": "bedrock"}, {
    "AZURE_OPENAI_API_KEY": "az", "OPENAI_API_KEY": "o"}) == {"provider": "bedrock"}
# AWS keys are one unit: a .env key never goes out with the settings' session token (a 403).
AWS_SET = {"provider": "bedrock", "model": "m", "region": "us-east-1", "aws_auth": "access_key",
           "aws_access_key_id": "AKSET", "aws_secret_access_key": "SKSET",
           "aws_session_token": "STSET"}
got = providers.apply_env(AWS_SET, {"AWS_ACCESS_KEY_ID": AK, "AWS_SECRET_ACCESS_KEY": SK})
assert got == {**AWS_SET, "aws_access_key_id": AK, "aws_secret_access_key": SK,
               "aws_session_token": ""}, got
h = providers.bedrock_request(got, "S", "U", now=NOW)[1]
assert "x-amz-security-token" not in h and "Credential=AKIDEXAMPLE/" in h["Authorization"]
got = providers.apply_env(AWS_SET, {"AWS_ACCESS_KEY_ID": AK})  # the settings' secret not used
assert got["aws_secret_access_key"] == "" and got["aws_session_token"] == "", got
try:
    providers.bedrock_request(got, "S", "U")
    assert False
except ValueError as e:
    assert str(e) == "bedrock: aws_secret_access_key is not set", e
assert providers.apply_env(AWS_SET, {"AWS_SESSION_TOKEN": "STENV"}) == AWS_SET  # alone: ignored
assert providers.apply_env({"provider": "bedrock", "aws_auth": "api_key"}, {
    "AWS_SESSION_TOKEN": "STENV"}) == {"provider": "bedrock", "aws_auth": "api_key"}
assert providers.apply_env({"provider": "openai", "api_key": "mine"}, {
    "AUDAX_PROVIDER": "foundry", "AUDAX_API_KEY": "generic", "AZURE_OPENAI_API_KEY": "az",
    "AZURE_OPENAI_ENDPOINT": "https://r.openai.azure.com", "AZURE_OPENAI_API_VERSION": "preview",
    "OPENAI_API_KEY": "o", "AWS_REGION": "us-east-1"}) == {
    "provider": "foundry", "api_key": "az", "base_url": "https://r.openai.azure.com",
    "api_version": "preview"}  # the provider's own key is applied after the generic one
assert providers.apply_env({"provider": "foundry"}, {"AUDAX_API_KEY": "generic"}) == {
    "provider": "foundry", "api_key": "generic"}
assert providers.apply_env({"provider": "openai"}, {
    "OPENAI_API_KEY": "o", "OPENAI_BASE_URL": "https://gw/v1"}) == {"provider": "openai",
                                                                     "api_key": "o"}
# Vendor keys go only to their vendor (2026-10-25 ruling): OPENAI_API_KEY to openai,
# ANTHROPIC_API_KEY to claude. The compatible gateways take AUDAX_API_KEY and AUDAX_BASE_URL;
# OPENAI_BASE_URL and ANTHROPIC_BASE_URL apply to no provider.
VENDOR = {"OPENAI_API_KEY": "o", "OPENAI_BASE_URL": "https://gw/v1", "ANTHROPIC_API_KEY": "a",
          "ANTHROPIC_BASE_URL": "https://gw"}
for p in ("openai_compatible", "anthropic_compatible"):
    gw_settings = {"provider": p, "api_key": "gw-key", "base_url": "https://mine/v1"}
    assert providers.apply_env(gw_settings, VENDOR) == gw_settings, p
    assert providers.apply_env({}, {**VENDOR, "AUDAX_PROVIDER": p}) == {"provider": p}, p
    assert providers.apply_env({}, {
        **VENDOR, "AUDAX_PROVIDER": p, "AUDAX_API_KEY": "g", "AUDAX_BASE_URL": "https://gw2/v1",
        "AUDAX_AUTH_HEADER": "x-api-key", "AUDAX_API_VERSION": "v1"}) == {
        "provider": p, "api_key": "g", "base_url": "https://gw2/v1", "auth_header": "x-api-key",
        "api_version": "v1"}, p
assert providers.apply_env({"provider": "claude"}, VENDOR) == {"provider": "claude",
                                                               "api_key": "a"}
assert providers.apply_env({"provider": "openai"}, VENDOR) == {"provider": "openai",
                                                               "api_key": "o"}
assert providers.apply_env({"provider": "ollama", "model": "m"}, {}) == {"provider": "ollama",
                                                                        "model": "m"}
for odd in (["x"], None, 5):  # a malformed provider: no override, and no exception
    assert providers.apply_env({"provider": odd}, {"OPENAI_API_KEY": "o"}) == {"provider": odd}
# A .env that switches provider drops the settings' provider fields: the old key is never sent.
SETTINGS = {"provider": "claude", "model": "m", "api_key": "sk-ant-SETTINGS", "region": "r",
            "base_url": "https://old", "auth_header": "bearer", "api_version": "1",
            "aws_auth": "access_key", "aws_access_key_id": "A", "aws_secret_access_key": "S",
            "aws_session_token": "T", "aws_profile": "p", "language": "en"}
assert providers.apply_env(SETTINGS, {"AUDAX_PROVIDER": "ollama"}) == {
    "provider": "ollama", "model": "m", "language": "en"}
assert providers.apply_env(SETTINGS, {"AUDAX_PROVIDER": "claude"}) == SETTINGS  # no switch
saved_post = providers.post_json
providers.post_json = raising(AssertionError("sent"))  # a request must not even be attempted
for env, p in (({"AUDAX_PROVIDER": "openai_compatible", "AUDAX_BASE_URL": "https://gw.example/v1",
                 "ANTHROPIC_API_KEY": "a"}, "openai_compatible"),
               ({"AUDAX_PROVIDER": "bedrock", "AWS_REGION": "us-east-1"}, "bedrock")):
    cfg = providers.apply_env(SETTINGS, env)
    try:
        providers.complete(cfg["provider"], cfg, "S", "U")
        raise AssertionError("no error")
    except ValueError as e:
        assert str(e) == p + ": api_key is not set", e
providers.post_json = saved_post

# auth_headers: three styles; empty or unknown gives the provider's default.
assert providers.auth_headers("bearer", "k") == {"Authorization": "Bearer k"}
assert providers.auth_headers("api-key", "k") == {"api-key": "k"}
assert providers.auth_headers("x-api-key", "k") == {"x-api-key": "k"}
assert providers.auth_headers(" X-API-KEY ", "k") == {"x-api-key": "k"}
assert providers.auth_headers("", "k") == {"Authorization": "Bearer k"}
assert providers.auth_headers("cookie", "k", "api-key") == {"api-key": "k"}

# Builders: URL, headers and body, field by field.
gw = {"model": "llama-3", "api_key": " k ", "base_url": "https://gw.example/v1/"}
url, h, b = providers.openai_compatible_request(gw, "SYS", "USR")
assert url == "https://gw.example/v1/chat/completions"
assert h == {"content-type": "application/json", "User-Agent": UA, "Authorization": "Bearer k"}
assert b == {"model": "llama-3", "messages": CHAT}  # no temperature: reasoning models refuse it
url, h, b = providers.openai_compatible_request(
    {**gw, "api_version": "2025-04-01-preview", "auth_header": "api-key"}, "SYS", "USR")
assert url == "https://gw.example/v1/chat/completions?api-version=2025-04-01-preview"
assert h["api-key"] == "k" and "Authorization" not in h
fo = {"model": "gpt-5-mini", "api_key": "k", "base_url": "https://r.openai.azure.com/openai/v1"}
url, h, b = providers.foundry_request(fo, "SYS", "USR")
assert url == "https://r.openai.azure.com/openai/v1/chat/completions"
assert h == {"content-type": "application/json", "User-Agent": UA, "api-key": "k"}
assert b == {"model": "gpt-5-mini", "messages": CHAT}
assert providers.foundry_request({**fo, "base_url": "https://r.openai.azure.com/"}, "S", "U")[
    0] == "https://r.openai.azure.com/openai/v1/chat/completions"  # AZURE_OPENAI_ENDPOINT's root
h = providers.foundry_request({**fo, "auth_header": "bearer"}, "S", "U")[1]
assert h["Authorization"] == "Bearer k" and "api-key" not in h
ac = {"model": "claude-sonnet-4-5", "api_key": "k",
      "base_url": "https://r.services.ai.azure.com/anthropic"}
url, h, b = providers.anthropic_compatible_request(ac, "SYS", "USR")
assert url == "https://r.services.ai.azure.com/anthropic/v1/messages"
assert h == {"content-type": "application/json", "User-Agent": UA, "x-api-key": "k",
             "anthropic-version": "2023-06-01"}
assert b == {"model": "claude-sonnet-4-5", "max_tokens": 2048, "system": "SYS",
             "messages": [{"role": "user", "content": "USR"}]}  # no betas, no output_config
url, h, _ = providers.anthropic_compatible_request({**ac, "auth_header": "bearer",
                                                    "api_version": "2023-06-01"}, "S", "U")
assert url.endswith("/anthropic/v1/messages?api-version=2023-06-01")
assert h["Authorization"] == "Bearer k" and "x-api-key" not in h
# A whole endpoint pasted as base_url (an Azure Target URI): its path is not added twice, its
# query is kept, and api_version replaces the query's api-version (never two).
TARGET = ("https://r.openai.azure.com/openai/deployments/gpt-4o/chat/completions"
          "?api-version=2024-10-21")
assert providers.foundry_request({**fo, "base_url": TARGET}, "S", "U")[0] == TARGET
assert providers.openai_compatible_request({**gw, "base_url": TARGET}, "S", "U")[0] == TARGET
assert providers.foundry_request(
    {**fo, "base_url": TARGET + "&x=1", "api_version": "2025-01-01-preview"}, "S", "U")[0] == (
    "https://r.openai.azure.com/openai/deployments/gpt-4o/chat/completions"
    "?x=1&api-version=2025-01-01-preview")
assert providers.openai_compatible_request(
    {**gw, "base_url": "https://gw.example/v1/?team=a"}, "S", "U")[0] == (
    "https://gw.example/v1/chat/completions?team=a")
assert providers.openai_compatible_request(
    {**gw, "base_url": "https://gw.example/v1/chat/completions?api-version=a&api-version=b"},
    "S", "U")[0] == "https://gw.example/v1/chat/completions?api-version=b"
ANT = "https://r.services.ai.azure.com/anthropic/v1/messages?api-version=2023-06-01"
assert providers.anthropic_compatible_request({**ac, "base_url": ANT}, "S", "U")[0] == ANT
assert providers.anthropic_compatible_request(
    {**ac, "base_url": ANT, "api_version": "2024-02-02"}, "S", "U")[0] == (
    "https://r.services.ai.azure.com/anthropic/v1/messages?api-version=2024-02-02")
assert providers.anthropic_compatible_request(
    {**ac, "base_url": "https://gw.example/v1/messages/"}, "S", "U")[0] == (
    "https://gw.example/v1/messages")
cfg = providers.apply_env({"provider": "foundry", "model": "m"}, {  # the same through the .env
    "AZURE_OPENAI_ENDPOINT": TARGET, "AZURE_OPENAI_API_KEY": "k",
    "AZURE_OPENAI_API_VERSION": "2025-01-01-preview"})
assert providers.foundry_request(cfg, "S", "U")[0] == TARGET.replace("2024-10-21",
                                                                     "2025-01-01-preview")
br = {"model": "anthropic.claude-test-v1:0", "region": "us-east-1", "api_key": "tok",
      "aws_auth": "api_key"}
url, h, b = providers.bedrock_request(br, "SYS", "USR")
assert url == ("https://bedrock-runtime.us-east-1.amazonaws.com/model/"
               "anthropic.claude-test-v1%3A0/converse")
assert h == {"content-type": "application/json", "User-Agent": UA, "Authorization": "Bearer tok"}
assert b == {"system": [{"text": "SYS"}],
             "messages": [{"role": "user", "content": [{"text": "USR"}]}],
             "inferenceConfig": {"maxTokens": 2048}}  # no temperature: Claude refuses sampling
assert providers.bedrock_request({**br, "aws_auth": ""}, "S", "U")[1]["Authorization"] == (
    "Bearer tok")  # no auth method chosen: the API key
arn = "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-test-v1:0"
assert providers.bedrock_request({**br, "model": arn}, "S", "U")[0] == (
    "https://bedrock-runtime.us-east-1.amazonaws.com/model/arn%3Aaws%3Abedrock%3Aus-east-1%3A"
    "123456789012%3Ainference-profile%2Fus.anthropic.claude-test-v1%3A0/converse")

# Missing required fields: ValueError("<provider>: <field> is not set"); nothing else is sent.
for build, cfg, field in [
        (providers.openai_compatible_request, {"model": "m", "api_key": "k"}, "base_url"),
        (providers.openai_compatible_request, {"base_url": "https://x", "api_key": "k"}, "model"),
        (providers.openai_compatible_request, {"base_url": "https://x", "model": "m"}, "api_key"),
        (providers.foundry_request, {"model": "m", "base_url": "https://x"}, "api_key"),
        (providers.anthropic_compatible_request, {"model": "m", "base_url": "https://x"},
         "api_key"),
        (providers.bedrock_request, {"region": "us-east-1", "api_key": "k"}, "model"),
        (providers.bedrock_request, {"model": "m", "api_key": "k"}, "region"),
        (providers.bedrock_request, {"model": "m", "region": "us-east-1"}, "api_key"),
        (providers.bedrock_request, {"model": "m", "region": "us-east-1", "aws_auth": "access_key",
                                     "aws_access_key_id": AK}, "aws_secret_access_key"),
        (providers.bedrock_request, {"model": "m", "region": "us-east-1", "aws_auth": "access_key",
                                     "aws_secret_access_key": SK}, "aws_access_key_id")]:
    name = build.__name__[:-len("_request")]
    try:
        build(cfg, "S", "U")
        assert False, (name, field)
    except ValueError as e:
        assert str(e) == name + ": " + field + " is not set", (str(e), field)
for build, cfg in [(providers.openai_compatible_request, {**gw, "base_url": "file:///etc/hosts"}),
                   (providers.foundry_request, {**fo, "base_url": "r.openai.azure.com"}),
                   (providers.bedrock_request, {**br, "region": "evil.example/x?"}),
                   (providers.bedrock_request, {**br, "aws_auth": "sso"})]:
    try:
        build(cfg, "S", "U")
        assert False, cfg
    except ValueError as e:
        assert "is not valid" in str(e) or "must start with" in str(e), e
for build, cfg in [(providers.foundry_request, {**fo, "api_key": "sk-SECRET\nx"}),
                   (providers.bedrock_request, {**br, "api_key": "SECRET—x"}),
                   (providers.bedrock_request, {**br, "aws_auth": "access_key",
                                                "aws_access_key_id": "AK", "aws_secret_access_key":
                                                "SK", "aws_session_token": "SECRET\nx"})]:
    try:  # http.client would quote a header value it cannot send: refused first, not quoted
        build(cfg, "S", "U")
        assert False
    except ValueError as e:
        assert "SECRET" not in repr(e), e

# SigV4 against the AWS documentation example (IAM ListUsers, GET, empty body).
doc = providers.sigv4_sign(
    "GET", "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08", b"",
    "application/x-www-form-urlencoded; charset=utf-8", "20150830T123600Z",
    region="us-east-1", service="iam", access_key=AK, secret_key=SK)
assert doc == {"Authorization": "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/"
               "aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature="
               "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7",
               "x-amz-date": "20150830T123600Z"}, doc
assert providers.sigv4_sign(  # the canonical query string is sorted
    "GET", "https://iam.amazonaws.com/?Version=2010-05-08&Action=ListUsers", b"",
    "application/x-www-form-urlencoded; charset=utf-8", "20150830T123600Z",
    region="us-east-1", service="iam", access_key=AK, secret_key=SK) == doc
# Known answers from curl 8.7.1 --aws-sigv4 "aws:amz:us-east-1:bedrock" (24 Oct 2026, a local
# recorder, no AWS): POST, JSON body, Host with a port, with and without a session token. The
# path has no "%", so encoding it once (curl 8.7.1) or twice (AWS's rule for non-S3) agree.
CURL_BODY = (b'{"system": [{"text": "S"}], "messages": [{"role": "user", "content": [{"text": '
             b'"U"}]}], "inferenceConfig": {"maxTokens": 2048}}')
for token, signature in (
        ("", "6b561fd695a2e207a042d103c6834ac8112a6309228fb87dfebd0876c4c8f5b8"),
        ("FQoGZXIvYXdzEXAMPLETOKEN",
         "939264e030fdb895b22ce7c96d01620dcb4faffe477abb8a59cf8b3b87a9de32")):
    got = providers.sigv4_sign(
        "POST", "http://127.0.0.1:60905/model/anthropic.claude-test-v1/converse" if not token
        else "http://127.0.0.1:60907/model/anthropic.claude-test-v1/converse", CURL_BODY,
        "application/json", "20261024T071411Z", region="us-east-1", service="bedrock",
        access_key=AK, secret_key=SK, session_token=token)
    assert got["Authorization"].endswith("Signature=" + signature), (token, got)
# A model id's ":" is %3A in the URL and %253A in the canonical request (the spec; curl 8.7.1
# signs it once, so it disagrees here and only here; see the task-6 report).
assert providers.canonical_uri("/model/anthropic.claude-test-v1%3A0/converse") == (
    "/model/anthropic.claude-test-v1%253A0/converse")
# Known answer from aws-cli 2.36.19 (botocore) "bedrock-runtime converse --endpoint-url" against
# a local recorder (25 Oct 2026, these dummy keys, no AWS): the request line, Host, X-Amz-Date,
# body and Authorization as captured. A single-encoded %3A gives a different signature.
AWSCLI_BODY = (b'{"messages": [{"role": "user", "content": [{"text": "U"}]}], "system": '
               b'[{"text": "S"}], "inferenceConfig": {"maxTokens": 2048}}')
got = providers.sigv4_sign(
    "POST", "http://127.0.0.1:56138/model/anthropic.claude-test-v1%3A0/converse", AWSCLI_BODY,
    "application/json", "20261025T092039Z", region="us-east-1", service="bedrock",
    access_key=AK, secret_key=SK)
assert got["Authorization"] == (
    "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261025/us-east-1/bedrock/aws4_request, "
    "SignedHeaders=content-type;host;x-amz-date, Signature="
    "cfdd5615e0e451ed837622257ae6b4b935d33b669e6f1325641eb3bbbc9cacbe"), got
assert providers.canonical_uri("") == "/" and providers.canonical_uri("/") == "/"

# Bedrock signed with an access key; sigv4_headers takes now as UTC (naive = UTC).
sig = {**br, "api_key": "", "aws_auth": "access_key", "aws_access_key_id": AK,
       "aws_secret_access_key": SK}
url, h, b = providers.bedrock_request(sig, "S", "U", now=NOW)
assert set(h) == {"content-type", "User-Agent", "Authorization", "x-amz-date"}, h
assert h["x-amz-date"] == "20261024T120000Z" and h["content-type"] == "application/json"
assert h["Authorization"].startswith(
    "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261024/us-east-1/bedrock/aws4_request, "
    "SignedHeaders=content-type;host;x-amz-date, Signature=")
assert h["Authorization"] == providers.sigv4_headers(
    "POST", url, json.dumps(b).encode(), "us-east-1", "bedrock", access_key=AK, secret_key=SK,
    now=NOW)["Authorization"]
assert SK not in str(h)
for when in (NOW.replace(tzinfo=None),
             NOW.astimezone(datetime.timezone(datetime.timedelta(hours=2)))):
    assert providers.bedrock_request(sig, "S", "U", now=when)[1] == h
assert providers.bedrock_request(sig, "S", "V", now=NOW)[1]["Authorization"] != h[
    "Authorization"]  # the body is signed
url, h, b = providers.bedrock_request({**sig, "aws_session_token": "ST"}, "S", "U", now=NOW)
assert h["x-amz-security-token"] == "ST"
assert "SignedHeaders=content-type;host;x-amz-date;x-amz-security-token," in h["Authorization"]
now_h = providers.bedrock_request(sig, "S", "U")[1]  # now=None: the clock, in UTC
stamp = datetime.datetime.strptime(now_h["x-amz-date"], "%Y%m%dT%H%M%SZ").replace(tzinfo=UTC)
assert abs((datetime.datetime.now(UTC) - stamp).total_seconds()) < 60

# The bytes post_json sends are the bytes that were signed.
captured = {}


def capture(req, timeout):
    captured.update(req=req, timeout=timeout)
    return io.BytesIO(b'{"output": {"message": {"content": [{"text": "ok"}]}}}')


urllib.request.urlopen = capture
url, h, b = providers.bedrock_request({**sig, "aws_session_token": "ST"}, "S", "Grüße",
                                      now=NOW)
assert REAL_POST_JSON(url, h, b, 20) == {"output": {"message": {"content": [{"text": "ok"}]}}}
req = captured["req"]
assert req.full_url == url and req.host == "bedrock-runtime.us-east-1.amazonaws.com"
assert req.get_header("Authorization") == h["Authorization"] == providers.sigv4_headers(
    "POST", req.full_url, req.data, "us-east-1", "bedrock", access_key=AK, secret_key=SK,
    session_token="ST", now=NOW)["Authorization"]
assert req.get_header("Content-type") == "application/json"
assert req.get_header("X-amz-date") == "20261024T120000Z"
assert req.get_header("X-amz-security-token") == "ST"
urllib.request.urlopen = real_urlopen

# aws_profile_credentials: a temp HOME, never the real ~/.aws.
home = Path(tempfile.mkdtemp())
(home / ".aws").mkdir()
(home / ".aws/credentials").write_text(
    "[default]\naws_access_key_id = AKDEF\naws_secret_access_key = SKDEF\n\n"
    "[work]\naws_access_key_id=AKW\naws_secret_access_key=SK%W\naws_session_token=STW\n")
(home / ".aws/config").write_text(
    "[default]\nregion = eu-central-1\n\n[profile work]\nregion = us-west-2\n"
    "aws_access_key_id = AKCONFIG\n\n"  # the credentials file's key wins over this one
    "[profile sso]\nsso_session = corp\nsso_account_id = 1\nregion = us-east-1\n\n"
    "[profile legacy-sso]\nsso_start_url = https://x.awsapps.com/start\n\n"
    "[profile cfgkeys]\naws_access_key_id = AKC\naws_secret_access_key = SKC\n"
    "region = ap-south-1\n\n[profile role]\nrole_arn = arn:aws:iam::1:role/r\n"
    "source_profile = default\n\n[sso-session corp]\nsso_region = us-east-1\n")
assert providers.aws_profile_credentials("work", home=home) == ("AKW", "SK%W", "STW", "us-west-2")
assert providers.aws_profile_credentials("default", home=home) == ("AKDEF", "SKDEF", "",
                                                                   "eu-central-1")
assert providers.aws_profile_credentials("", home=home)[0] == "AKDEF"  # no name: default
assert providers.aws_profile_credentials("cfgkeys", home=home) == ("AKC", "SKC", "", "ap-south-1")
for name, message in [
        ("missing", "bedrock: AWS profile missing not found"),
        ("sso", "bedrock: SSO profiles are not supported - use an access key or a Bedrock API key"),
        ("legacy-sso",
         "bedrock: SSO profiles are not supported - use an access key or a Bedrock API key"),
        ("role", "bedrock: AWS profile role has no access key - use an access key or a Bedrock "
                 "API key")]:
    try:
        providers.aws_profile_credentials(name, home=home)
        assert False, name
    except RuntimeError as e:
        assert str(e) == message, e
bare, broken = Path(tempfile.mkdtemp()), Path(tempfile.mkdtemp())
(broken / ".aws").mkdir()
(broken / ".aws/credentials").write_text("aws_secret_access_key = SECRETLINE\n")  # no [section]
for where, words in ((bare, "not found"), (broken, "cannot read")):
    try:
        providers.aws_profile_credentials("default", home=where)
        assert False, where
    except RuntimeError as e:
        assert words in str(e) and "SECRETLINE" not in repr(e), e
(broken / ".aws/credentials").write_bytes(b"[default]\naws_secret_access_key = SECRET\xff\n")
try:  # not UTF-8: UnicodeDecodeError's repr would carry the file's bytes
    providers.aws_profile_credentials("default", home=broken)
    assert False
except RuntimeError as e:
    assert "SECRET" not in repr(e) and "cannot read" in str(e), e
real_profile = providers.aws_profile_credentials  # bedrock_request reads the profile at call time
aws_home = home  # the temp one, bound here so the stand-in can never fall back to ~/.aws
providers.aws_profile_credentials = lambda name, **_: real_profile(name, home=aws_home)
prof = {"model": "m", "aws_auth": "profile", "aws_profile": "work"}
url, h, b = providers.bedrock_request(prof, "S", "U", now=NOW)
assert url.startswith("https://bedrock-runtime.us-west-2.amazonaws.com/")  # the profile's region
assert "Credential=AKW/20261024/us-west-2/bedrock/aws4_request" in h["Authorization"]
assert h["x-amz-security-token"] == "STW"
assert providers.bedrock_request({**prof, "region": "eu-west-1"}, "S", "U", now=NOW)[0].startswith(
    "https://bedrock-runtime.eu-west-1.")  # a region in the settings wins
assert "Credential=AKDEF/" in providers.bedrock_request({**prof, "aws_profile": ""}, "S", "U",
                                                        now=NOW)[1]["Authorization"]
try:
    providers.bedrock_request({**prof, "aws_profile": "sso"}, "S", "U")
    assert False
except RuntimeError as e:
    assert "SSO profiles are not supported" in str(e)
providers.aws_profile_credentials = real_profile

# extract_text: the three new reply shapes, including empty content.
assert providers.extract_text("foundry", {"choices": [{"message": {"content": "F"}}]}) == "F"
assert providers.extract_text("openai_compatible", {"choices": [{"message": {"content": ""}}]}
                              ) == ""
assert providers.extract_text("anthropic_compatible", {"content": [
    {"type": "thinking", "thinking": "x"}, {"type": "text", "text": "A"},
    {"type": "text", "text": "B"}]}) == "AB"
assert providers.extract_text("anthropic_compatible", {"content": []}) == ""
assert providers.extract_text("bedrock", {"output": {"message": {"role": "assistant", "content": [
    {"reasoningContent": {"reasoningText": {"text": "hmm"}}}, {"text": "C"}, {"text": "D"}]}},
    "stopReason": "end_turn"}) == "CD"
assert providers.extract_text("bedrock", {"output": {"message": {"content": []}}}) == ""

# complete dispatches the new ids, 20 s timeout; a missing field is raised before any request.
sent = []


def replying(reply):
    def post(url, headers, body, timeout):
        sent.append((url, headers, body, timeout))
        return reply
    return post


OPENAI_REPLY = {"choices": [{"message": {"content": "hi"}}]}
for provider, cfg, reply, want in [
        ("openai_compatible", {"model": "m", "api_key": KEY, "base_url": "https://gw.example/v1"},
         OPENAI_REPLY, "https://gw.example/v1/chat/completions"),
        ("foundry", {**fo, "api_version": "preview"}, OPENAI_REPLY,
         "https://r.openai.azure.com/openai/v1/chat/completions?api-version=preview"),
        ("anthropic_compatible", ac, {"content": [{"type": "text", "text": "hi"}]},
         "https://r.services.ai.azure.com/anthropic/v1/messages"),
        ("bedrock", {**br, "model": "m:0"}, {"output": {"message": {"content": [{"text": "hi"}]}}},
         "https://bedrock-runtime.us-east-1.amazonaws.com/model/m%3A0/converse")]:
    providers.post_json = replying(reply)
    assert providers.complete(provider, cfg, "S", "U") == "hi", provider
    assert sent[-1][0] == want and sent[-1][3] == 20, sent[-1]
providers.post_json = raising(AssertionError("sent without a required field"))
for provider in ("bedrock", "foundry", "openai_compatible", "anthropic_compatible"):
    try:
        providers.complete(provider, {}, "S", "U")
        assert False
    except ValueError as e:
        assert str(e).startswith(provider + ": ") and str(e).endswith(" is not set"), e

# --test CLI for Settings' "Test connection": one JSON line, exit 0, never the key.


def run_test_cli(stdin_text):
    sys.stdin = io.StringIO(stdin_text)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        assert providers.main(["--test"]) == 0
    assert err.getvalue() == "" and len(out.getvalue().splitlines()) == 1, (out.getvalue(), err)
    assert out.getvalue().endswith("\n") and KEY not in out.getvalue(), out.getvalue()
    return json.loads(out.getvalue())


GW = json.dumps({"provider": "openai_compatible", "model": "m", "api_key": KEY,
                 "base_url": "https://gw.example/v1", "language": "en"})
providers.post_json = replying({"choices": [{"message": {"content": "OK"}}]})
got = run_test_cli(GW)
assert set(got) == {"ok", "ms"} and got["ok"] is True and isinstance(got["ms"], int), got
assert got["ms"] >= 0
assert sent[-1][2]["messages"] == [{"role": "system", "content": "Reply with the single word OK."},
                                   {"role": "user", "content": "OK?"}] and sent[-1][3] == 20
providers.post_json = http_error(401)
assert run_test_cli(GW) == {"ok": False, "error": "<HTTPError 401: 'x'>"}
providers.post_json = raising(OSError("refused for " + KEY))  # an error that quotes the key
got = run_test_cli(GW)
assert got["ok"] is False and "<redacted>" in got["error"], got
# A placeholder under 4 characters is no secret: replacing it would garble the error text.
for short in ("1", "x", " 40 ", "abc"):
    assert providers.redact("HTTP 401 for abc", {"api_key": short}) == "HTTP 401 for abc", short
assert providers.redact("HTTP 401 for abcd", {"api_key": " abcd "}) == "HTTP 401 for <redacted>"
assert run_test_cli(json.dumps({"provider": "foundry"})) == {
    "ok": False, "error": "ValueError('foundry: base_url is not set')"}
for bad in ("not json", ""):
    assert run_test_cli(bad)["ok"] is False, bad
for bad in ("[1]", '[["provider", "openai_compatible"]]'):
    assert run_test_cli(bad) == {"ok": False,
                                 "error": "ValueError('settings are not a JSON object')"}, bad
providers.ENV_FILE.write_text("AUDAX_PROVIDER=foundry\nAZURE_OPENAI_ENDPOINT=https://r.openai."
                              "azure.com\nAZURE_OPENAI_API_KEY=" + KEY + "\nAUDAX_MODEL=gpt-5\n")
providers.post_json = replying(OPENAI_REPLY)
assert run_test_cli(json.dumps({"provider": "ollama", "model": "gemma4"}))["ok"] is True
assert sent[-1][0] == "https://r.openai.azure.com/openai/v1/chat/completions"  # .env applied
assert sent[-1][1]["api-key"] == KEY and sent[-1][2]["model"] == "gpt-5"
providers.post_json = raising(OSError("refused for " + KEY))  # a key that came from the .env
assert "<redacted>" in run_test_cli(json.dumps({"provider": "ollama"}))["error"]
providers.ENV_FILE = Path(tempfile.mkdtemp()) / ".env"
sys.stdin = sys.__stdin__
assert dict(os.environ) == ENVIRON  # nothing above put a secret (or anything) in the environment

print("ok")

