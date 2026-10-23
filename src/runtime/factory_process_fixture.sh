#!/bin/sh
# Deliberately no provider handshake: exercises process ownership before readiness.
exec /bin/cat
