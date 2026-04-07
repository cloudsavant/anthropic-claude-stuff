#!/bin/bash

LOKI_URL="http://192.168.178.57:3100/loki/api/v1/push"
TIMESTAMP=$(date +%s%N)

input=$(cat)

# Extract model info (model is an object: {"id": "claude-sonnet-4-6", "display_name": "Sonnet 4.6"})
model=$(echo "$input" | jq -r '.model.id // "unknown"')
session_id=$(echo "$input" | jq -r '.session_id // "unknown"')

# Extract raw metrics
turn_input=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
turn_output=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')
session_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
session_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
cache_creation=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
context_max=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
total_duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
total_api_duration_ms=$(echo "$input" | jq -r '.cost.total_api_duration_ms // 0')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
rate_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0')
rate_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0')

# Per-turn response times: delta from previous cumulative totals (stored per session).
# Only calculate if state file exists — skip on first turn to avoid pushing session cumulative totals.
STATE_FILE="/tmp/claude-loki-state-${session_id}.json"
timing_fields=""
if [ -f "$STATE_FILE" ]; then
    prev_api_ms=$(jq -r '.total_api_duration_ms // 0' "$STATE_FILE")
    prev_total_ms=$(jq -r '.total_duration_ms // 0' "$STATE_FILE")
    turn_api_duration_ms=$((total_api_duration_ms - prev_api_ms))
    turn_total_duration_ms=$((total_duration_ms - prev_total_ms))
    [ "$turn_api_duration_ms" -lt 0 ] && turn_api_duration_ms=0
    [ "$turn_total_duration_ms" -lt 0 ] && turn_total_duration_ms=0
    timing_fields=" turn_api_duration_ms=$turn_api_duration_ms turn_total_duration_ms=$turn_total_duration_ms"
fi
echo "{\"total_api_duration_ms\": $total_api_duration_ms, \"total_duration_ms\": $total_duration_ms}" > "$STATE_FILE"

# Derived metrics
session_total=$((session_input + session_output))
context_used=$((cache_read + turn_input + turn_output))
context_pct=$((context_used * 100 / context_max))
cache_total=$((cache_creation + cache_read))
cache_hit_ratio=$([ "$cache_total" -gt 0 ] && echo $((cache_read * 100 / cache_total)) || echo 0)
turn_total=$((turn_input + turn_output))

# Build the log line
log_line="model=$model session_id=$session_id turn_input=$turn_input turn_output=$turn_output turn_total=$turn_total session_input=$session_input session_output=$session_output session_total=$session_total cache_creation=$cache_creation cache_read=$cache_read cache_hit_ratio=$cache_hit_ratio context_used=$context_used context_max=$context_max context_pct=$context_pct${timing_fields} session_api_duration_ms=$total_api_duration_ms session_total_duration_ms=$total_duration_ms lines_added=$lines_added lines_removed=$lines_removed rate_5h=$rate_5h rate_7d=$rate_7d"

# Create Loki payload
payload=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "job": "claude-code",
        "host": "$(hostname)",
        "type": "metrics",
        "model": "$model"
      },
      "values": [
        ["$TIMESTAMP", "$log_line"]
      ]
    }
  ]
}
EOF
)

# Send to Loki
curl -s -X POST "$LOKI_URL" \
  -H "Content-Type: application/json" \
  -d "$payload" > /dev/null 2>&1 &

# Pass through the input unchanged
echo "$input"
