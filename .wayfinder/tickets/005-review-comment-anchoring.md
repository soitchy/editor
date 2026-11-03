---
id: 005
title: How review comments are stored and re-anchored
type: wayfinder:research
status: closed
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# How review comments are stored and re-anchored

## Question

How do diffity, GitHub, and other review tools persist comment threads, and how do they keep a comment attached to the right lines as the code under it changes (line+context matching, diff-mapping, content hashes, outdated markers)? Which approaches work for plain files that an agent could also read?

## Resolution

Findings: branch `research/review-comment-anchoring`, file `research/review-comment-anchoring.md`. Sources: diffity's source, the GitHub API docs, and the Gerrit, Phabricator and git-appraise source.

- **diffity storage:** one SQLite file (`diffity.db`) in the app data folder, not the repo. Agents only reach threads through its MCP tools while the app runs, so it doesn't meet our offline goal.
- **diffity anchoring:**
  - The anchor is view ref, path, side, start/end line, and `anchor_content` (the exact anchored text).
  - It never shifts line numbers; it checks the stored text against a fresh diff and labels each thread current, outdated or file-gone.
- **Every system** keeps the original anchor unchanged and works out the current position when threads are read.
- **GitHub** keeps original_line, original_commit_id and diff_hunk beside the live line. A thread goes outdated only when its anchored line changes.
- **Gerrit and Phabricator** map lines through a diff with a running offset.
  - Gerrit falls back to a file comment, then a change-level one, and never drops a comment.
  - Phabricator shows ported copies as display-only "ghosts".
- **git-appraise** stores one JSON object per line in git notes, which merge cleanly. Comments are pinned to a commit with no re-anchoring, and are lost on rebase unless note copying is configured.
- **The researcher suggests:**
  - One file per thread in a gitignored dot-folder, with replies and status changes appended.
  - A fixed anchor: path, side, base commit, line range, exact text and a few context lines.
  - Tiered re-anchoring: exact match, then shift through `git diff`, then search by the stored text, then mark outdated and fall back to file-level.

To decide in [Comment storage and anchoring](011-comment-storage-anchoring.md).
