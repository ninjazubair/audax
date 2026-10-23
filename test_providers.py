"""Run: /usr/bin/python3 test_providers.py"""
import io
import json
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

import providers

UA = "AUDAX/0.2.0"

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
BIZ = "https://api.business.githubcopilot.com"
assert providers.gh_token(run=lambda *a, **k: type(
    "R", (), {"stdout": " gho_x \n", "returncode": 0})()) == "gho_x"
assert providers.gh_token(run=lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError())) == ""
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
    assert "not signed in" in str(e)
providers.gh_token = lambda: "gho_t"
providers.copilot_api_host = lambda token: "https://api.business.githubcopilot.com"
sent = []
providers.post_json = lambda url, headers, body, timeout: (
    sent.append((url, headers["Authorization"], timeout))
    or {"choices": [{"message": {"content": "hi"}}]})
mine = {"model": "gpt-4.1"}
assert providers.complete("copilot", mine, "S", "U") == "hi"
assert sent == [("https://api.business.githubcopilot.com/chat/completions", "Bearer gho_t", 20)]
assert mine == {"model": "gpt-4.1"}  # the caller's dict never gets the token

print("ok")
