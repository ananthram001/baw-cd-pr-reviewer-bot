#!/bin/bash
# =============================================================================
# baw-cd-pr-reviewer-bot — Poll open PRs and post AI reviews via IBM Bob Shell
# =============================================================================

set -euo pipefail

# ── Credentials (overridden by /etc/baw-cd-pr-reviewer-bot/config.env) ──────
: "${BOBSHELL_API_KEY:?ERROR: BOBSHELL_API_KEY is not set}"
: "${GH_TOKEN:?ERROR: GH_TOKEN is not set}"
export BOBSHELL_API_KEY
export GH_TOKEN

# GitHub host — set to github.ibm.com for IBM internal GHE, or github.com for public
GH_HOST="${GH_HOST:-github.com}"
export GH_HOST

# GitHub username of the bot account — only review PRs where this user is a requested reviewer
# Set to empty string "" to review ALL open PRs regardless
BOT_GITHUB_USER="${BOT_GITHUB_USER:-ananthram001}"

# ── Paths ────────────────────────────────────────────────────────────────────
BASE_DIR="/opt/baw-cd-pr-reviewer-bot"
STATE_DIR="$BASE_DIR/state"
LOG_FILE="$BASE_DIR/logs/review.log"
REPOS_FILE="$BASE_DIR/repos.txt"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── Load repos list ──────────────────────────────────────────────────────────
if [[ ! -f "$REPOS_FILE" ]]; then
  log "ERROR: repos list not found at $REPOS_FILE"
  exit 1
fi

mapfile -t REPOS < <(grep -v '^\s*#' "$REPOS_FILE" | grep -v '^\s*$')

if [[ ${#REPOS[@]} -eq 0 ]]; then
  log "No repos configured in $REPOS_FILE — nothing to do"
  exit 0
fi

log "====== baw-cd-pr-reviewer-bot poll cycle started ======"
log "Watching ${#REPOS[@]} repo(s)"

# ── Main loop ────────────────────────────────────────────────────────────────
for REPO in "${REPOS[@]}"; do
  REPO=$(echo "$REPO" | xargs)  # trim whitespace
  log "--- Checking $REPO ---"

  # Fetch open non-draft PRs:
  #   - PRs where BOT_GITHUB_USER is a requested reviewer, OR
  #   - PRs authored by BOT_GITHUB_USER (can't self-request review)
  if [[ -n "$BOT_GITHUB_USER" ]]; then
    JQ_FILTER=".[] | select(.draft == false) | select(
      (.requested_reviewers[]?.login == \"$BOT_GITHUB_USER\") or
      (.user.login == \"$BOT_GITHUB_USER\")
    ) | \"\(.number) \(.head.sha) \(.title)\""
  else
    JQ_FILTER='.[] | select(.draft == false) | "\(.number) \(.head.sha) \(.title)"'
  fi

  PR_LIST=$(gh api --hostname "$GH_HOST" "repos/$REPO/pulls?state=open&per_page=50" \
    --jq "$JQ_FILTER" \
    2>>"$LOG_FILE") || {
    log "ERROR: Could not fetch PRs for $REPO (check token permissions)"
    continue
  }

  if [[ -z "$PR_LIST" ]]; then
    log "No open PRs in $REPO"
    continue
  fi

  while IFS= read -r LINE; do
    PR_NUMBER=$(echo "$LINE" | awk '{print $1}')
    PR_SHA=$(echo "$LINE"    | awk '{print $2}')
    PR_TITLE=$(echo "$LINE"  | cut -d' ' -f3-)

    # SHA-based state file — re-review on every new push
    REPO_SLUG="${REPO//\//_}"
    STATE_FILE="$STATE_DIR/${REPO_SLUG}_PR${PR_NUMBER}_${PR_SHA}.reviewed"

    if [[ -f "$STATE_FILE" ]]; then
      log "PR #$PR_NUMBER [$PR_SHA] already reviewed — skipping"
      continue
    fi

    log "Reviewing PR #$PR_NUMBER: $PR_TITLE"

    # ── Fetch diff ────────────────────────────────────────────────────────
    DIFF=$(gh api --hostname "$GH_HOST" "repos/$REPO/pulls/$PR_NUMBER" \
      -H "Accept: application/vnd.github.v3.diff" 2>>"$LOG_FILE") || {
      log "ERROR: Could not fetch diff for PR #$PR_NUMBER"
      continue
    }

    if [[ -z "$DIFF" ]]; then
      log "Empty diff for PR #$PR_NUMBER — skipping"
      continue
    fi

    DIFF_TRIMMED=$(echo "$DIFF" | head -c 12000)
    TRUNCATED_MSG=""
    if [[ ${#DIFF} -gt 12000 ]]; then
      TOTAL_LINES=$(echo "$DIFF" | wc -l)
      TRUNCATED_MSG=$'\n\n> ⚠️ Diff was large and trimmed to 12,000 characters ('"$TOTAL_LINES"' lines total). Only the first portion was reviewed.'
    fi

    # ── Bob AI review ─────────────────────────────────────────────────────
    PROMPT="You are a polite, constructive code reviewer for the BAW/CP4BA platform team. Review the GitHub PR diff below for the repo '$REPO'.

PR Title: $PR_TITLE

---

## Review Guidelines

**Tone:** Always be polite and collaborative. Never blame anyone. Instead of saying 'you broke this' or 'this is wrong', use language like:
- 'Can we add a check here for...'
- 'Could we consider...'
- 'Would it be worth handling the case where...'
- 'Might be good to verify...'

**Never approve the PR.** Your job is only to add review comments. If everything looks good, end with exactly:
> Looks good to me — By PR Reviewer Bot

---

## What to check

### 1. 🔐 Secrets & Credentials
- Scan for any hardcoded passwords, tokens, API keys, certificates, or secrets exposed in the diff.
- Flag any environment variables that look like secrets being logged or printed.
- Suggest using secret managers or environment variables instead.

### 2. 🔄 Backward Compatibility & Feature Flag Safety
- If existing functionality or a method is modified, check whether the change could break the existing flow.
- Specifically look for: new features or integrations (e.g. a new auth provider, a new flag, a new config) where the code works WITH the new feature but the old path (without the feature) was not tested or guarded.
- Example pattern to flag: 'This adds Okta support, but can we add a check so that when Okta is not configured, the existing login flow still works as before?'
- Check for missing null/undefined/empty checks on newly introduced config or flags.

### 3. 🐛 Defect Fix Analysis (only if this PR is fixing a bug)
- Analyse what caused the defect based on the diff.
- Identify what commit or change likely introduced the regression — mention commit hashes or filenames visible in the diff context, do not blame any individual.
- Summarise: what was the root cause, what the fix does, and whether the fix fully addresses the root cause or is a partial workaround.
- Note if a similar pattern exists elsewhere in the codebase that may need the same fix.

### 4. ⚡ Performance (new code only)
- Look only at the newly added lines (lines starting with + in the diff).
- Flag any performance concerns introduced by the new code only — do not comment on pre-existing code.
- Look for: unnecessary loops over large collections, repeated expensive calls inside loops, blocking operations, redundant file reads/writes, missing caching opportunities, spawning excessive subprocesses.
- If no performance issues in the new code, write: '✅ No issues found in new code.'

### 5. 🧪 Test Coverage
- Check if the PR includes tests for the changed behaviour.
- If not, suggest specific test cases — especially for the backward compatibility paths identified in point 2.

---

## Output Format

Use markdown. Be specific — reference filenames and line numbers from the diff where relevant.
Keep comments short and actionable. One comment per finding.
Group findings under the section headings above.
If a section has no findings, write: '✅ No issues found.'

At the end, add a brief **Summary** with a count of findings by severity (🔴 Must Fix / 🟠 Should Fix / 🟡 Nice to Have).

If there are zero findings across all sections, output only:
> Looks good to me — By PR Reviewer Bot

---

\`\`\`diff
$DIFF_TRIMMED
\`\`\`"

    log "Sending diff to IBM Bob AI..."
    # Write prompt to temp file — avoids shell quoting issues with large diffs
    PROMPT_FILE=$(mktemp /tmp/bob_prompt_XXXXXX.txt)
    BOB_OUT_FILE=$(mktemp /tmp/bob_out_XXXXXX.txt)
    echo "$PROMPT" > "$PROMPT_FILE"

    bob run --log-level silent \
        --disable-mcp \
        --disable-subagents \
        "$(cat "$PROMPT_FILE")" > "$BOB_OUT_FILE" 2>>"$LOG_FILE" || {
      log "ERROR: Bob AI review failed for PR #$PR_NUMBER"
      rm -f "$PROMPT_FILE" "$BOB_OUT_FILE"
      continue
    }
    rm -f "$PROMPT_FILE"

    # Bob pretty output structure:
    #   <separator line of ─ chars>
    #   User (N) <timestamp>
    #   <prompt text>
    #   <separator line of ─ chars>
    #   Assistant (N) <timestamp>
    #   <REVIEW TEXT WE WANT>
    #   <separator line of ─ chars>
    #   Task Summary
    #   ...
    #
    # Strategy: grab everything after the LAST "Assistant (" line, stop at "Task Summary"
    REVIEW=$(awk '
      /Assistant \(/ { found=1; buf=""; next }
      found && /^Task Summary/ { exit }
      found { buf = buf $0 "\n" }
      END { printf "%s", buf }
    ' "$BOB_OUT_FILE" | sed '/^[[:space:]]*$/{ N; /^\n[[:space:]]*$/d }' | sed 's/^[[:space:]]*//')

    rm -f "$BOB_OUT_FILE"

    if [[ -z "$REVIEW" ]]; then
      log "WARNING: Could not extract review text from Bob output for PR #$PR_NUMBER"
      REVIEW="Bob AI processed this PR but the review output could not be parsed. Check /opt/baw-cd-pr-reviewer-bot/logs/review.log for details."
    fi

    # ── Post comment via bot identity ─────────────────────────────────────
    COMMENT_BODY="## 🤖 BAW-CD PR Review Bot

$REVIEW
$TRUNCATED_MSG

---
*Posted by **baw-cd-pr-reviewer-bot** · Powered by IBM Bob AI · $(date '+%Y-%m-%d %H:%M %Z')*"

    gh api --hostname "$GH_HOST" "repos/$REPO/issues/$PR_NUMBER/comments" \
      --method POST \
      --field body="$COMMENT_BODY" >> "$LOG_FILE" 2>&1 && {
      log "✅ Review posted for PR #$PR_NUMBER in $REPO"
      touch "$STATE_FILE"
    } || {
      log "ERROR: Failed to post comment for PR #$PR_NUMBER in $REPO"
    }

    sleep 5  # rate-limit guard between PRs

  done <<< "$PR_LIST"

done

log "====== Poll cycle complete ======"
