"""Run: /usr/bin/python3 test_dictate.py"""
import io
import sys
import tempfile
from pathlib import Path

import dictate

dictate.LOG = Path(tempfile.mkdtemp()) / "test.log"  # keep the real log clean

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

sys.stdin = io.StringIO("")  # main reads its config from stdin; never the runner's
assert dictate.main([]) == 1  # no recording given
assert dictate.main(["/nonexistent.wav"]) == 1  # whisper fails: error, not a crash

print("ok")
