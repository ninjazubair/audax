# AUDAX 0.4.0 — more clean-up providers, `.env` configuration (2026-10-24)

Owner request (12:16): "It works with GitHub Copilot now, but it should also work with a `.env`
file … AWS Bedrock or other AI subscriptions … add an advanced thing in the AI part … Microsoft
Foundry etc. You judge the best way." Decisions below are the implementer's **(my call)**.

## Providers
Existing: `ollama`, `copilot`, `claude` (Anthropic API), `openai` — unchanged.
New ids:

| id | Shown as | Request | Auth |
| --- | --- | --- | --- |
| `bedrock` | Amazon Bedrock | Converse API: `POST https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/converse` | Bedrock API key (`Authorization: Bearer`), or SigV4 with an access key/secret (+ session token), or an AWS profile from `~/.aws/credentials` + `~/.aws/config` |
| `foundry` | Microsoft Foundry | OpenAI-compatible chat completions at `{base_url}/chat/completions[?api-version=…]` (e.g. `https://<resource>.openai.azure.com/openai/v1`) | header `api-key: <key>` by default |
| `openai_compatible` | Other (OpenAI-compatible) | `{base_url}/chat/completions[?api-version=…]` | `Authorization: Bearer` by default |
| `anthropic_compatible` | Other (Anthropic-compatible) | `{base_url}/v1/messages`, `anthropic-version: 2023-06-01` (e.g. Claude on Foundry `https://<resource>.services.ai.azure.com/anthropic`) | `x-api-key` by default |

- Header style is configurable for the three key-based new providers: `bearer` | `api-key` |
  `x-api-key`. Optional `api_version` adds `?api-version=…`.
- Bodies (minimal, so gateways accept them): OpenAI-compatible `{"model", "messages": [system,
  user]}` (no temperature: reasoning models reject it); Anthropic-compatible `{"model",
  "max_tokens": 2048, "system", "messages": [user]}` (no betas, no output_config); Bedrock
  Converse `{"system": [{"text"}], "messages": [{"role": "user", "content": [{"text"}]}],
  "inferenceConfig": {"maxTokens": 2048}}` (no temperature: current Claude models reject sampling
  parameters).
- Responses: OpenAI shape `choices[0].message.content`; Anthropic shape join `content[].text`
  where `type == "text"`; Converse join `output.message.content[].text`.
- SigV4 (service `bedrock`, region from config): standard library only (`hmac`, `hashlib`);
  signed headers `content-type;host;x-amz-date` (+ `x-amz-security-token` when a session token
  is present); canonical URI is the already-percent-encoded request path encoded again per
  segment (Bedrock model ids contain `:`). Verified against the AWS documentation example and
  against `curl --aws-sigv4` on the same request.
- AWS profile: `configparser` over `~/.aws/credentials` (`aws_access_key_id`,
  `aws_secret_access_key`, `aws_session_token`) and `~/.aws/config` (`[profile X]` → `region`).
  SSO profiles are not supported (clear error: "use an access key or a Bedrock API key").
- No SDKs: the script runs under Apple's `/usr/bin/python3` 3.9 inside a signed bundle with no
  package installs (same ruling as v2).
- Default model fields are empty for the new providers; the user types the model / deployment /
  model id (placeholders show examples). Timeout 20 s like the others; any failure → "Pasted
  without clean-up".

## Configuration sources
1. **Settings → Clean-up**: the provider picker lists the four new entries; an **Advanced**
   group shows the fields the chosen provider needs (base URL, model, header style, API
   version; for Bedrock: region, auth method API key / access key / AWS profile, profile name).
   Secrets go to the Keychain (service `local.audax`; accounts `bedrock`, `bedrock_access_key_id`,
   `bedrock_secret_access_key`, `bedrock_session_token`, `foundry`, `openai_compatible`,
   `anthropic_compatible`). A **Test connection** button runs one tiny request and shows "OK
   (N ms)" or the error.
2. **`~/.config/audax/.env`** (KEY=VALUE, `#` comments, optional `export `, optional quotes):
   read by `dictate.py` on every dictation and by Settings for display. Any non-empty key there
   **overrides** the Settings value, key by key. Recognised keys:
   `AUDAX_PROVIDER`, `AUDAX_MODEL`, `AUDAX_BASE_URL`, `AUDAX_API_KEY`, `AUDAX_AUTH_HEADER`,
   `AUDAX_API_VERSION`, `AWS_REGION` / `AWS_DEFAULT_REGION`, `AWS_BEARER_TOKEN_BEDROCK`,
   `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_PROFILE`,
   `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_API_VERSION`, `OPENAI_API_KEY`,
   `OPENAI_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`. Provider-specific keys apply only
   to their provider (e.g. `AZURE_*` to `foundry`, `AWS_*` to `bedrock`).
   - Settings shows "Provider and values come from ~/.config/audax/.env" when `AUDAX_PROVIDER` is
     set there, and a warning when the file is readable by group or others ("chmod 600").
   - "Open .env file" creates the file with a commented template (mode 0600) only if it does not
     exist, then opens it. AUDAX never overwrites or edits an existing `.env`.
   - Secrets read from `.env` are never logged, never put in the environment of child processes,
     never written anywhere.

## UI text
- Footer: "Audio stays on this Mac. Text is sent to Amazon Bedrock / Microsoft Foundry / <host of
  base URL> for clean-up."
- Check row "AI clean-up": configured (required fields present) vs "Needs setup in Settings →
  Advanced" with a "Settings…" fix button.

## Non-goals
SSO / IAM Identity Center profiles, Vertex AI, streaming, per-provider model pickers for the new
providers, editing `.env` from the app.

## Constraints
As v3: Python 3.9 stdlib; Swift macOS 14; zero warnings; secrets never in argv/env/logs/files AUDAX
writes; no file deletion; plain commit messages (no AI attribution).
