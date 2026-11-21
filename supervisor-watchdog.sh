#!/usr/bin/env bash
# supervisord event listener: when any program reaches FATAL (it kept
# crashing and supervisord gave up), stop supervisord so the container exits
# and Railway restarts it. stdout is the supervisor protocol channel, so all
# logging goes to stderr.
set -uo pipefail

printf 'READY\n'
while IFS= read -r header; do
	len=$(printf '%s\n' "$header" | sed -n 's/.*len:\([0-9][0-9]*\).*/\1/p')
	payload=""
	if [ -n "$len" ] && [ "$len" -gt 0 ]; then
		IFS= read -r -N "$len" payload || true
	fi
	if [[ "$header" == *"eventname:PROCESS_STATE_FATAL"* ]]; then
		printf '[watchdog] a process went FATAL (%s); stopping the container so Railway restarts it.\n' "$payload" >&2
		if [ -s /tmp/supervisord.pid ]; then
			kill -TERM "$(cat /tmp/supervisord.pid)" 2>/dev/null || true
		fi
	fi
	printf 'RESULT 2\nOK'
	printf 'READY\n'
done
