"""The clean-up model providers: one request builder per provider, one HTTP call (post_json;
get_json for the Copilot entitlement lookup and copilot_models).

Providers: ollama, copilot, claude, openai, and (0.4.0) bedrock (Amazon Bedrock Converse, with a
Bedrock API key, an access key signed with SigV4, or a static-key AWS profile), foundry
(Microsoft Foundry, OpenAI-compatible), openai_compatible and anthropic_compatible (any gateway
with that API at a base URL).

Python 3.9 standard library only: the app runs this under Apple's /usr/bin/python3, no pip.
Secrets (cfg["api_key"] and the AWS keys, from the app's stdin, ~/.config/audax/.env or
~/.aws) go only into request headers or the SigV4 signature; they are never logged, never put in
os.environ, and no error raised here quotes them. GitHub Copilot needs no key: its token is read
from the GitHub CLI on every call and never stored; only the API host and the seat's model list
(ids, names, routes) are cached.

CLI for the app's Settings: python3 providers.py --copilot-models prints that list as JSON;
python3 providers.py --test sends one tiny request with the settings on stdin (plus the .env)
and prints {"ok": true, "ms": N} or {"ok": false, "error": "..."}.
"""
import configparser
import datetime
import hashlib
import hmac
import http.client
import json
import os
import re
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
ENV_FILE = Path.home() / ".config/audax/.env"  # read on every dictation; AUDAX never writes it
BEDROCK_URL = "https://bedrock-runtime.{region}.amazonaws.com/model/{model}/converse"
SECRET_FIELDS = ("api_key", "aws_access_key_id", "aws_secret_access_key", "aws_session_token")
PROVIDER_FIELDS = SECRET_FIELDS + ("aws_auth", "aws_profile", "base_url", "auth_header",
                                 "api_version", "region")  # tied to one provider
GENERIC_ENV = {"AUDAX_PROVIDER": "provider", "AUDAX_MODEL": "model", "AUDAX_BASE_URL": "base_url",
               "AUDAX_API_KEY": "api_key", "AUDAX_AUTH_HEADER": "auth_header",
               "AUDAX_API_VERSION": "api_version"}
# Applied after GENERIC_ENV, for the resulting provider only (bedrock: own code). A vendor's key
# goes only to that vendor: the two *_compatible gateways take AUDAX_API_KEY and AUDAX_BASE_URL,
# never OPENAI_* or ANTHROPIC_* (2026-10-25 ruling).
PROVIDER_ENV = {
    "foundry": {"AZURE_OPENAI_ENDPOINT": "base_url", "AZURE_OPENAI_API_KEY": "api_key",
                "AZURE_OPENAI_API_VERSION": "api_version"},
    "openai": {"OPENAI_API_KEY": "api_key"},
    "claude": {"ANTHROPIC_API_KEY": "api_key"},
}
AWS_KEYS_ENV = {"AWS_ACCESS_KEY_ID": "aws_access_key_id",
                "AWS_SECRET_ACCESS_KEY": "aws_secret_access_key",
                "AWS_SESSION_TOKEN": "aws_session_token"}
NO_STATIC_KEYS = " - use an access key or a Bedrock API key"


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


def clean_secret(value, name: str) -> str:
    """Trimmed. http.client would quote a header value it cannot send in its error, so refuse
    one with a line break or a non-ASCII character, naming only the field."""
    value = str(value or "").strip()
    if not (value.isascii() and value.isprintable()):
        raise ValueError(name + " has a line break or a non-ASCII character")
    return value


def api_key(cfg: dict) -> str:
    return clean_secret(cfg.get("api_key"), "API key")


def text(cfg: dict, field: str) -> str:
    return str(cfg.get(field) or "").strip()


def need(cfg: dict, provider: str, *fields: str) -> None:
    for field in fields:
        if not text(cfg, field):
            raise ValueError(f"{provider}: {field} is not set")


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


ENV_BLANKS = " \t"  # whitespace in the .env grammar: trimmed, and before an inline "#"


def env_value(value: str) -> Optional[str]:
    """A trimmed .env VALUE. Quoted (' or "): up to the matching closing quote, no escapes, and
    after it only blanks or a # comment. Unquoted: up to the first blank + "#", trimmed.
    None means the line is ignored: junk after the closing quote, or no closing quote."""
    if value[:1] in ("'", '"'):
        end = value.find(value[0], 1)
        if end < 0:
            return None
        rest = value[end + 1:].lstrip(ENV_BLANKS)
        return value[1:end] if rest[:1] in ("", "#") else None
    comment = re.search(r"[ \t]#", value)
    return value[:comment.start()].strip(ENV_BLANKS) if comment else value


def env_line(line: str) -> Optional[tuple]:
    """(key, value) of one .env line, or None: blank, a # comment, no "=", no key, or a quoted
    value the grammar rejects. An optional "export" + space or tab is dropped first."""
    line = line.strip(ENV_BLANKS)
    if line.startswith("#"):
        return None
    export = re.match(r"export[ \t]+", line)
    key, sep, value = line[export.end() if export else 0:].partition("=")
    key, value = key.strip(ENV_BLANKS), env_value(value.strip(ENV_BLANKS))
    return (key, value) if sep and key and value is not None else None


def load_env_file(path) -> dict:
    """KEY=VALUE pairs of a .env file, by the grammar Swift's EnvFile shares: a UTF-8 BOM is
    stripped, lines end at \\n, \\r\\n or \\r, then env_line; no variable expansion; a repeated
    key: the last one wins. A missing, unreadable or non-UTF-8 file gives {}. Never raises,
    never logs."""
    try:
        content = Path(path).read_text(encoding="utf-8-sig")
    except (OSError, ValueError, TypeError):  # missing, no permission, not UTF-8, no path
        return {}
    lines = re.split(r"\r\n|\r|\n", content)  # not splitlines: it also splits on \f,  ...
    return dict(pair for pair in map(env_line, lines) if pair)


def env_values(env: dict, mapping: dict) -> dict:
    return {field: env[name] for name, field in mapping.items() if env.get(name)}


def bedrock_env(env: dict) -> dict:
    """The Bedrock fields a .env sets: the region, then one way to sign in, in this order:
    a Bedrock API key, an access key, a profile. An access key is one unit: when the .env has
    AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY, all three AWS fields come from the .env (no
    AWS_SESSION_TOKEN there means none), never mixed with the settings' (AWS answers 403).
    An AWS_SESSION_TOKEN on its own changes nothing."""
    region = env.get("AWS_REGION") or env.get("AWS_DEFAULT_REGION")  # the SDKs' order
    out = {"region": region} if region else {}
    if env.get("AWS_BEARER_TOKEN_BEDROCK"):
        return {**out, "api_key": env["AWS_BEARER_TOKEN_BEDROCK"], "aws_auth": "api_key"}
    if env.get("AWS_ACCESS_KEY_ID") or env.get("AWS_SECRET_ACCESS_KEY"):
        keys = {field: env.get(name, "") for name, field in AWS_KEYS_ENV.items()}
        return {**out, **keys, "aws_auth": "access_key"}
    if env.get("AWS_PROFILE"):
        return {**out, "aws_profile": env["AWS_PROFILE"], "aws_auth": "profile"}
    return out


def apply_env(cfg: dict, env: dict) -> dict:
    """A new dict: cfg with every non-empty recognised .env value laid over it, key by key.
    The generic AUDAX_* keys first, then the resulting provider's own keys (so those win).
    An AUDAX_PROVIDER that switches provider first drops the settings' PROVIDER_FIELDS, so the
    old provider's key (or host, or AWS sign-in) is never sent to the new one."""
    if env.get("AUDAX_PROVIDER") and env["AUDAX_PROVIDER"] != str(cfg.get("provider")):
        cfg = {k: v for k, v in cfg.items() if k not in PROVIDER_FIELDS}
    out = {**cfg, **env_values(env, GENERIC_ENV)}
    provider = str(out.get("provider"))  # never raises: a dictation must still paste
    if provider == "bedrock":
        return {**out, **bedrock_env(env)}
    return {**out, **env_values(env, PROVIDER_ENV.get(provider, {}))}


def auth_headers(style: str, key: str, default: str = "bearer") -> dict:
    """bearer: Authorization: Bearer <key>; api-key / x-api-key: that header. Empty or unknown
    style: the provider's default."""
    style = str(style or "").strip().lower()
    if style not in ("bearer", "api-key", "x-api-key"):
        style = default
    return {"Authorization": "Bearer " + key} if style == "bearer" else {style: key}


def base_endpoint(cfg: dict, provider: str, path: str) -> str:
    """base_url + path [+ ?api-version=...]. A Foundry resource root (as AZURE_OPENAI_ENDPOINT
    is usually written) gets the OpenAI v1 path, /openai/v1. A whole endpoint pasted as base_url
    (an Azure Target URI, .../chat/completions?api-version=...) keeps its path, not doubled,
    and its query; api_version, when set, replaces the query's api-version: never two."""
    need(cfg, provider, "base_url")
    parts = urllib.parse.urlsplit(text(cfg, "base_url"))
    if parts.scheme not in ("https", "http") or not parts.netloc:  # urllib also opens file://
        raise ValueError(f"{provider}: base_url must start with https:// or http://")
    route = parts.path.rstrip("/") or ("/openai/v1" if provider == "foundry" else "")
    if not route.endswith(path):
        route += path
    query = with_api_version(parts.query, text(cfg, "api_version"))
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, route, query, ""))


def with_api_version(query: str, version: str) -> str:
    """query with at most one api-version: version when set, else the query's own (the last)."""
    pairs = urllib.parse.parse_qsl(query, keep_blank_values=True)
    version = version or dict(pairs).get("api-version", "")
    pairs = [pair for pair in pairs if pair[0] != "api-version"]
    return urllib.parse.urlencode(pairs + ([("api-version", version)] if version else []))


def keyed_request(cfg: dict, provider: str, path: str, default_style: str) -> tuple:
    """(url, headers) of the key-based gateways; ValueError names the first missing field."""
    url = base_endpoint(cfg, provider, path)
    need(cfg, provider, "model", "api_key")
    style = cfg.get("auth_header")
    return url, json_headers(**auth_headers(style, api_key(cfg), default_style))


def openai_compatible_request(cfg: dict, system: str, user: str) -> tuple:
    url, headers = keyed_request(cfg, "openai_compatible", "/chat/completions", "bearer")
    return url, headers, {"model": text(cfg, "model"), "messages": chat(system, user)}


def foundry_request(cfg: dict, system: str, user: str) -> tuple:
    url, headers = keyed_request(cfg, "foundry", "/chat/completions", "api-key")
    return url, headers, {"model": text(cfg, "model"), "messages": chat(system, user)}


def anthropic_compatible_request(cfg: dict, system: str, user: str) -> tuple:
    url, headers = keyed_request(cfg, "anthropic_compatible", "/v1/messages", "x-api-key")
    headers["anthropic-version"] = "2023-06-01"
    body = {"model": text(cfg, "model"), "max_tokens": 2048, "system": system,
            "messages": [{"role": "user", "content": user}]}
    return url, headers, body


def canonical_uri(path: str) -> str:
    """Each segment of the already percent-encoded path encoded once more: SigV4's rule for every
    service but S3, so a Bedrock model id's %3A is signed as %253A."""
    return "/".join(urllib.parse.quote(seg, safe="") for seg in (path or "/").split("/"))


def canonical_query(query: str) -> str:
    pairs = urllib.parse.parse_qsl(query, keep_blank_values=True)
    encoded = sorted((urllib.parse.quote(k, safe=""), urllib.parse.quote(v, safe=""))
                     for k, v in pairs)
    return "&".join(k + "=" + v for k, v in encoded)


def sigv4_sign(method: str, url: str, payload: bytes, content_type: str, amz_date: str, *,
               region: str, service: str, access_key: str, secret_key: str,
               session_token: str = "") -> dict:
    """AWS Signature Version 4 headers: {"Authorization", "x-amz-date"[, "x-amz-security-token"]}.

    Signs content-type, host (the URL's host[:port], which urllib and curl send as Host) and
    x-amz-date, plus x-amz-security-token when there is a session token. amz_date is
    YYYYMMDDTHHMMSSZ (UTC). Host is not returned: urllib sets it.
    """
    parts = urllib.parse.urlsplit(url)
    signed = {"content-type": content_type, "host": parts.netloc, "x-amz-date": amz_date}
    if session_token:
        signed["x-amz-security-token"] = session_token
    names = ";".join(sorted(signed))
    canonical = "\n".join([method, canonical_uri(parts.path), canonical_query(parts.query),
                           *(k + ":" + " ".join(signed[k].split()) for k in sorted(signed)),
                           "", names, hashlib.sha256(payload).hexdigest()])
    scope = f"{amz_date[:8]}/{region}/{service}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                         hashlib.sha256(canonical.encode()).hexdigest()])
    key = ("AWS4" + secret_key).encode()
    for part in (amz_date[:8], region, service, "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    headers = {"Authorization": f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
                                f"SignedHeaders={names}, Signature={signature}",
               "x-amz-date": amz_date}
    if session_token:
        headers["x-amz-security-token"] = session_token
    return headers


def sigv4_headers(method: str, url: str, body_bytes: bytes, region: str, service: str, *,
                  access_key: str, secret_key: str, session_token: str = "",
                  now: Optional[datetime.datetime] = None) -> dict:
    """sigv4_sign for a JSON body at now (UTC; a naive datetime is taken as UTC)."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if now.tzinfo:
        now = now.astimezone(datetime.timezone.utc)
    return sigv4_sign(method, url, body_bytes, "application/json",
                      now.strftime("%Y%m%dT%H%M%SZ"), region=region, service=service,
                      access_key=access_key, secret_key=secret_key, session_token=session_token)


def read_aws_file(path: Path, prefix: str = "") -> dict:
    """{profile: {option: value}} of one AWS ini file, "<prefix>name" sections read as "name";
    {} when the file is missing or unreadable."""
    parser = configparser.ConfigParser(interpolation=None, strict=False)  # "%" in a secret
    try:
        parser.read(path, encoding="utf-8")
    except (configparser.Error, ValueError):  # their text quotes the file, i.e. secrets
        raise RuntimeError("bedrock: cannot read ~/.aws/" + path.name) from None
    return {name[len(prefix):] if prefix and name.startswith(prefix) else name: dict(parser[name])
            for name in parser.sections()}


def static_keys(profile: dict, name: str) -> tuple:
    access, secret = profile.get("aws_access_key_id"), profile.get("aws_secret_access_key")
    if access and secret:
        return access, secret, profile.get("aws_session_token", ""), profile.get("region", "")
    if "sso_start_url" in profile or "sso_session" in profile:
        raise RuntimeError("bedrock: SSO profiles are not supported" + NO_STATIC_KEYS)
    raise RuntimeError(f"bedrock: AWS profile {name} has no access key" + NO_STATIC_KEYS)


def aws_profile_credentials(profile: str, home=None) -> tuple:
    """(access_key, secret_key, session_token, region) of a profile with static keys, from
    <home>/.aws/config ([profile name], or [default]) and <home>/.aws/credentials ([name]),
    whose values win. SSO and role profiles are not supported."""
    aws = Path(home or Path.home()) / ".aws"
    name = profile or "default"
    files = (read_aws_file(aws / "config", "profile "), read_aws_file(aws / "credentials"))
    found = [sections[name] for sections in files if name in sections]
    if not found:
        raise RuntimeError(f"bedrock: AWS profile {name} not found")
    merged = {}
    for section in found:  # config first, then credentials
        merged.update(section)
    return static_keys(merged, name)


def bedrock_auth(cfg: dict) -> tuple:
    """(region, keys): keys is None for a Bedrock API key, else (access, secret, session token).
    A region in the settings beats the profile's."""
    region, method = text(cfg, "region"), text(cfg, "aws_auth") or "api_key"
    if method == "api_key":
        return region, None
    if method == "profile":
        access, secret, token, home_region = aws_profile_credentials(text(cfg, "aws_profile"))
        return region or home_region, (access, secret, token)
    if method == "access_key":
        need(cfg, "bedrock", "aws_access_key_id", "aws_secret_access_key")
        return region, (cfg["aws_access_key_id"], cfg["aws_secret_access_key"],
                        cfg.get("aws_session_token"))
    raise ValueError("bedrock: aws_auth is not valid")


def bedrock_request(cfg: dict, system: str, user: str,
                    now: Optional[datetime.datetime] = None) -> tuple:
    """Bedrock Converse. Signed with SigV4 for an access key or a profile; now is for tests."""
    need(cfg, "bedrock", "model")
    region, keys = bedrock_auth(cfg)
    if not region:
        raise ValueError("bedrock: region is not set")
    if not re.fullmatch(r"[a-z0-9-]+", region):  # it becomes part of the host name
        raise ValueError("bedrock: region is not valid")
    model = urllib.parse.quote(text(cfg, "model"), safe="")  # ids have ":", ARNs "/" too
    url = BEDROCK_URL.format(region=region, model=model)
    body = {"system": [{"text": system}],
            "messages": [{"role": "user", "content": [{"text": user}]}],
            "inferenceConfig": {"maxTokens": 2048}}
    if keys is None:
        need(cfg, "bedrock", "api_key")
        return url, json_headers(Authorization="Bearer " + api_key(cfg)), body
    access, secret, token = (clean_secret(value, name) for value, name in zip(
        keys, ("AWS access key ID", "AWS secret access key", "AWS session token")))
    signed = sigv4_headers("POST", url, json.dumps(body).encode(), region, "bedrock",
                           access_key=access, secret_key=secret, session_token=token, now=now)
    return url, json_headers(**signed), body  # post_json sends these same json.dumps bytes


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


def copilot_token() -> str:
    """The gh token, or RuntimeError (our own words, no token in them) when not signed in."""
    token = gh_token()
    if not token:
        raise RuntimeError("copilot: not signed in - run: "
                           "gh auth login --hostname github.com --web --git-protocol https")
    return token


def with_copilot_auth(cfg: dict, token: str = "") -> dict:
    """A copy of cfg with the GitHub token (copilot_token's unless given), the plan's host and
    the cached model list (for the route), at any age; [] without one. Never fetches the list: a
    dictation must not wait for it; the CLI (run by the app's Settings) refreshes it. The
    caller's dict is untouched."""
    token = token or copilot_token()
    host = copilot_api_host(token)
    models = read_models_cache(MODELS_CACHE)[1] or []
    return {**cfg, "_token": token, "_host": host, "_models": models}


def extract_text(provider: str, resp: dict) -> str:
    if provider == "copilot" and "output" in resp:  # /responses
        return "".join(c["text"] for item in resp["output"] if item.get("type") == "message"
                       for c in item["content"] if c.get("type") == "output_text")
    if provider in ("claude", "anthropic_compatible"):
        return "".join(b["text"] for b in resp["content"] if b.get("type") == "text")
    if provider == "bedrock":  # Converse; reasoning blocks have no "text"
        return "".join(c["text"] for c in resp["output"]["message"]["content"] if "text" in c)
    if provider == "ollama":
        return resp["message"]["content"]
    return resp["choices"][0]["message"]["content"]  # openai, foundry, openai_compatible


BUILDERS = {"ollama": ollama_request, "openai": openai_request, "claude": claude_request,
            "copilot": copilot_request, "bedrock": bedrock_request, "foundry": foundry_request,
            "openai_compatible": openai_compatible_request,
            "anthropic_compatible": anthropic_compatible_request}


def complete(provider: str, cfg: dict, system: str, user: str, timeout: float = 20) -> str:
    """The model's answer as text. Raises on any failure; dictate.cleanup decides what then.

    Copilot: the gh token is not in cfg, so the caller's redaction cannot see it. Any failure
    once it is read (host lookup, request, reply) is raised again as a RuntimeError of its repr
    with the token redacted: a server can echo it in a reason phrase."""
    if provider != "copilot":
        return send(provider, cfg, system, user, timeout)
    token = copilot_token()
    try:
        return send(provider, with_copilot_auth(cfg, token), system, user, timeout)
    except Exception as e:
        raise RuntimeError(redact(repr(e), {"api_key": token})) from None


def send(provider: str, cfg: dict, system: str, user: str, timeout: float) -> str:
    """One request to provider's builder URL, its reply as text."""
    url, headers, body = BUILDERS[provider](cfg, system, user)
    try:
        resp = post_json(url, headers, body, timeout)
    except urllib.error.HTTPError as e:
        if provider == "copilot" and e.code in (401, 403, 404):  # e.g. gh switched account:
            write_host_cache(HOST_CACHE, cfg["_host"], at=0)  # ask for the host next time
        raise
    return extract_text(provider, resp)


def redact(message: str, cfg: dict) -> str:
    """message with every secret value of cfg replaced: a second guard behind clean_secret."""
    for field in SECRET_FIELDS:
        value = text(cfg, field)
        if value:
            message = message.replace(value, "<redacted>")
    return message


def check_connection(stream) -> dict:
    """--test: the settings JSON on stream, plus the .env, one tiny request. Never raises."""
    cfg = {}
    try:
        data = json.loads(stream.read() or "{}")
        if not isinstance(data, dict):
            raise ValueError("settings are not a JSON object")
        cfg = apply_env(data, load_env_file(ENV_FILE))
        t0 = time.monotonic()
        complete(text(cfg, "provider"), cfg, "Reply with the single word OK.", "OK?", timeout=20)
    except Exception as e:  # any failure is the answer; its text is redacted, then cut
        return {"ok": False, "error": redact(repr(e), cfg)[:200]}
    return {"ok": True, "ms": int((time.monotonic() - t0) * 1000)}


def main(argv: list) -> int:
    """--copilot-models: the seat's models as a JSON array on stdout, for the app's Settings;
    the only path that refreshes the cached list (when older than 10 minutes).
    Exit 1 with one line on stderr when not signed in or nothing is listed. The token is never
    printed: errors are ours (RuntimeError) or reported by type only.

    --test: check_connection's result as one JSON line on stdout, exit 0 either way.
    """
    if argv == ["--test"]:
        print(json.dumps(check_connection(sys.stdin)))
        return 0
    if argv != ["--copilot-models"]:
        print("usage: providers.py --copilot-models | --test", file=sys.stderr)
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
