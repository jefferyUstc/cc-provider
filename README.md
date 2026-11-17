# ccx: run Claude Code on other providers' models

```
claude      -> Anthropic, your own login (untouched)
stepfun     -> StepFun step-5-preview (Anthropic-compatible endpoint, direct)
openrouter  -> Grok or any other OpenRouter model (Anthropic-compatible endpoint, direct)
openai      -> OpenAI gpt-6.1-sol (through a local LiteLLM proxy)
```

Each command is a symlink to `bin/ccx`. It reads `providers/<invoked name>.env`,
sets Claude Code's `ANTHROPIC_*` variables in its own process only, and starts the
real `claude`. Your global settings and shell stay unchanged; skills, hooks, MCP
servers, CLAUDE.md and history are shared.

Requires bash, python3 and Claude Code; `openai` also needs conda and curl.
Tested on macOS.

## Setup

```bash
./install.sh                          # symlinks in ~/.local/bin (or: ./install.sh <dir>)
conda env create -f environment.yml   # only for openai
```

Export the keys you use in your shell rc file; they are never stored in this repo:

```bash
export STEPFUN_API_KEY=...
export OPENROUTER_API_KEY=...
export OPENAI_API_KEY=...
```

`./install.sh --uninstall` removes the symlinks.

## Usage

Same arguments as `claude`:

```bash
stepfun
stepfun -p "explain this repo"
openrouter --model x-ai/grok-code-fast-1   # another model, this session only
openai --resume
```

Arguments in `CCX_CLAUDE_ARGS` are added to every launch, e.g.
`export CCX_CLAUDE_ARGS="--dangerously-skip-permissions"`.

## Adding a provider

Copy `providers/_template.env` to `providers/<command>.env`, fill it in, and rerun
`./install.sh`. Two kinds of provider:

- **Anthropic Messages-compatible endpoint** (many have one): set
  `ANTHROPIC_BASE_URL`, as in `stepfun.env`. Nothing else is needed.
- **OpenAI protocol only** (xAI, Gemini, ...): set `CCX_LITELLM_PORT` instead and copy
  `openai.litellm.yaml` to `<command>.litellm.yaml` with that provider's LiteLLM
  prefix and key variable, as in `openai.env`.

## Behavior

- **Models**: every Claude alias and auto mode's classifier map to the provider's
  main or small model, and subagents run on the session's model. `/model` lists only
  those two (plus Default).
- **`/model` + Enter** saves to the shared `~/.claude/settings.json`. When the session
  ends, `ccx` restores the previous value if it is not a Claude model, so `claude`
  keeps working. Press `s` instead to switch for the session only.
- **Credentials**: only the provider's key is sent. `ANTHROPIC_API_KEY` is emptied and
  inherited custom headers and cloud-provider switches are dropped. As with plain
  `claude`, commands the model runs can read your environment, including that key.
- **`--settings`**: Claude Code keeps only the last one, so `ccx` merges yours with
  its own.
- **LiteLLM proxy**: started on 127.0.0.1 by the provider's first run and reused
  afterwards; pid file and log are in `~/.local/state/ccx/`. Only the proxy holds the
  real key; `claude` gets a token derived from it. The proxy is replaced
  automatically when the key, the provider's `.litellm.yaml` or `environment.yml`
  changes. LiteLLM is pinned in `environment.yml`.
- **Limits**: claude.ai connectors (Gmail, Drive, ...) do not load, and
  Claude-specific features depend on the provider's compatibility.

## Tests

```bash
./tests/run.sh   # offline: mock API and fake claude, no keys or network
```
