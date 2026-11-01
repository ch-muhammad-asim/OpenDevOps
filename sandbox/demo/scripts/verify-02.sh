#!/usr/bin/env bash
# UC 02: the agent creates, reads, edits and deletes a file in its workspace.
#
#   sandbox/demo/scripts/verify-02.sh [--with-llm]
#
# Exec path: full file lifecycle in /sandbox/hermes/workspace/demo-02 (the
# writable hermes-data volume), then the same write outside the policy
# (/opt/hermes, /etc) is refused by Landlock. Leaves nothing behind.
# Landlock refusals are kernel errors (EACCES); they are not in `openshell logs`.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== verify-02: workspace files =="
W=/sandbox/hermes/workspace/demo-02
F="$W/notes.txt"

section "1. Create, read, edit, delete in $W"
out="$(sbx_sh "mkdir -p $W && echo 'hello from the sandbox' > $F && echo created")"
expect_has "create $F" "$out" created
out="$(sbx cat "$F")"; expect_has "read it back" "$out" "hello from the sandbox"
out="$(sbx_sh "sed -i 's/hello/edited/' $F && cat $F")"; expect_has "edit it (sed -i)" "$out" "edited from the sandbox"
out="$(sbx_sh "rm -f $F && rmdir $W && test ! -e $W && echo deleted")"; expect_has "delete it" "$out" deleted

section "2. Writes outside the workspace are refused (Landlock)"
out="$(sbx_sh 'touch /opt/hermes/demo-02.txt')"
expect_has "write /opt/hermes (Hermes code) refused" "$out" "Permission denied"
out="$(sbx_sh 'touch /etc/demo-02.conf')"
expect_has "write /etc refused" "$out" "Permission denied" "Read-only file system"
out="$(sbx_sh 'test -e /opt/hermes/demo-02.txt || test -e /etc/demo-02.conf && echo LEFTOVER || echo none')"
expect_has "no file was created outside the workspace" "$out" none

section "3. Prompt path (DEMO-02)"
llm_step "DEMO-02 file lifecycle" \
  "DEMO-02: Create /sandbox/hermes/workspace/demo-02/notes.txt with the text 'hello from Hermes', read it back, replace 'hello' with 'edited', show the file, then delete the file and its folder." \
  'edited'
if [ "$LLM_SENT" -eq 1 ]; then
  # Hermes's own approval guard may deny the delete (fails closed on the
  # unattended API); that is a safe outcome, not a failure. reset.sh cleans up.
  out="$(sbx_sh "test -e $W && echo LEFTOVER || echo clean")"
  case "$out" in
    *clean*) pass "workspace clean after the prompt" ;;
    *) info "the agent's delete was not carried out (Hermes approval guard denied it); reset.sh removes $W" ;;
  esac
fi

finish
