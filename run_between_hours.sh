#!/bin/sh
#
# Usage:
#   run_between_hours.sh START_HOUR END_HOUR [run directory]
#
# Example:
#   ./run_between_hours.sh 22 04 /somepath
#
source ~/.bashrc
ROOT=/Volumes/bigbig/theaiguy/daily
EXEC=/Users/theaiguy/pipeline      # wherever your scripts live

START_HOUR="$1"
END_HOUR="$2"
shift 2

echo "HELLO"

if [ -z "$START_HOUR" ] || [ -z "$END_HOUR" ] ; then
  echo "Usage: $0 START_HOUR END_HOUR [ work dir]"
  exit 2
fi

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

echo "HELLO again"
while true; do
  if ! is_within_window; then
    sleep 60
    continue
  fi

  start_time=$(date +%s)


DOY=$(date +%j)
WORKDIR="${1:-$PWD}"
LOGDIR=$(date +pipe_%H_%M)

echo "looking for ", $WORKDIR

# --- Concurrency check ---
if pgrep -f "coffee $EXEC/new_pipeline.coffee" >/dev/null  2> /dev/null; then
  echo "Another new_pipeline."
  exit 0
fi

if [ -f "$WORKDIR/override.yaml" ]; then
  cd $WORKDIR || exit 1
  export EXEC
  /bin/mkdir -p logs
  if [ -f "$WORKDIR/pipeline.json" ]; then
    echo "PIPELINE HALTED"
    exit 0
  fi
  rm state/*

  echo "=== Starting pipeline for $WORKDIR at $(date) ==="
  coffee $EXEC/new_pipeline.coffee daily_oracle \
    > logs/$LOGDIR.log 2>logs/$LOGDIR.err
  echo "=== Finished pipeline for $WORKDIR at $(date) ==="
else
  echo "No override.yaml for $WORKDIR, skipping."
fi
  rc=$?
  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))

  if [ "$elapsed" -lt 60 ]; then
    echo "ERROR: command ran only $elapsed seconds (< 60). Exiting."
    exit 1
  fi

  sleep 60
done
