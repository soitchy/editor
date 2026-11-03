# Review comment anchoring and persistence

Research question: how do diffity, GitHub, Gerrit, Phabricator and local tools
(git-appraise / git notes) persist review threads, and how do they keep a
comment attached to the right lines as code changes? Which approaches suit
plain files that both the editor and a coding agent can read and write?

Researched 2026-11-03. Sources are primary (source code, official API docs)
unless noted. diffity source read at commit
[`8abe0d1`](https://github.com/nilbuild/diffity/tree/8abe0d1150e7adf7331a399960c6e543741935bb).

## TL;DR

- **Nobody does magic.** Every system stores a *frozen* anchor (path + side +
  line range + the commit/patch set it was written against) and computes the
  "current" position at read time. When it can't, the thread is marked
  *outdated* or demoted to a coarser target (file, then whole change). The
  original anchor is never overwritten.
- Two re-anchoring techniques show up in real systems:
  1. **Map line numbers through a diff** between the anchor revision and the
     target revision (Gerrit, Phabricator). Lines outside changed hunks shift by
     the running offset; a range that overlaps a changed hunk is a "conflict".
  2. **Snapshot the anchored text and compare** (diffity's `anchor_content`;
     GitHub stores `diff_hunk` and the original line/commit). If the text at
     the stored position no longer matches, it is outdated.
- GitHub's rule since 2018: a thread goes outdated only when *the anchored
  line itself* changes. Edits elsewhere just shift it.
- **diffity stores everything in a single SQLite database** (`diffity.db` in the
  app's data dir), *not* in the repo. Agents reach threads only through its MCP
  tools while the app is running. So diffity doesn't meet our "readable
  without a live connection" goal.
- git-appraise is the only surveyed tool whose storage is text an agent could
  read: one JSON object per line, in git notes. But notes live in refs, not the
  working tree, and it does no re-anchoring at all.
- **Recommendation (inference, see the last section):** one plain file per
  thread in a gitignored dot-folder. Store a frozen anchor:
  `{path, side, base commit SHA, start/end line, exact anchored text, a few
  context lines}`. Re-anchor at read time in tiers: exact match at the stored
  lines, then shift through `git diff`, then fuzzy search by snippet and
  context, then *outdated* with fallback to a file-level thread. Write any
  computed position back as a separate "current" field, never over the
  original.

## diffity

### Storage

- A SQLite database opened at `app_data_dir()/diffity.db`
  ([`src-tauri/src/lib.rs` L47-49](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/lib.rs#L47-L49)).
  It is per-user, outside the repo, and keyed by `repo_path`.
- Schema ([`src-tauri/src/core/store.rs` L15-109](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/core/store.rs#L15-L109)):
  - `review_sessions(repo_path, ref)`: one session per diff "view" (`work`,
    `staged`, `main...feature`, `<sha>~1..<sha>`, ...). Later migrations add a
    branch `scope`.
  - `threads(id, session_id, file_path, side, start_line, end_line, status,
    severity, anchor_content, github_thread_id, ...)`. Later columns are
    `review_id`, `view_ref` and `promoted_from`
    ([`THREAD_COLS` L478](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/core/store.rs#L478)).
  - `comments(id, thread_id, author_type, author_name, body, created_at,
    pending, review_id, github_comment_id)`.
  - `viewed_files(session_id, file_path, content_hash)` uses a content hash for
    "viewed" state only, not for anchoring.
- Thread kinds are encoded in `file_path`/`start_line`:
  - A sentinel `GENERAL_FILE_PATH` marks a whole-diff thread.
  - `start_line == 0` marks a file-level thread.
  - A `__path__:` prefix marks a folder or file comment in the tree view
    ([`repo_threads.rs` L15-16, L250-259](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/core/repo_threads.rs#L250-L259)).
- Agents talk to it over MCP (a local socket `mcp.sock` in the data dir,
  [`agents/bridge.rs` L48-49](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/agents/bridge.rs#L48)).
  The tools are `get_diff`, `list_threads`, `add_comment`,
  `add_general_comment`, `reply` and `resolve`
  ([`agents/tools.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/agents/tools.rs)).
  `resolve` is refused if the user rejected an edit in that turn (L53-55).

### Anchoring

- **Anchor = view ref + path + side (old/new) + start/end line +
  `anchor_content`.** `anchor_content` is the exact text of the anchored lines
  joined by `\n`. When an agent posts with only `file`/`line`, the server
  computes `anchor_content` from the current patch
  ([`tools.rs` L367-373](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/agents/tools.rs#L367-L373)).
  The agent never has to supply it.
- **Status at read time** comes from `ViewIndex::anchor`
  ([`repo_threads.rs` L163-177](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/core/repo_threads.rs#L163-L177)).
  It re-runs the view's diff, indexes the hunk lines per side, and returns:
  - `ViewEmpty` if the view has no changes.
  - `Current` for general threads.
  - `FileGone` if the path is not in the diff.
  - `Current` if *any* line in `start..=end` is still inside a hunk.
  - Otherwise `Outdated`.
- **Line numbers are never shifted.** A thread keeps its stored numbers and is
  checked against the fresh diff at those same numbers.
- **"Moved to commit"**: after you commit, a working-tree thread can stop
  anchoring. diffity then checks whether the `HEAD` commit's diff has the same
  lines *with identical text* (`matches_anchor`, which compares
  `anchor_content`). If so, it points the thread at that commit
  ([`repo_threads.rs` L179-191, L322-329](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/core/repo_threads.rs#L322-L329)).
- **UI outdated badge**: the frontend marks a thread outdated when
  `thread.anchorContent !== currentCode`
  ([`comment-thread.tsx` L91-92](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src/components/comments/comment-thread.tsx#L91-L92)).
  The comments panel shows the frozen `anchorContent` snippet for outdated
  threads
  ([`comments-panel.tsx` L131-145](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src/features/comments/comments-panel.tsx#L131-L145)).
  Suggestions use the same comparison
  ([`suggestion-block.tsx` L41-46](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src/features/suggestions/suggestion-block.tsx#L41-L46)).
- **GitHub sync** reads GitHub's `isOutdated`, `line`, `originalLine`, etc. over
  GraphQL rather than computing them itself
  ([`github/graphql.rs` L363](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/github/graphql.rs#L363)).

**Takeaway:** diffity's model is simple and useful. Its weaknesses are that
positions never shift, so a thread goes outdated as soon as lines above it
move, and that storage is a private DB.

## GitHub pull request review comments

- **REST fields** ([Pull request review comments API](https://docs.github.com/en/rest/pulls/comments)):
  - `position` is the legacy diff-relative index ("the line just below the
    `@@` line is position 1"). The docs say it "is closing down. Use `line`
    instead."
  - `line`/`start_line` are file line numbers in the PR diff blob.
  - `side`/`start_side` are `LEFT` or `RIGHT`.
  - `subject_type` is `line` or `file`.
  - On `commit_id`: "Not using the latest commit SHA may render your comment
    outdated if a subsequent commit modifies the line you specify."
  - Responses also carry `original_line`, `original_start_line`,
    `original_position`, `original_commit_id` and `diff_hunk`, so the frozen
    anchor and a text snapshot (the hunk) are kept next to the live position.
  - Threads are flat: "Replies to replies are not supported."
- **GraphQL** ([Pulls reference](https://docs.github.com/en/graphql/reference/pulls)):
  - `PullRequestReviewThread` has `isOutdated` ("whether this thread was
    outdated by newer changes"), `isResolved`, `line`, `originalLine`,
    `startLine`, `originalStartLine`, `diffSide` and `subjectType`.
  - `PullRequestReviewComment` has `commit`, `originalCommit`, `diffHunk` and
    `outdated`. `position`/`originalPosition` are deprecated ("We are phasing out
    diff-relative positioning").
  - diffity's own test fixtures show outdated threads coming back with
    `line: null`
    ([`github/review.rs` L239-245](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/github/review.rs#L239-L245)).
- **Outdating rule:** GitHub's
  [2018 changelog](https://github.blog/changelog/2018-09-25-precision-review-comment-outdating/)
  says conversations now go outdated only "when the line of code that started
  the conversation is changed". So GitHub maps through the diff and goes
  outdated only on a conflict at the anchored line. The algorithm itself is not
  public.

## Gerrit

- **Storage (NoteDb)** ([NoteDb docs](https://gerrit-review.googlesource.com/Documentation/note-db.html)):
  - Each change has a notes branch `refs/changes/NN/NNNNN/meta`.
  - Inline comments live in a NoteMap "where the key is the commit SHA-1 of the
    patchset that the comment refers to". The values are JSON
    (`RevisionNoteData`).
  - Each JSON comment has fields like `key{uuid, filename, patchSetId}`,
    `lineNbr`, `range`, `side`, `revId`, `unresolved`, `message`, `author` and
    `writtenOn`.
- **API entity** ([`CommentInfo`, REST changes API](https://gerrit-review.googlesource.com/Documentation/rest-api-changes.html)):
  - `patch_set`, `path`, `side` (`REVISION`/`PARENT`), `line`, and `range`
    (start/end line plus character).
  - `in_reply_to` (a UUID) and `commit_id` (the 40-char SHA the comment
    applies to).
  - `unresolved`: "The state of resolution of a comment thread is stored in the
    last comment in that thread chronologically". Resolution is per-comment and
    append-only, not a mutable thread field.
  - `context_lines` is available on request.
  - "If neither line nor range is set, it's a file comment."
- **Re-anchoring: "ported comments"**
  (`GET .../revisions/{rev}/ported_comments`, same doc):
  - Comments are ported from earlier patch sets to the requested one.
  - The response keeps the original attributes "except for these attributes:
    path, line, and range point to the computed position in the target
    revision".
  - When the exact position can't be determined, Gerrit uses "the next best
    position", which "can also mean ... converting the comment to a file comment
    (or even moving the comment to a different file or the patchset level)".
  - For copied files, Gerrit may return the same comment twice. Results may
    differ between calls.
- **Algorithm** ([`GitPositionTransformer.java`](https://gerrit.googlesource.com/gerrit/+/refs/heads/master/java/com/google/gerrit/server/patch/GitPositionTransformer.java),
  [`CommentPorter.java`](https://gerrit.googlesource.com/gerrit/+/refs/heads/master/java/com/google/gerrit/server/restapi/change/CommentPorter.java)):
  - Map the file path through renames and copies.
  - Then walk the file top-down, keeping a running line shift from the diff's
    edit ranges. Positions are shifted by that amount.
  - If a position overlaps an edited range, apply a conflict strategy.
    `BestPositionOnConflict` (used for ported comments) drops the line range
    but keeps the file. A deleted file drops to the patchset level, and the
    strategy "will never drop any Position".
  - `OmitPositionOnConflict` (used for rebase edits) drops the position.
  - Diff errors fall back to treating all files as deleted, so comments land at
    patchset level.
  - The ported position is computed per request. The stored comment is never
    rewritten.

## Phabricator (Differential)

- **Storage:** inline comments are database rows tied to a *changeset* (one file
  in one diff), with `isNewFile` (side), `lineNumber`, `lineLength` and
  reply/`fixedState` fields. Ported comments are made in memory as "ghost"
  copies (`makeEphemeral(true)`, `setIsGhost([...originalID, href, reason])`)
  and are never re-saved
  ([`PhabricatorInlineCommentAdjustmentEngine.php` L224-243](https://github.com/phacility/phabricator/blob/master/src/infrastructure/diff/engine/PhabricatorInlineCommentAdjustmentEngine.php#L224-L243)).
- **Algorithm:**
  - Match changesets by filename, including move/rename targets
    (L106-222).
  - Then chain `DifferentialLineAdjustmentMap`s across the diff update and
    rebase, and map the head and tail lines of the comment range (L266-365).
  - The map "follows lines of code across source changes ... if the next update
    adds 15 more lines above it, the comment should move down to line 45"
    ([`DifferentialLineAdjustmentMap.php` L4-9](https://github.com/phacility/phabricator/blob/master/src/applications/differential/parser/DifferentialLineAdjustmentMap.php#L4-L9)).
  - When the anchored lines were deleted, the range collapses or stretches to
    the surrounding surviving lines rather than vanishing.
  - Users can turn ghosts off with a setting (L67-70).
- Phabricator is no longer maintained upstream. Its design is still a clean
  reference for "map through diff, show as ghost".

## git-appraise (git notes)

- **Storage**
  ([README "Metadata"](https://github.com/google/git-appraise/blob/master/README.md#metadata)):
  - Data lives in git notes under `refs/notes/devtools/*`. Review comments go in
    `refs/notes/devtools/discuss` and are attached to the review's first
    commit.
  - "Each item stored is written as a single line of JSON ... This allows the
    git notes to be automatically merged using the `cat_sort_uniq` strategy."
  - Edits are new lines with `original` pointing to the edited comment, so the
    log is append-only.
- **Schema**
  ([`review/comment/comment.go`](https://github.com/google/git-appraise/blob/master/review/comment/comment.go)):
  - `Comment{timestamp, author, original, parent, location, description,
    resolved, v}`.
  - `Location{commit, path, range{startLine, startColumn, endLine,
    endColumn}}`. No path means a whole-commit comment, and no range means a
    file comment.
- **Anchoring:** pinned to `location.commit`. `Location.Check` only checks that
  the line exists in that commit. There is no porting or outdated logic in the
  codebase (grep for outdated/remap finds nothing).
- **git notes caveats** ([git-notes docs](https://git-scm.com/docs/git-notes)):
  - Notes attach to object IDs, so a rebase or amend orphans them. Copying
    needs `notes.rewriteRef` set ("Does not have a default value").
  - `cat_sort_uniq` concatenates, sorts and de-duplicates lines, which is why
    git-appraise uses one JSON object per line.
  - Notes live in refs, not the working tree. An agent needs `git notes show`
    to read them, not a plain file read.

## Approaches compared

| Approach | Used by | Survives edits above anchor | Detects anchored text changed | Needs git history | Plain-file friendly |
|---|---|---|---|---|---|
| Line numbers only, at a commit SHA | git-appraise | no (only valid at that commit) | no | yes | yes |
| Line numbers + re-check same numbers in fresh diff | diffity (`ViewIndex::anchor`) | no (goes outdated) | partly | yes | yes |
| Snapshot of anchored text, compared | diffity (`anchor_content`), GitHub (`diff_hunk`) | only with a search step | yes | no | yes |
| Map through diff (running line shift, conflict means outdated or demote) | Gerrit, Phabricator, GitHub (behaviour) | yes | yes (conflict = overlap with an edit) | yes, or a stored snapshot of the base | yes, if base SHA or snapshot is stored |
| Demote on failure: line, then file, then change | Gerrit `BestPositionOnConflict` | n/a | n/a | n/a | yes |
| Keep original anchor and compute current position at read time | all of the above | n/a | n/a | n/a | yes |
| Content hash of the file | diffity (viewed-files only) | no | file-level only | no | yes |

No system surveyed uses context-line fuzzy matching (patch(1)-style fuzz) for
comments. It's a reasonable extra tier, but it is not taken from any source
here.

## Implications for our editor (recommendation)

Everything in this section is inference from the evidence above, not something
any one source prescribes.

1. **Storage:** use one file per thread in a gitignored dot-folder (e.g.
   `.review/threads/<id>.json` or `.md` with front-matter).
   - One file per thread means the editor and an agent rarely write the same
     file at once.
   - Append replies and status changes rather than rewriting history, as
     git-appraise and Gerrit's "last comment wins" resolution do. Then
     concurrent writers can be reconciled.
   - This gives what diffity's SQLite DB and git-appraise's notes refs can't: an
     agent can `cat`/`grep` it with no app running.
2. **Frozen anchor** per thread, never mutated:
   - `path` and `side` (old/new).
   - `base` (the commit SHA, or the view ref plus the HEAD SHA at creation).
   - `start_line`/`end_line` (0 means file-level; a sentinel means whole diff).
   - `anchor_text`: the exact lines, as diffity's `anchor_content`.
   - Optionally 2-3 lines of context before and after.
3. **Agent writes stay minimal:** like diffity's `add_comment`, accept just
   `path` + line(s) + body from the agent. The editor fills `anchor_text` and
   `base` when it ingests the thread, or a validation pass does. A raw agent
   write is still valid on its own.
4. **Re-anchor at read time**, in tiers:
   1. Text at the stored lines equals `anchor_text`: *current*.
   2. Map the stored lines through `git diff <base> -- path` (or through the
      editor's live edit log for unsaved buffers) with a running offset, as
      Gerrit and Phabricator do. If the mapped lines still equal
      `anchor_text`: *current (moved)*.
   3. Search the file near the mapped position for `anchor_text`, using the
      context lines to break ties: *moved* (an extension; no source does this).
   4. Otherwise *outdated*: show the frozen snippet, as diffity's panel does,
      and demote to file-level, then diff-level, as Gerrit's
      `BestPositionOnConflict` does.
   Optionally cache the result as a separate `current: {line, status, at_sha}`
   field so an offline agent sees it, but treat it as derived.
5. **Thread scopes** to model: line range, file, and whole diff. This matches
   GitHub's `subject_type`, Gerrit's file and patchset-level comments, and
   diffity's sentinels.

## Sources

- diffity source at `8abe0d1`: [`store.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/core/store.rs), [`repo_threads.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/core/repo_threads.rs), [`lib.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/lib.rs), [`agents/tools.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/agents/tools.rs), [`comment-thread.tsx`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src/components/comments/comment-thread.tsx)
- GitHub: [REST review comments](https://docs.github.com/en/rest/pulls/comments), [GraphQL pulls reference](https://docs.github.com/en/graphql/reference/pulls), [Precision review comment outdating (2018 changelog)](https://github.blog/changelog/2018-09-25-precision-review-comment-outdating/)
- Gerrit: [REST changes API (CommentInfo, ported_comments)](https://gerrit-review.googlesource.com/Documentation/rest-api-changes.html), [NoteDb](https://gerrit-review.googlesource.com/Documentation/note-db.html), [`GitPositionTransformer.java`](https://gerrit.googlesource.com/gerrit/+/refs/heads/master/java/com/google/gerrit/server/patch/GitPositionTransformer.java), [`CommentPorter.java`](https://gerrit.googlesource.com/gerrit/+/refs/heads/master/java/com/google/gerrit/server/restapi/change/CommentPorter.java)
- Phabricator: [`PhabricatorInlineCommentAdjustmentEngine.php`](https://github.com/phacility/phabricator/blob/master/src/infrastructure/diff/engine/PhabricatorInlineCommentAdjustmentEngine.php), [`DifferentialLineAdjustmentMap.php`](https://github.com/phacility/phabricator/blob/master/src/applications/differential/parser/DifferentialLineAdjustmentMap.php)
- git-appraise: [README](https://github.com/google/git-appraise/blob/master/README.md), [`comment.go`](https://github.com/google/git-appraise/blob/master/review/comment/comment.go); [git-notes docs](https://git-scm.com/docs/git-notes)
