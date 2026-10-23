"""Run: /usr/bin/python3 test_providers.py"""
import io
import json
import urllib.error
import urllib.request

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
    seen.update(url=req.full_url, method=req.get_method(), body=json.loads(req.data),
                ua=req.get_header("User-agent"), key=req.get_header("X-api-key"), timeout=timeout)
    return io.BytesIO(b'{"ok": 1}')


real_urlopen = urllib.request.urlopen
urllib.request.urlopen = fake_urlopen
assert providers.post_json("http://x/y", {"x-api-key": "k"}, {"q": 1}, 7) == {"ok": 1}
assert seen == {"url": "http://x/y", "method": "POST", "body": {"q": 1}, "ua": UA, "key": "k",
                "timeout": 7}
urllib.request.urlopen = real_urlopen

try:
    providers.complete("copilot", {"model": "m"}, "S", "U")
    assert False
except RuntimeError as e:
    assert "Task 6" in str(e)

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

print("ok")
