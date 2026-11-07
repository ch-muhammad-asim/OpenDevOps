#!/bin/sh
# Runs INSIDE herdr-hermes (piped in by e2e-test.sh test 6). Counts only, never values: how many processes carry
# NVIDIA_API_KEY in their environment, split into the Hermes process tree (expected: it loads the key from the file)
# and everything else (PID 1, herdr server, shells: expected 0); and whether the key file is mounted read-only.
hermes=0; other=0
for d in /proc/[0-9]*; do
  e="$d/environ"; [ -r "$e" ] || continue
  tr '\0' '\n' <"$e" 2>/dev/null | grep -q '^NVIDIA_API_KEY=' || continue
  case "$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)" in
    *hermes_cli*|*/hermes\ *|*/.venv/bin/hermes*|*"bin/hermes"*) hermes=$((hermes + 1)) ;;
    *) other=$((other + 1)) ;;
  esac
done
pid1=0; tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -q '^NVIDIA_API_KEY=' && pid1=1
ro=no; grep -q ' /run/secrets/nvidia_api_key .* ro[, ]' /proc/mounts && ro=yes
echo "pid1=${pid1} other=${other} hermes=${hermes} keyfile_ro=${ro}"
