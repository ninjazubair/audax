"""The clean-up model providers: one request builder per provider, one HTTP call (post_json).

Python 3.9 standard library only: the app runs this under Apple's /usr/bin/python3, no pip.
The API key comes in cfg["api_key"] (from the app's stdin) and goes only into a request header;
it is never logged, and no error raised here quotes it.
"""
import json
import urllib.request

USER_AGENT = "AUDAX/0.2.0"
OLLAMA_URL = "http://127.0.0.1:11434/api/chat"
OPENAI_URL = "https://api.openai.com/v1/chat/completions"
CLAUDE_URL = "https://api.anthropic.com/v1/messages"


def post_json(url: str, headers: dict, body: dict, timeout: float) -> dict:
    """POSTs body as JSON, returns the JSON reply. HTTP errors raise urllib.error.HTTPError."""
    req = urllib.request.Request(url, json.dumps(body).encode(),
                                 {**headers, "User-Agent": USER_AGENT})
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


def extract_text(provider: str, resp: dict) -> str:
    if provider == "claude":
        return "".join(b["text"] for b in resp["content"] if b.get("type") == "text")
    if provider == "ollama":
        return resp["message"]["content"]
    return resp["choices"][0]["message"]["content"]


BUILDERS = {"ollama": ollama_request, "openai": openai_request, "claude": claude_request}


def complete(provider: str, cfg: dict, system: str, user: str, timeout: float = 20) -> str:
    """The model's answer as text. Raises on any failure; dictate.cleanup decides what then."""
    if provider == "copilot":
        raise RuntimeError("copilot: not available until Task 6")
    url, headers, body = BUILDERS[provider](cfg, system, user)
    return extract_text(provider, post_json(url, headers, body, timeout))
