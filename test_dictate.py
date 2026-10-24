"""Run: /usr/bin/python3 test_dictate.py"""
import contextlib
import http.client
import io
import json
import sys
import tempfile
import urllib.error
from pathlib import Path

import dictate

dictate.LOG = Path(tempfile.mkdtemp()) / "test.log"  # keep the real log clean
dictate.USER_SUBS = Path(tempfile.mkdtemp()) / "word_subs.json"  # never the user's real file

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
dictate.transcribe = lambda wav, vocab, language: "send the work front update"
dictate.ask_model = lambda cfg, system, user: "<dictation>Send the work front update.</dictation>"
result = dictate.process(Path("x.wav"), {**dictate.DEFAULT_CONFIG, "cleanup": "full"})
assert result["final"] == "Send the Workfront update." and result["cleanup"] == "ok"
dictate.USER_SUBS.write_text('{"firefly": "Adobe Firefly"}')  # replacement holds its own key
dictate.transcribe = lambda wav, vocab, language: "open firefly now"
dictate.ask_model = lambda cfg, system, user: user  # echoes the <dictation> text unchanged
result = dictate.process(Path("x.wav"), {**dictate.DEFAULT_CONFIG, "cleanup": "full"})
assert result["final"] == "open Adobe Firefly now"  # applied once, never "Adobe Adobe Firefly"
dictate.transcribe, dictate.ask_model = real_transcribe, real_ask_model

assert dictate.read_config(None) == dictate.DEFAULT_CONFIG  # a broken stdin object: defaults
cfg = dictate.read_config(io.StringIO('{"language": "fr", "cleanup": "on"}'))
assert cfg["language"] == "en" and cfg["cleanup"] == "full"


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
dictate.transcribe = lambda wav, vocab, language: "um so send the update"
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
dictate.transcribe = lambda wav, vocab, language: "der Käse ist gut"  # stays unescaped
sys.stdin = io.StringIO(json.dumps({"language": "de", "cleanup": "off"}))
out = io.StringIO()
with contextlib.redirect_stdout(out):
    assert dictate.main(["x.wav"]) == 0
assert '"text": "der Käse ist gut"' in out.getvalue()
assert '"raw": "der Käse ist gut"' in dictate.LOG.read_text(encoding="utf-8")
dictate.transcribe, dictate.providers.post_json = real_transcribe, real_post

sys.stdin = io.StringIO("")  # main reads its config from stdin; never the runner's
err = io.StringIO()
with contextlib.redirect_stderr(err):
    assert dictate.main([]) == 1  # no recording given
assert err.getvalue().startswith("usage:")
assert dictate.main(["/nonexistent.wav"]) == 1  # whisper fails: error, not a crash

print("ok")
