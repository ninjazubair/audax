"""The clean-up model providers: one request builder per provider, one HTTP call (post_json;
get_json for the Copilot entitlement lookup and copilot_models).

Python 3.9 standard library only: the app runs this under Apple's /usr/bin/python3, no pip.
The API key comes in cfg["api_key"] (from the app's stdin) and goes only into a request header;
it is never logged, and no error raised here quotes it. GitHub Copilot needs no key: its token
is read from the GitHub CLI on every call and never stored; only the API host and the seat's
model list (ids, names, routes) are cached.

CLI for the app's Settings: python3 providers.py --copilot-models prints that list as JSON.
"""
import http.client
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional


def read_version(path: Path) -> str:
    """The app's version from the VERSION file (repo root, or next to this script in the app).

    "dev" when it is missing, empty or unreadable: a version string never fails a clean-up.
    """
    try:
        return path.read_text(encoding="utf-8").strip() or "dev"
    except (OSError, ValueError):  # ValueError: not UTF-8
        return "dev"


APP_VERSION = read_version(Path(__file__).with_name("VERSION"))
USER_AGENT = "AUDAX/" + APP_VERSION
OLLAMA_URL = "http://127.0.0.1:11434/api/chat"
OPENAI_URL = "https://api.openai.com/v1/chat/completions"
CLAUDE_URL = "https://api.anthropic.com/v1/messages"
STATE = Path.home() / ".cache/mac-dictation"
GH_PATHS = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]  # an app's PATH has no Homebrew
COPILOT_HEADERS = {"Copilot-Integration-Id": "audax", "Editor-Version": "audax/" + APP_VERSION,
                   "X-GitHub-Api-Version": "2025-04-01", "User-Agent": USER_AGENT}
COPILOT_USER_URL = "https://api.github.com/copilot_internal/user"
COPILOT_DEFAULT_API = "https://api.githubcopilot.com"
HOST_CACHE = STATE / "copilot_host.json"  # {"api": str, "at": epoch}, never a token
HOST_CACHE_SECONDS = 24 * 3600
MODELS_CACHE = STATE / "copilot_models.json"  # {"at", "models": [{"id", "name", "route"}]}
MODELS_CACHE_SECONDS = 600
FIRST_MODEL = "gpt-6.1-sol"  # the default: top of the list


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
    """The host only. at=0 marks it stale."""
    write_cache(cache, {"api": api, "at": time.time() if at is None else at})


def write_cache(cache: Path, data: dict) -> None:
    """Atomic, mode 0600 (mkstemp's). Never pass it a token.

    Best effort: a cache that cannot be written never fails a clean-up.
    On failure only the temp file this call created is removed.
    """
    tmp = None
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=cache.parent, prefix=cache.name + ".")
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
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


def model_route(entry: dict) -> Optional[str]:
    """Chat when listed or when nothing is listed (gpt-4.1 lists none but works there)."""
    endpoints = entry.get("supported_endpoints") or []
    if "/chat/completions" in endpoints or not endpoints:
        return "/chat/completions"
    return "/responses" if "/responses" in endpoints else None  # e.g. ws: only, embeddings


def read_models_cache(cache: Path) -> tuple:
    """(fresh, models); (False, None) when there is none yet or it is not ours."""
    try:
        saved = json.loads(cache.read_text())
        fresh = 0 <= time.time() - saved["at"] < MODELS_CACHE_SECONDS
        models = saved["models"]
    except (OSError, ValueError, KeyError, TypeError):
        return False, None
    return (fresh, models) if isinstance(models, list) else (False, None)


def copilot_models(token: str, host: str, get=None, cache: Optional[Path] = None) -> list:
    """The seat's pickable models as {"id", "name", "route"}, gpt-6.1-sol first, cached 10 min.
    For the CLI only: a dictation reads the cache and never calls this.

    Never raises: on any failure the last cached list, however old, else [].
    get defaults to get_json and cache to MODELS_CACHE, both looked up at call time.
    """
    get = get or get_json
    cache = cache or MODELS_CACHE
    fresh, saved = read_models_cache(cache)
    if fresh:
        return saved
    try:
        data = get(host + "/models", {"Authorization": "Bearer " + token, **COPILOT_HEADERS}, 10)
        # Skipped: entries that are not a dict, and entries without an id (missing or empty).
        entries = [m for m in data["data"] if isinstance(m, dict) and m.get("id")]
        models = [{"id": m["id"], "name": m.get("name") or m["id"], "route": model_route(m)}
                  for m in entries if m.get("model_picker_enabled") or m["id"] == "gpt-4.1"]
        models = sorted((m for m in models if m["route"]),
                        key=lambda m: (m["id"] != FIRST_MODEL, m["name"].lower()))
    except (OSError, ValueError, KeyError, TypeError, AttributeError,
            http.client.HTTPException):  # offline, HTTP status, not JSON, not the shape we know
        return saved or []
    write_cache(cache, {"at": time.time(), "models": models})
    return models


def copilot_route(model_id: str, models: list) -> str:
    """The listed route; for a model the list lacks (or no list), a guess from its id."""
    listed = next((m["route"] for m in models  # a foreign cache shape: skipped, not raised
                   if isinstance(m, dict) and m.get("id") == model_id and m.get("route")), None)
    if listed:
        return listed
    # ponytail: id heuristic for the families measured on /responses only (24 Oct 2026); a new
    # /responses-only family (say gpt-7) goes to chat until it shows up in the cached list.
    responses = model_id.startswith(("gpt-5", "gpt-6")) or "codex" in model_id
    return "/responses" if responses else "/chat/completions"


def copilot_request(cfg: dict, system: str, user: str) -> tuple:
    if copilot_route(cfg.get("model", ""), cfg.get("_models", [])) == "/responses":
        return responses_request(cfg, system, user)
    headers = json_headers(Authorization="Bearer " + cfg["_token"], **COPILOT_HEADERS)
    body = {"model": cfg.get("model", ""), "temperature": 0, "messages": chat(system, user)}
    return cfg["_host"] + "/chat/completions", headers, body


def responses_request(cfg: dict, system: str, user: str) -> tuple:
    """Copilot's /responses (the only endpoint of gpt-6.1-sol and the current OpenAI models)."""
    headers = json_headers(Authorization="Bearer " + cfg["_token"], **COPILOT_HEADERS)
    body = {"model": cfg.get("model", ""), "instructions": system,
            "input": [{"role": "user", "content": [{"type": "input_text", "text": user}]}],
            "store": False}
    return cfg["_host"] + "/responses", headers, body


def with_copilot_auth(cfg: dict) -> dict:
    """A copy of cfg with the GitHub token, the plan's host and the cached model list (for the
    route), at any age; [] without one. Never fetches the list: a dictation must not wait for
    it; the CLI (run by the app's Settings) refreshes it. The caller's dict is untouched."""
    token = gh_token()
    if not token:
        raise RuntimeError("copilot: not signed in - run: "
                           "gh auth login --hostname github.com --web --git-protocol https")
    host = copilot_api_host(token)
    models = read_models_cache(MODELS_CACHE)[1] or []
    return {**cfg, "_token": token, "_host": host, "_models": models}


def extract_text(provider: str, resp: dict) -> str:
    if provider == "copilot" and "output" in resp:  # /responses
        return "".join(c["text"] for item in resp["output"] if item.get("type") == "message"
                       for c in item["content"] if c.get("type") == "output_text")
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


def main(argv: list) -> int:
    """--copilot-models: the seat's models as a JSON array on stdout, for the app's Settings;
    the only path that refreshes the cached list (when older than 10 minutes).

    Exit 1 with one line on stderr when not signed in or nothing is listed. The token is never
    printed: errors are ours (RuntimeError) or reported by type only.
    """
    if argv != ["--copilot-models"]:
        print("usage: providers.py --copilot-models", file=sys.stderr)
        return 2
    try:
        auth = with_copilot_auth({})
        models = copilot_models(auth["_token"], auth["_host"])
    except RuntimeError as e:  # not signed in, or Copilot Chat off: our own words
        print(e, file=sys.stderr)
        return 1
    except Exception as e:  # the host lookup failed; its text is never printed
        print("copilot: model list unavailable (%s)" % type(e).__name__, file=sys.stderr)
        return 1
    if not models:
        print("copilot: no models listed for this account", file=sys.stderr)
        return 1
    print(json.dumps(models))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
