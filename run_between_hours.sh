#!/bin/sh
#
# Usage:
#   run_between_hours.sh START_HOUR END_HOUR COMMAND [args...]
#
# Example:
#   ./run_between_hours.sh 22 04 ./my_script.sh
#

START_HOUR="$1"
END_HOUR="$2"
shift 2

if [ -z "$START_HOUR" ] || [ -z "$END_HOUR" ] || [ $# -eq 0 ]; then
  echo "Usage: $0 START_HOUR END_HOUR COMMAND [args...]"
  exit 2
fi

COMMAND="$@"

is_within_window() {
  now_hour=$(date +%H)

  if [ "$START_HOUR" -le "$END_HOUR" ]; then
    # same-day window (e.g. 08 → 17)
    [ "$now_hour" -ge "$START_HOUR" ] && [ "$now_hour" -lt "$END_HOUR" ]
  else
    # overnight window (e.g. 22 → 04)
    [ "$now_hour" -ge "$START_HOUR" ] || [ "$now_hour" -lt "$END_HOUR" ]
  fi
}

while true; do
  if ! is_within_window; then
    sleep 60
    continue
  fi

  start_time=$(date +%s)

  $COMMAND
  rc=$?
  rm state/*
  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))

  if [ "$elapsed" -lt 60 ]; then
    echo "ERROR: command ran only $elapsed seconds (< 60). Exiting."
    exit 1
  fi

  sleep 60
done
