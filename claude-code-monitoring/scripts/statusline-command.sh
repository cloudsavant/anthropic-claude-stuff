#!/bin/bash
input=$(cat)

# Push metrics to Loki in background
echo "$input" | "$(dirname "$0")/push-to-loki.sh" > /dev/null 2>&1 &

cwd=$(echo "$input" | jq -r '.cwd')
model=$(echo "$input" | jq -r '.model.id // "unknown"')

# Per-turn tokens
turn_input=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // "0"')
turn_output=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // "0"')
turn_total=$((turn_input + turn_output))

# Session tokens
session_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // "0"')
session_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // "0"')
session_total=$((session_input + session_output))

# Context window
context_window=$(echo "$input" | jq -r '.context_window.context_window_size // "0"')
cache_creation=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // "0"')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // "0"')
actual_usage=$((cache_read + turn_input + turn_output))
used_pct=$((actual_usage * 100 / context_window))

# Rate limits
rate_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // "?"')
rate_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // "?"')

echo -e "\033[01;32m$(whoami)@$(hostname -s)\033[00m:\033[01;34m$cwd\033[00m \033[00;35m[$model]\033[00m"
echo -e "turn: \033[01;33m↓$turn_input ↑$turn_output Σ$turn_total\033[00m | sess: \033[01;33m↓$session_input ↑$session_output Σ$session_total\033[00m | cache: \033[01;33m↓$cache_creation ↑$cache_read\033[00m | ctx: \033[01;33m$actual_usage/$context_window ($used_pct%)\033[00m | rate: \033[01;33m5h:$rate_5h% 7d:$rate_7d%\033[00m"
