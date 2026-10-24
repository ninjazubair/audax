"""Run: /usr/bin/python3 test_providers.py"""
import contextlib
import io
import json
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
assert err.getvalue().splitlines() == ["usage: providers.py --copilot-models"] * 2 + [
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
for code, stale in ((403, True), (401, True), (404, True), (500, False)):
    providers.write_host_cache(providers.HOST_CACHE, BIZ)
    providers.post_json = http_error(code)
    try:
        providers.complete("copilot", {"model": "m"}, "S", "U")
        assert False
    except urllib.error.HTTPError as e:
        assert e.code == code
    saved = json.loads(providers.HOST_CACHE.read_text())
    assert saved["api"] == BIZ, (code, saved)
    assert saved["at"] == 0 if stale else saved["at"] > 0, (code, saved)

print("ok")
