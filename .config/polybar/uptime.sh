#!/usr/bin/env bash
uptime -p | sed -E 's/up //; s/ years?/y/; s/ weeks?/w/; s/ days?/d/; s/ hours?/h/; s/ minutes?/m/; s/,//g'
