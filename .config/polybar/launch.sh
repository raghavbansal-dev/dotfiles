#!/usr/bin/env bash
polybar-msg cmd quit 2>/dev/null
sleep 0.3
polybar main >/dev/null 2>&1 &
disown
