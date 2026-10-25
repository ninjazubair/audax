"""Run: /usr/bin/python3 test_dictate.py"""
import contextlib
import email
import http.client
import http.server
import io
import json
import os
import socket
import sys
import tempfile
import threading
import urllib.error
from pathlib import Path

import dictate

dictate.LOG = Path(tempfile.mkdtemp()) / "test.log"  # keep the real log clean
dictate.USER_SUBS = Path(tempfile.mkdtemp()) / "word_subs.json"  # never the user's real file
dictate.providers.ENV_FILE = Path(tempfile.mkdtemp()) / ".env"  # never the user's real .env

assert dictate.apply_subs("Check Work Front and real time CDP", {
    "work front": "Workfront", "real time cdp": "RTCDP"}) == "Check Workfront and RTCDP"
assert dictate.apply_subs("network frontier", {"work front": "Workfront"}) == "network frontier"
assert dictate.apply_subs("the real-time CDP project", {
    "real time cdp": "RTCDP"}) == "the RTCDP project"

assert dictate.parse_whisper(" Hello there.\n How are you?\n") == "Hello there. How are you?"
assert dictate.parse_whisper(" [BLANK_AUDIO]\n") == ""
assert dictate.parse_whisper(" [Music]\n *gunshot*\n (coughing)\n") == ""
assert dictate.parse_whisper(" Send it (today) please.\n") == "Send it (today) please."
assert dictate.apply_subs("use the path", {"the path": "C:\\temp"}) == "use C:\\temp"

assert dictate.has_words("You")
assert not dictate.has_words(" . ")  # whisper's output on faint noise
assert not dictate.has_words("")

assert dictate.accept("send it at five", "Send it at 5.") == "Send it at 5."
assert dictate.accept("what is AEP", "AEP is Adobe Experience Platform, a real-time "
                      "customer data platform that unifies profiles.") == "what is AEP"
assert dictate.accept("hello", "") == "hello"

assert dictate.read_config(io.StringIO("")) == dictate.DEFAULT_CONFIG
assert dictate.read_config(io.StringIO(
    '{"language": "de", "cleanup": "light"}'))["language"] == "de"
assert dictate.read_config(io.StringIO("not json"))["provider"] == "ollama"
assert "German" in dictate.prompt_for("de", "full")
assert "never translate" in dictate.prompt_for("de", "full")
assert "grammar" in dictate.prompt_for("en", "full")
assert "grammar" not in dictate.prompt_for("en", "light")
assert "ähm" in dictate.prompt_for("de", "light")
off = dictate.cleanup("hello", {**dictate.DEFAULT_CONFIG, "cleanup": "off"})
assert off[:2] == ("hello", "off")
down = dictate.cleanup("um hello", {**dictate.DEFAULT_CONFIG, "url": "http://127.0.0.1:9/x"})
assert down[:2] == ("um hello", "skipped") and down[2]  # Ollama down: raw text, error kept
assert dictate.apply_subs("der käse ist gut", {"käse": "Käse"}) == "der Käse ist gut"  # umlauts
assert dictate.has_words("Äpfel")
assert dictate.accept("one two three four five six seven eight",  # model dropped content
                      "one two") == "one two three four five six seven eight"
assert dictate.accept("um uh so like you know I think", "I think.") == "I think."  # fillers
assert dictate.accept("meet at five no wait actually five thirty",  # self-correction
                      "Meet at 5:30.") == "Meet at 5:30."
# 11 words, 6 of them content once the German fillers (ähm, also, halt, äh, sozusagen) are out:
# 2 cleaned words is a third of 6, so German accepts; English counts all 11 and rejects.
german = "ähm also ich halt äh wollte sozusagen fragen ob wir verschieben"
assert dictate.accept(german, "Wir verschieben.", "de") == "Wir verschieben."
assert dictate.accept(german, "Wir verschieben.", "en") == german

real_ask_model = dictate.ask_model  # fake model answers, no network
dictate.ask_model = lambda cfg, system, user: "<dictation>I think.</dictation>"
assert dictate.cleanup("um uh I think", dict(dictate.DEFAULT_CONFIG)) == ("I think.", "ok", None)
dictate.ask_model = lambda cfg, system, user: "one two"
eight = "one two three four five six seven eight"
assert dictate.cleanup(eight, dict(dictate.DEFAULT_CONFIG)) == (
    eight, "skipped", "rejected: dropped content")
dictate.ask_model = lambda cfg, system, user: "Sure! Here is what I think about that. " * 3
assert dictate.cleanup("what is AEP", dict(dictate.DEFAULT_CONFIG)) == (
    "what is AEP", "skipped", "rejected: too long")
dictate.ask_model = real_ask_model

assert dictate.load_subs()["work front"] == "Workfront"  # no user file yet: bundled only
assert not dictate.LOG.exists()  # a missing user file is normal, never logged
dictate.USER_SUBS.write_text('{"audacks": "AUDAX", "work front": "WF"}')
subs = dictate.load_subs()
assert subs["audacks"] == "AUDAX" and subs["work front"] == "WF"  # user wins over bundled
dictate.USER_SUBS.write_text('{"Work  Front": "WF"}')  # user wins in any case or spacing
assert dictate.apply_subs("the work front update", dictate.load_subs()) == "the WF update"
dictate.USER_SUBS.write_text("{broken")
assert dictate.load_subs()["work front"] == "Workfront"  # malformed: bundled still applies
assert dictate.LOG.read_text().count('"warning": "word_subs.json ignored: invalid JSON"') == 1
dictate.USER_SUBS.write_text('["audacks", "AUDAX"]')
assert "audacks" not in dictate.load_subs()
assert dictate.LOG.read_text().count("word_subs.json ignored: not an object") == 1

dictate.USER_SUBS.write_text('{"audacks": "AUDAX"}')
real_transcribe = dictate.transcribe  # a model must not undo a correction
urls = []
dictate.transcribe = lambda wav, vocab, language, url: urls.append(url) or (
    "send the work front update", "server")
dictate.ask_model = lambda cfg, system, user: "<dictation>Send the work front update.</dictation>"
result = dictate.process(Path("x.wav"), {**dictate.DEFAULT_CONFIG, "cleanup": "full",
                                         "whisper_path": "/audax-x"})
assert result["final"] == "Send the Workfront update." and result["cleanup"] == "ok"
assert result["stt"] == "server"  # which speech-to-text path ran, for the log
assert urls == ["http://127.0.0.1:18777/audax-x/inference"]  # the app's per-launch path
dictate.USER_SUBS.write_text('{"firefly": "Adobe Firefly"}')  # replacement holds its own key
dictate.transcribe = lambda wav, vocab, language, url: ("open firefly now", "cli")
dictate.ask_model = lambda cfg, system, user: user  # echoes the <dictation> text unchanged
result = dictate.process(Path("x.wav"), {**dictate.DEFAULT_CONFIG, "cleanup": "full"})
assert result["final"] == "open Adobe Firefly now"  # applied once, never "Adobe Adobe Firefly"
dictate.transcribe, dictate.ask_model = real_transcribe, real_ask_model

assert dictate.read_config(None) == dictate.DEFAULT_CONFIG  # a broken stdin object: defaults
cfg = dictate.read_config(io.StringIO('{"language": "fr", "cleanup": "on"}'))
assert cfg["language"] == "en" and cfg["cleanup"] == "full"
assert dictate.read_config(io.StringIO('{"whisper_path": 7}'))["whisper_path"] == ""
assert dictate.read_config(io.StringIO('{"whisper_path": "/a"}'))["whisper_path"] == "/a"


def boom_fn(provider, cfg, system, user, timeout=20):
    raise urllib.error.HTTPError("https://api.anthropic.com/v1/messages", 401, "Unauthorized",
                                 {}, io.BytesIO(b""))


real_complete = dictate.providers.complete  # test_cleanup_skipped_on_provider_error
dictate.providers.complete = boom_fn
claude = {**dictate.DEFAULT_CONFIG, "provider": "claude", "api_key": "k"}
skipped = dictate.cleanup("um hello", claude)
assert skipped[:2] == ("um hello", "skipped") and "401" in skipped[2]
dictate.providers.complete = real_complete

real_post = dictate.providers.post_json  # malformed replies and transport errors: skipped


def reply_with(value):
    def fake(url, headers, body, timeout):
        if isinstance(value, Exception):
            raise value
        return value
    return fake


for provider, reply in [("ollama", []), ("ollama", {}), ("ollama", {"message": None}),
                        ("ollama", {"message": {"content": None}}), ("openai", {"choices": []}),
                        ("claude", {"content": "oops"}),
                        ("claude", {"content": [{"type": "text", "text": 5}]}),
                        ("claude", http.client.IncompleteRead(b"")),
                        ("openai", ValueError("Expecting value"))]:
    dictate.providers.post_json = reply_with(reply)
    got = dictate.cleanup("um hello", {**claude, "provider": provider})
    assert got[:2] == ("um hello", "skipped") and got[2], (provider, reply, got)

real_gh = dictate.providers.gh_token  # copilot, not signed in to GitHub: raw text, not exit 1
dictate.providers.gh_token = lambda: ""
got = dictate.cleanup("um hello", {**dictate.DEFAULT_CONFIG, "provider": "copilot"})
assert got[:2] == ("um hello", "skipped") and "not signed in" in got[2], got
dictate.providers.gh_token = real_gh

SECRET = "sk-test-NEVER-LOG-ME"  # the key reaches neither the log nor the app's stdout
dictate.transcribe = lambda wav, vocab, language, url: ("um so send the update", "cli")
for key in (SECRET, SECRET + "\nx"):
    dictate.providers.post_json = reply_with(urllib.error.HTTPError(
        "https://api.anthropic.com/v1/messages", 401, "Unauthorized", {}, io.BytesIO(b"")))
    sys.stdin = io.StringIO(json.dumps({"provider": "claude", "model": "m", "api_key": key}))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert dictate.main(["x.wav"]) == 0
    printed = json.loads(out.getvalue())
    assert printed["text"] == "um so send the update" and printed["cleanup"] == "skipped"
    assert "NEVER" not in out.getvalue() and "NEVER" not in dictate.LOG.read_text()
assert "401" in dictate.LOG.read_text()
dictate.transcribe = lambda wav, vocab, language, url: ("der Käse ist gut", "cli")  # unescaped
sys.stdin = io.StringIO(json.dumps({"language": "de", "cleanup": "off"}))
out = io.StringIO()
with contextlib.redirect_stdout(out):
    assert dictate.main(["x.wav"]) == 0
assert '"text": "der Käse ist gut"' in out.getvalue()
assert '"raw": "der Käse ist gut"' in dictate.LOG.read_text(encoding="utf-8")

# ~/.config/audax/.env overrides the app's settings for each dictation, key by key; its key
# reaches the request header and nothing else (not stdout, the log or the environment).
dictate.providers.ENV_FILE.write_text(
    "# gateway\nAUDAX_PROVIDER=openai_compatible\nAUDAX_BASE_URL=https://gw.example/v1\n"
    "export AUDAX_MODEL='gw-model'\nOPENAI_API_KEY=" + SECRET + "\n")
environ = dict(os.environ)
dictate.transcribe = lambda wav, vocab, language, url: ("um so send the update", "cli")
seen = []


def gateway(reply):
    def post(url, headers, body, timeout):
        seen.append((url, headers.get("Authorization"), body["model"]))
        return reply_with(reply)(url, headers, body, timeout)
    return post


for reply, status in (({"choices": [{"message": {"content": "So send the update."}}]}, "ok"),
                      (urllib.error.HTTPError("https://gw.example/v1/chat/completions", 401,
                                              "Unauthorized", {}, io.BytesIO(b"")), "skipped")):
    dictate.providers.post_json = gateway(reply)
    sys.stdin = io.StringIO(json.dumps({"provider": "ollama", "model": "gemma4", "api_key": ""}))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert dictate.main(["x.wav"]) == 0
    assert json.loads(out.getvalue())["cleanup"] == status, out.getvalue()
    last = json.loads(dictate.LOG.read_text(encoding="utf-8").splitlines()[-1])
    assert last["provider"] == "openai_compatible", last  # the log names the provider used
    assert SECRET not in out.getvalue() and SECRET not in dictate.LOG.read_text()
assert json.loads(out.getvalue())["text"] == "um so send the update"
assert "401" in last["error"]
assert seen == [("https://gw.example/v1/chat/completions", "Bearer " + SECRET, "gw-model")] * 2
assert dict(os.environ) == environ
dictate.providers.ENV_FILE = Path(tempfile.mkdtemp()) / ".env"
dictate.transcribe, dictate.providers.post_json = real_transcribe, real_post

ct, body = dictate.multipart({"temperature": "0", "language": "de"}, "file", "rec.wav", b"RIFF....")
assert ct.startswith("multipart/form-data; boundary=") and b'name="language"\r\n\r\nde' in body
assert b'filename="rec.wav"' in body and body.endswith(b"--\r\n")
form = email.message_from_bytes(b"Content-Type: " + ct.encode() + b"\r\n\r\n" + body)
assert {part.get_param("name", header="content-disposition"): part.get_payload(decode=True)
        for part in form.get_payload()} == {"temperature": b"0", "language": b"de",
                                             "file": b"RIFF...."}


class FakeWhisper(http.server.BaseHTTPRequestHandler):  # a real local server: the success path
    reply = b'{"text": " [Music]\\n Send the update.\\n"}'
    got = b""

    def do_POST(self):
        FakeWhisper.got = self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(FakeWhisper.reply)

    def log_message(self, *args):
        pass


fake = http.server.HTTPServer(("127.0.0.1", 0), FakeWhisper)
threading.Thread(target=fake.serve_forever, daemon=True).start()
url = "http://127.0.0.1:%d/inference" % fake.server_port
wav = Path(tempfile.mkdtemp()) / "rec.wav"
wav.write_bytes(b"RIFF....WAVE")
assert dictate.transcribe(wav, ["Workfront", "Käse"], "de", server_url=url) == (
    "Send the update.", "server")  # non-speech tags cleaned as for whisper-cli
for field in ('name="temperature"\r\n\r\n0\r\n', 'name="response_format"\r\n\r\njson\r\n',
              'name="language"\r\n\r\nde\r\n', 'name="prompt"\r\n\r\nWorkfront, Käse\r\n'):
    assert field.encode() in FakeWhisper.got, field
assert b"RIFF....WAVE" in FakeWhisper.got
assert dictate.transcribe_server(wav, [], "en", url=url) == "Send the update."
assert b'name="prompt"' not in FakeWhisper.got  # no vocabulary, no prompt field

real_cli = dictate.transcribe_cli  # test_transcribe_falls_back
calls = []
dictate.transcribe_cli = lambda wav, vocab, language: calls.append("cli") or "fallback text"
closed = "http://127.0.0.1:9/inference"  # a real closed port: connection refused
assert dictate.transcribe(wav, [], "en", server_url=closed) == ("fallback text", "cli")
FakeWhisper.reply = b'{"error": "failed to read audio data"}'  # the server's own failure reply
assert dictate.transcribe(wav, [], "en", server_url=url) == ("fallback text", "cli")
FakeWhisper.reply = b"<html>not json</html>"
assert dictate.transcribe(wav, [], "en", server_url=url) == ("fallback text", "cli")
FakeWhisper.reply = b'{"text": null}'  # JSON, but no transcript in it
assert dictate.transcribe(wav, [], "en", server_url=url)[1] == "cli"
assert calls == ["cli", "cli", "cli", "cli"]
for reply in (b'{"text": null}', b"[1]"):  # no usable transcript: ValueError, which falls back
    FakeWhisper.reply = reply
    try:
        dictate.transcribe_server(wav, [], "en", url=url)
        raise AssertionError("no error")
    except ValueError:
        pass
dictate.transcribe_cli = real_cli
fake.shutdown()
mute = socket.socket()  # accepts the connection, never answers: a timeout is an OSError too
mute.bind(("127.0.0.1", 0))
mute.listen()
try:
    dictate.transcribe_server(wav, [], "en", url="http://127.0.0.1:%d/inference"
                              % mute.getsockname()[1], timeout=0.3)
    raise AssertionError("no timeout")
except OSError:
    pass
mute.close()

sys.stdin = io.StringIO("")  # main reads its config from stdin; never the runner's
err = io.StringIO()
with contextlib.redirect_stderr(err):
    assert dictate.main([]) == 1  # no recording given
assert err.getvalue().startswith("usage:")
assert dictate.main(["/nonexistent.wav"]) == 1  # whisper fails: error, not a crash

print("ok")
