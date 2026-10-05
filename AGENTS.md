# Agent workflow

## Backlog

This repository uses Backlog.md in `backlog/` as the authoritative task source.
Install the pinned CLI with `mise install`; invoke it as `mise exec -- backlog`.
Read `backlog instructions overview` and the matching task-creation,
task-execution, or task-finalization guide before that operation. Search/read
existing tasks first. Use the CLI for task changes; never edit task Markdown
by hand. Reread each task after writing it.

Claim tasks on the primary `main` checkout by setting `In Progress` and rereading
before implementation. Do not select a task already in progress. Keep backlog
state on primary `main`, including when implementation uses a worktree; the
config intentionally disables cross-branch/remote task scanning and auto-commit.
Respect dependencies. Record concrete blockers and resume conditions in the task;
`To Do` does not mean prerequisites or human gates are satisfied. Only mark Done
when acceptance criteria and delivery evidence are met. Do not push or open a PR
without explicit permission.

## Display-disable work

Read `docs/display-disable.md` for canonical direction and
`docs/display-disable-tool-survey.md` for evidence. Start with TASK-1, bounded
offline ABI verification. TASK-2 reconciles existing `recovery-enable` work;
do not duplicate its journal/helper or assume ownership of its worktree.

TASK-1 through TASK-8 authorize offline implementation/validation only, using
fake writers and no-write rehearsals. No private setter invocation (even enable
of an online display), live restoration trial, DDC write, or disruptive recovery
is authorized by a green test suite or task completion. TASK-9 and TASK-10 require
explicit scoped human approval before hardware writes. Preserve strict identity
refusal, unresolved journals and session-only transactions. Never guess IDs,
relax checks to unblock a trial, or silently escalate to logout/reboot.

Validation commands and opt-in no-write checks are in `docs/development.md` and
`docs/display-recovery.md`. Keep historical evidence separate from fresh results.
