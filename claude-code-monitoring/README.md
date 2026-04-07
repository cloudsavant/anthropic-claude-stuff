# Claude Code — Monitoring with Loki + Grafana

Push per-turn metrics from Claude Code to a Loki instance and visualize them in Grafana.
Two dashboards are included: one for general token/cache/context metrics, one for model usage analysis.

## What gets tracked

Every time Claude Code completes a turn, the following metrics are pushed to Loki:

| Field | Description |
|---|---|
| `model` | Model ID (e.g. `claude-sonnet-4-6`) — also a stream label |
| `session_id` | Claude Code session ID |
| `turn_input` | Input tokens this turn |
| `turn_output` | Output tokens this turn |
| `turn_total` | Total tokens this turn |
| `session_input` | Cumulative input tokens for session |
| `session_output` | Cumulative output tokens for session |
| `session_total` | Cumulative total tokens for session |
| `cache_creation` | Cache creation tokens this turn |
| `cache_read` | Cache read tokens this turn |
| `cache_hit_ratio` | Cache hit % `(cache_read / (cache_read + cache_creation) * 100)` |
| `context_used` | Actual context window used `(cache_read + turn_input + turn_output)` |
| `context_max` | Context window size |
| `context_pct` | Context window used % |
| `turn_api_duration_ms` | Per-turn API response time (ms) — omitted on first turn of session |
| `turn_total_duration_ms` | Per-turn wall-clock time (ms) — omitted on first turn of session |
| `session_api_duration_ms` | Cumulative API time for session |
| `session_total_duration_ms` | Cumulative wall-clock time for session |
| `lines_added` | Cumulative lines of code added in session |
| `lines_removed` | Cumulative lines of code removed in session |
| `rate_5h` | 5-hour rolling rate limit used % |
| `rate_7d` | 7-day rolling rate limit used % |

> **Context window note:** `context_used = cache_read + turn_input + turn_output`.
> Do NOT add session totals — `cache_read` already represents the accumulated context.
> Adding session totals double-counts and produces values over 100%.

> **Response time note:** `total_api_duration_ms` and `total_duration_ms` in the Claude Code
> JSON are session cumulative totals. The scripts calculate per-turn deltas using a state file
> at `/tmp/claude-loki-state-{session_id}.json`. The first turn of each session is skipped
> to avoid pushing the full accumulated total.

## Status line

The statusline shows a 2-line prompt suffix after each Claude turn:

```
user@hostname:/cwd [claude-sonnet-4-6]
turn: ↓1234 ↑567 Σ1801 | sess: ↓45K ↑12K Σ57K | cache: ↓200 ↑44K | ctx: 45K/200K (22%) | rate: 5h:16% 7d:22%
```

## Setup

### Prerequisites

- A running [Loki](https://grafana.com/oss/loki/) instance reachable from your machine
- A running [Grafana](https://grafana.com/) instance with Loki configured as a datasource
- `jq` and `curl` installed
- Claude Code CLI

### 1. Install the scripts

```bash
cp scripts/push-to-loki.sh ~/.claude/push-to-loki.sh
cp scripts/statusline-command.sh ~/.claude/statusline-command.sh
chmod +x ~/.claude/push-to-loki.sh ~/.claude/statusline-command.sh
```

Edit `push-to-loki.sh` and set your Loki URL:

```bash
LOKI_URL="http://<your-loki-host>:3100/loki/api/v1/push"
```

### 2. Configure Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

If you only want the status line without Loki, remove the push line from `statusline-command.sh`.

### 3. Import the Grafana dashboards

Find your Loki datasource UID:

```bash
curl -s -u admin:admin http://<grafana-host>:3000/api/datasources | jq '.[] | select(.type=="loki") | .uid'
```

Replace the placeholder UID in both dashboard JSON files:

```bash
sed -i 's/aeei85juwtji8e/<your-loki-uid>/g' grafana-dashboards/*.json
```

Import via Grafana UI: **Dashboards → Import → Upload JSON file**, or via API:

```bash
curl -X POST http://<grafana-host>:3000/api/dashboards/db \
  -u admin:admin \
  -H "Content-Type: application/json" \
  -d "{\"dashboard\": $(cat grafana-dashboards/claude-code-metrics.json), \"overwrite\": true, \"folderId\": 0}"

curl -X POST http://<grafana-host>:3000/api/dashboards/db \
  -u admin:admin \
  -H "Content-Type: application/json" \
  -d "{\"dashboard\": $(cat grafana-dashboards/claude-code-model-usage.json), \"overwrite\": true, \"folderId\": 0}"
```

## Dashboards

### Claude Code Metrics

General health dashboard with:
- Per-turn token breakdown (input, output, total)
- Session cumulative token totals
- Cache creation vs read, cache hit ratio over time, cache degradation alert
- Context window usage gauge and timeseries
- Per-turn API and total response times, average, overhead (total − API)
- Rate limit gauges (5h, 7d)
- Raw log stream at the bottom

### Claude Code — Model Usage

Model-focused dashboard with:
- Current model (live), unique models used, total turns, avg tokens/turn
- Rate limit gauges (5h, 7d)
- Donut charts: turns, output tokens, input tokens — split by model (24h)
- Timeseries: turns per model (stacked bars), output/input tokens per model
- Response time per model, cache hit ratio per model
- Model usage summary table (turns, avg tokens, avg response, avg cache hit %)
- Rate limit usage over time, lines added/removed over time

## How it works

Claude Code's `statusLine` hook fires after every turn and receives a JSON payload on stdin.
`statusline-command.sh` reads this JSON, formats the terminal status line, and pipes the same
JSON to `push-to-loki.sh` in the background (fire-and-forget, does not block the UI).

`push-to-loki.sh` extracts all metrics, calculates derived values, computes per-turn response
time deltas, and POSTs a structured key=value log line to Loki with `model` as a stream label.
Grafana then queries Loki using LogQL `regexp` + `unwrap` to extract numeric fields for
visualization.

### LogQL pattern used

```logql
max_over_time(
  {job="claude-code", type="metrics"}
    | regexp "field_name=(?P<v>[0-9]+)"
    | unwrap v [10m]
)
```
