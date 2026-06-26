# `GPT/advice/`

Status-1 Claude (advice-only — see `/CLAUDE.md`) writes recommendations
here. One file per UTC date: `GPT/advice/YYYY-MM-DD.md`. Append within
the day; new file at UTC midnight.

Each entry is a short section beginning `## HH:MM UTC — <subject>` with
four labeled fields: **Context**, **Recommendation**, **Why**, **How to
verify**.

Mr. Hinds reads these between runs, picks which to apply, and commits
the resulting changes himself. Claude does not edit anything else at
status 1 and does not run git, ever.

This directory is committed so advice survives across sessions and is
visible to every Claude that opens the repo on any machine.
