"""The clean-up model providers: one request builder per provider, one HTTP call (post_json;
get_json only for the Copilot entitlement lookup).

Python 3.9 standard library only: the app runs this under Apple's /usr/bin/python3, no pip.
The API key comes in cfg["api_key"] (from the app's stdin) and goes only into a request header;
it is never logged, and no error raised here quotes it. GitHub Copilot needs no key: its token
is read from the GitHub CLI on every call and never stored; only the API host is cached.
"""
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional

USER_AGENT = "AUDAX/0.2.0"
OLLAMA_URL = "http://127.0.0.1:11434/api/chat"
OPENAI_URL = "https://api.openai.com/v1/chat/completions"
CLAUDE_URL = "https://api.anthropic.com/v1/messages"
STATE = Path.home() / ".cache/mac-dictation"
GH_PATHS = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]  # an app's PATH has no Homebrew
COPILOT_HEADERS = {"Copilot-Integration-Id": "audax", "Editor-Version": "audax/0.2.0",
                   "X-GitHub-Api-Version": "2025-04-01", "User-Agent": USER_AGENT}
COPILOT_USER_URL = "https://api.github.com/copilot_internal/user"
COPILOT_DEFAULT_API = "https://api.githubcopilot.com"
HOST_CACHE = STATE / "copilot_host.json"  # {"api": str, "at": epoch}, never a token
HOST_CACHE_SECONDS = 24 * 3600


def post_json(url: str, headers: dict, body: dict, timeout: float) -> dict:
    """POSTs body as JSON, returns the JSON reply. HTTP errors raise urllib.error.HTTPError."""
    req = urllib.request.Request(url, json.dumps(body).encode(),
                                 {**headers, "User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def get_json(url: str, headers: dict, timeout: float) -> dict:
    """GETs url, returns the JSON reply. HTTP errors raise urllib.error.HTTPError."""
    req = urllib.request.Request(url, headers={**headers, "User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def json_headers(**extra) -> dict:
    return {"content-type": "application/json", "User-Agent": USER_AGENT, **extra}


def api_key(cfg: dict) -> str:
    """The key, trimmed. http.client would quote a key it cannot send in its error, so refuse."""
    key = str(cfg.get("api_key", "")).strip()
    if not (key.isascii() and key.isprintable()):
        raise ValueError("API key has a line break or a non-ASCII character")
    return key


def chat(system: str, user: str) -> list:
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


def ollama_request(cfg: dict, system: str, user: str) -> tuple:
    body = {"model": cfg.get("model", ""), "stream": False, "think": False, "keep_alive": "1h",
            "options": {"temperature": 0}, "messages": chat(system, user)}
    return cfg.get("url", OLLAMA_URL), json_headers(), body


def openai_request(cfg: dict, system: str, user: str) -> tuple:
    headers = json_headers(Authorization="Bearer " + api_key(cfg))
    body = {"model": cfg.get("model", ""), "temperature": 0, "messages": chat(system, user)}
    return OPENAI_URL, headers, body


def claude_request(cfg: dict, system: str, user: str) -> tuple:
    headers = json_headers(**{"x-api-key": api_key(cfg), "anthropic-version": "2023-06-01",
                              "anthropic-beta": "server-side-fallback-2026-07-01"})
    body = {"model": cfg.get("model", ""), "max_tokens": 2048, "system": system,
            "messages": [{"role": "user", "content": user}],
            "output_config": {"effort": "low"}, "fallbacks": "default"}
    return CLAUDE_URL, headers, body


def gh_token(run=subprocess.run) -> str:
    """The GitHub CLI's token for github.com, or "" (no gh, signed out, slow, odd output).

    Read on every dictation, never stored. Nothing raised here can carry it: every failure,
    including output that is not UTF-8 or could not go in a header, gives "".
    """
    for gh in GH_PATHS:
        try:
            out = run([gh, "auth", "token", "--hostname", "github.com"],
                      capture_output=True, text=True, timeout=3)
        except (OSError, subprocess.SubprocessError, ValueError):  # ValueError: not UTF-8;
            continue  # its repr would quote stdout, i.e. the token
        token = (out.stdout or "").strip()
        if token and token.isascii() and token.isprintable():
            return token
    return ""


def copilot_host_ok(api) -> bool:
    """The token is sent to this host, so only Copilot's own https hosts are trusted."""
    try:
        parts = urllib.parse.urlsplit(api)
        host = parts.hostname or ""
    except (TypeError, AttributeError, ValueError):  # not a string, or not a URL
        return False
    return parts.scheme == "https" and (host == "githubcopilot.com"
                                        or host.endswith(".githubcopilot.com"))


def read_host_cache(cache: Path) -> Optional[str]:
    try:
        saved = json.loads(cache.read_text())
        api, fresh = saved["api"], 0 <= time.time() - saved["at"] < HOST_CACHE_SECONDS
    except (OSError, ValueError, KeyError, TypeError):  # none yet, or not ours
        return None
    return api if fresh and copilot_host_ok(api) else None


def write_host_cache(cache: Path, api: str, at: Optional[float] = None) -> None:
    """Atomic, mode 0600 (mkstemp's), and the host only. at=0 marks it stale.

    Best effort: a cache that cannot be written never fails a clean-up that has its host.
    On failure only the temp file this call created is removed.
    """
    tmp = None
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=cache.parent, prefix=cache.name + ".")
        with os.fdopen(fd, "w") as f:
            json.dump({"api": api, "at": time.time() if at is None else at}, f)
        os.replace(tmp, cache)
    except OSError:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def copilot_api_host(token: str, get=get_json, cache: Optional[Path] = None) -> str:
    """The Copilot API host for this account's plan (business, enterprise, ...), cached 24 h.

    cache defaults to HOST_CACHE, looked up at call time so a test or wrapper can repoint it.
    A failed entitlement call propagates; dictate.cleanup reports "skipped".
    """
    cache = cache or HOST_CACHE
    api = read_host_cache(cache)
    if api:
        return api
    info = get(COPILOT_USER_URL, {"Authorization": "Bearer " + token, **COPILOT_HEADERS}, 10)
    if info.get("chat_enabled") is False:
        raise RuntimeError("copilot: Copilot Chat is not enabled for this GitHub account")
    api = (info.get("endpoints") or {}).get("api")
    api = api.rstrip("/") if copilot_host_ok(api) else COPILOT_DEFAULT_API
    write_host_cache(cache, api)
    return api


def copilot_request(cfg: dict, system: str, user: str) -> tuple:
    headers = json_headers(Authorization="Bearer " + cfg["_token"], **COPILOT_HEADERS)
    body = {"model": cfg.get("model", ""), "temperature": 0, "messages": chat(system, user)}
    return cfg["_host"] + "/chat/completions", headers, body


def with_copilot_auth(cfg: dict) -> dict:
    """A copy of cfg with the GitHub token and the plan's host; the caller's dict is untouched."""
    token = gh_token()
    if not token:
        raise RuntimeError("copilot: not signed in - run: "
                           "gh auth login --hostname github.com --web")
    return {**cfg, "_token": token, "_host": copilot_api_host(token)}


def extract_text(provider: str, resp: dict) -> str:
    if provider == "claude":
        return "".join(b["text"] for b in resp["content"] if b.get("type") == "text")
    if provider == "ollama":
        return resp["message"]["content"]
    return resp["choices"][0]["message"]["content"]


BUILDERS = {"ollama": ollama_request, "openai": openai_request, "claude": claude_request,
            "copilot": copilot_request}


def complete(provider: str, cfg: dict, system: str, user: str, timeout: float = 20) -> str:
    """The model's answer as text. Raises on any failure; dictate.cleanup decides what then."""
    if provider == "copilot":
        cfg = with_copilot_auth(cfg)
    url, headers, body = BUILDERS[provider](cfg, system, user)
    try:
        resp = post_json(url, headers, body, timeout)
    except urllib.error.HTTPError as e:
        if provider == "copilot" and e.code in (401, 403, 404):  # e.g. gh switched account:
            write_host_cache(HOST_CACHE, cfg["_host"], at=0)  # ask for the host next time
        raise
    return extract_text(provider, resp)
