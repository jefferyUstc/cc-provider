#!/usr/bin/env bash
# tests/run.sh - offline tests for bin/ccx. No real API keys or network needed.
# Needs python3 and claude on PATH; the routing test runs the real claude binary
# against tests/mock_anthropic.py, the rest use a fake claude that records what
# ccx hands it.
set -euo pipefail

repo=$(cd -P "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
mock_pid=""
cleanup() {
  if [ -n "$mock_pid" ]; then
    kill "$mock_pid"
    wait "$mock_pid" 2>/dev/null || true   # the mock dies of SIGTERM by design; its status is not a result
  fi
  cat "$t"/state/ccx/*.pid 2>/dev/null | xargs kill 2>/dev/null || true   # stub LiteLLM proxy
  rm -rf "$t"
}
trap cleanup EXIT

# Run as a plain terminal session even when invoked from inside Claude Code.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION \
      CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_EXECPATH \
      CLAUDE_CODE_SESSION_ATTENDED CLAUDE_PID CLAUDE_EFFORT AI_AGENT CCX_CLAUDE_ARGS

pass=0 fail=0
check() { # check NAME COMMAND...
  if "${@:2}"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi
}
has() { grep -q -- "$2" "$1"; }

# A private copy of ccx with a mock provider (CCX_HOME is wherever ccx lives).
mkdir -p "$t/bin" "$t/providers" "$t/work" "$t/cfg"
cp "$repo/bin/ccx" "$t/bin/ccx"
ln -s ccx "$t/bin/mock"
python3 -I "$repo/tests/mock_anthropic.py" "$t/requests.log" > "$t/port" &
mock_pid=$!
for _ in $(seq 1 50); do [ -s "$t/port" ] && break; sleep 0.1; done
[ -s "$t/port" ] || { echo "mock server did not start"; exit 1; }
cat > "$t/providers/mock.env" <<EOF
CCX_KEY=MOCK_API_KEY
CCX_MODEL=big-model
CCX_SMALL_MODEL=small-model
ANTHROPIC_BASE_URL=http://127.0.0.1:$(cat "$t/port")/prefix
EOF

# Fake claude: records argv and env as JSON, then optionally edits settings.json
# the way /model + Enter would, and hangs up ccx the way a closed terminal would.
cat > "$t/fake_claude" <<'EOF'
#!/usr/bin/env python3
import json, os, signal, sys
json.dump({"argv": sys.argv[1:], "env": dict(os.environ)}, open(os.environ["FAKE_OUT"], "w"))
if os.environ.get("FAKE_SET_MODEL"):
    p = os.environ["CLAUDE_CONFIG_DIR"] + "/settings.json"
    s = json.load(open(p)); s["model"] = os.environ["FAKE_SET_MODEL"]; json.dump(s, open(p, "w"))
if os.environ.get("FAKE_HANGUP"):
    os.kill(os.getppid(), signal.SIGHUP)
sys.exit(3)
EOF
chmod +x "$t/fake_claude"
fake() { # fake [ccx args...]: run the mock provider against the fake claude
  (cd "$t/work" && CLAUDE_CONFIG_DIR=$t/cfg CCX_CLAUDE_BIN=$t/fake_claude FAKE_OUT=$t/fake.json \
    MOCK_API_KEY=test-key-123 "$t/bin/mock" "$@") || true
}
q() { python3 -c "import json,sys; d=json.load(open('$t/fake.json')); print($1)"; }
settings_flag() { q "json.loads(d['argv'][d['argv'].index('--settings')+1])$1"; }
echo '{"model": "opus"}' > "$t/cfg/settings.json"

echo "== routing through the real claude binary =="
out=$(cd "$t/work" && MOCK_API_KEY=test-key-123 "$t/bin/mock" -p "reply with OK" </dev/null 2>/dev/null)
check "claude -p returns the mock's reply" [ "$out" = OK ]
check "request goes to <base>/v1/messages" has "$t/requests.log" '"path": "/prefix/v1/messages'
check "request asks for the provider's model" has "$t/requests.log" '"model": "big-model"'
check "only the provider key is sent (Bearer)" has "$t/requests.log" '"authorization": "Bearer test-key-123"'
check "no x-api-key header is sent" has "$t/requests.log" '"x_api_key": null'
check "no Anthropic credential is sent" [ "$(grep -c '"authorization": "Bearer test-key-123"' "$t/requests.log")" = "$(grep -c . "$t/requests.log")" ]

echo "== environment handed to claude =="
fake
check "main model mapped" [ "$(q "d['env']['ANTHROPIC_MODEL']")" = big-model ]
check "opus/sonnet/fable aliases mapped" [ "$(q "d['env']['ANTHROPIC_DEFAULT_OPUS_MODEL'] + d['env']['ANTHROPIC_DEFAULT_SONNET_MODEL'] + d['env']['ANTHROPIC_DEFAULT_FABLE_MODEL']")" = big-modelbig-modelbig-model ]
check "haiku alias mapped to small model" [ "$(q "d['env']['ANTHROPIC_DEFAULT_HAIKU_MODEL']")" = small-model ]
check "subagents forced onto the session's model" [ "$(q "d['env']['CLAUDE_CODE_SUBAGENT_MODEL_FORCE']")" = 1 ]
check "auto-mode classifier model mapped" [ "$(q "d['env']['CLAUDE_CODE_AUTO_MODE_MODEL']")" = big-model ]
check "auto-mode server checks off" [ "$(q "d['env']['CLAUDE_CODE_AUTO_MODE_SERVER']")" = 0 ]
check "ANTHROPIC_API_KEY explicitly empty" [ "$(q "repr(d['env']['ANTHROPIC_API_KEY'])")" = "''" ]
check "raw provider key not exported" [ "$(q "'MOCK_API_KEY' in d['env']")" = False ]
check "exit code of claude is passed through" [ "$( (cd "$t/work" && CLAUDE_CONFIG_DIR=$t/cfg CCX_CLAUDE_BIN=$t/fake_claude FAKE_OUT=$t/fake.json MOCK_API_KEY=k "$t/bin/mock"); echo $?)" = 3 ]
ANTHROPIC_CUSTOM_HEADERS='X-Other-Gateway: secret' ANTHROPIC_BETAS=some-beta CLAUDE_CODE_USE_BEDROCK=1 \
  CLAUDE_CODE_USE_MANTLE=1 CLAUDE_CODE_SUBAGENT_MODEL=claude-opus-4-5 ANTHROPIC_BASE_URL=http://elsewhere fake
check "inherited headers, betas, cloud switches and subagent model are dropped" [ "$(q "[k for k in d['env'] if k in ('ANTHROPIC_CUSTOM_HEADERS', 'ANTHROPIC_BETAS', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_MANTLE', 'CLAUDE_CODE_SUBAGENT_MODEL')]")" = "[]" ]
check "inherited base URL is replaced by the provider's" [ "$(q "d['env']['ANTHROPIC_BASE_URL']")" = "http://127.0.0.1:$(cat "$t/port")/prefix" ]

echo "== --settings merging =="
fake -c
check "exactly one --settings is passed" [ "$(q "d['argv'].count('--settings')")" = 1 ]
check "picker lists main and small model" [ "$(settings_flag "['modelPicker']['options']" | grep -o "'model': '[a-z-]*'" | tr '\n' ' ')" = "'model': 'big-model' 'model': 'small-model' " ]
check "other args are kept in order" [ "$(q "d['argv'][2:]")" = "['-c']" ]
fake --settings '{"env": {"FOO": "1"}}' -c
check "caller's --settings JSON is merged" [ "$(settings_flag "['env']['FOO']")" = 1 ]
check "picker still present after merge" [ "$(settings_flag "['modelPicker']['replaceBuiltInOptions']")" = True ]
echo '{"modelPicker": {"options": [{"model": "mine"}]}}' > "$t/user-settings.json"
fake "--settings=$t/user-settings.json"
check "caller's --settings=FILE wins for modelPicker" [ "$(settings_flag "['modelPicker']['options'][0]['model']")" = mine ]
CCX_CLAUDE_ARGS='--settings {"env":{"BAR":"2"}} --verbose' fake
check "--settings inside CCX_CLAUDE_ARGS is merged" [ "$(settings_flag "['env']['BAR']")" = 2 ]
check "CCX_CLAUDE_ARGS come before the command line" [ "$(q "d['argv'][2:]")" = "['--verbose']" ]
fake -p x -- --settings literal
check "arguments after -- are left alone" [ "$(q "d['argv'][2:]")" = "['-p', 'x', '--', '--settings', 'literal']" ]

echo "== /model guard =="
echo '{"model": "opus", "theme": "dark"}' > "$t/cfg/settings.json"
FAKE_SET_MODEL=big-model fake 2>/dev/null
check "provider model ID written by /model is reverted" [ "$(python3 -c "import json; print(json.load(open('$t/cfg/settings.json')))")" = "{'model': 'opus', 'theme': 'dark'}" ]
FAKE_SET_MODEL=sonnet fake
check "a Claude alias written by /model is kept" [ "$(python3 -c "import json; print(json.load(open('$t/cfg/settings.json'))['model'])")" = sonnet ]
echo '{"theme": "dark"}' > "$t/cfg/settings.json"
FAKE_SET_MODEL=big-model fake 2>/dev/null
check "model key removed again when it was unset" [ "$(python3 -c "import json; print(json.load(open('$t/cfg/settings.json')))")" = "{'theme': 'dark'}" ]
echo '{"model": "opus"}' > "$t/cfg/settings.json"
FAKE_SET_MODEL=big-model FAKE_HANGUP=1 fake 2>/dev/null
check "reverted even when the terminal is closed (SIGHUP)" [ "$(python3 -c "import json; print(json.load(open('$t/cfg/settings.json'))['model'])")" = opus ]
echo '{broken' > "$t/cfg/settings.json"; rm -f "$t/fake.json"
fake 2>/dev/null
check "malformed settings.json stops ccx before claude starts" [ ! -e "$t/fake.json" ]
echo '{"model": "opus"}' > "$t/cfg/settings.json"

echo "== errors =="
err=$(cd "$t/work" && env -u MOCK_API_KEY "$t/bin/mock" 2>&1 || true)
check "missing key is reported" has <(echo "$err") "MOCK_API_KEY is empty"
err=$("$t/bin/ccx" nosuch 2>&1 || true)
check "unknown provider is reported" has <(echo "$err") "unknown provider 'nosuch'"
cp "$repo/providers/_template.env" "$t/providers/"
err=$("$t/bin/ccx" _template 2>&1 || true)
check "the template is not a provider" has <(echo "$err") "unknown provider '_template'"
err=$("$t/bin/ccx" ../providers/mock 2>&1 || true)
check "a path is not a provider" has <(echo "$err") "unknown provider '../providers/mock'"

echo "== LiteLLM-backed provider (stub litellm in a fake conda env) =="
mkdir -p "$t/fakebin" "$t/envs/ccx-litellm/bin"
cp "$repo/environment.yml" "$t/"
cat > "$t/fakebin/conda" <<EOF
#!/bin/sh
echo '{"envs": ["$t/envs/ccx-litellm"]}'
EOF
# Stub proxy: records the key it was given and serves /v1/models to its master key only.
cat > "$t/envs/ccx-litellm/bin/litellm" <<'EOF'
#!/usr/bin/env python3
import os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
open(os.environ["STUB_OUT"], "w").write(os.environ.get("LLM_API_KEY", ""))
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        ok = self.headers.get("authorization") == "Bearer " + os.environ["LITELLM_MASTER_KEY"]
        self.send_response(200 if ok else 401)
        self.send_header("content-length", "0")
        self.end_headers()
HTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), Handler).serve_forever()
EOF
chmod +x "$t/fakebin/conda" "$t/envs/ccx-litellm/bin/litellm"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
printf 'CCX_KEY=LLM_API_KEY\nCCX_MODEL=big-model\nCCX_LITELLM_PORT=%s\n' "$port" > "$t/providers/llm.env"
echo "model_list: []" > "$t/providers/llm.litellm.yaml"
llm() {
  (cd "$t/work" && PATH=$t/fakebin:$PATH XDG_STATE_HOME=$t/state STUB_OUT=$t/stub.key CLAUDE_CONFIG_DIR=$t/cfg \
    CCX_CLAUDE_BIN=$t/fake_claude FAKE_OUT=$t/fake.json LLM_API_KEY=real-key-456 "$t/bin/ccx" llm 2>/dev/null) || true
}
proxy_pid() { cat "$t/state/ccx/litellm-llm.pid"; }
llm
check "claude is pointed at the local proxy" [ "$(q "d['env']['ANTHROPIC_BASE_URL']")" = "http://127.0.0.1:$port" ]
check "claude gets a proxy token, never the real key" [ "$(q "d['env']['ANTHROPIC_AUTH_TOKEN'].startswith('sk-ccx-') and 'real-key-456' not in d['env'].values()")" = True ]
check "the proxy gets the real key" [ "$(cat "$t/stub.key")" = real-key-456 ]
first=$(proxy_pid)
llm
check "a running proxy is reused" [ "$(proxy_pid)" = "$first" ]
echo "# changed" >> "$t/providers/llm.litellm.yaml"
llm
check "the proxy is replaced when its config changes" [ "$(proxy_pid)" != "$first" ]
check "the old proxy is stopped" [ "$(kill -0 "$first" 2>/dev/null && echo alive || echo gone)" = gone ]

echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
