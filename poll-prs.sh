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

  # Fetch open non-draft PRs — filtered to ones requesting the bot as reviewer (if BOT_GITHUB_USER set)
  if [[ -n "$BOT_GITHUB_USER" ]]; then
    JQ_FILTER=".[] | select(.draft == false) | select(.requested_reviewers[]?.login == \"$BOT_GITHUB_USER\") | \"\(.number) \(.head.sha) \(.title)\""
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
    PROMPT="You are a senior code reviewer for the BAW/CP4BA platform team. Review this GitHub PR diff for the repo '$REPO'.

PR Title: $PR_TITLE

Provide structured feedback on:
1. **Correctness / Bugs** — logic errors, off-by-ones, null/undefined handling
2. **Security** — injections, exposed secrets, insecure defaults
3. **Performance** — unnecessary loops, blocking calls, missing indexes
4. **Code Style** — naming clarity, readability, DRY violations
5. **Tests** — missing coverage, untested edge cases

Reference specific filenames and line numbers. Be concise and actionable. Format output in markdown.

\`\`\`diff
$DIFF_TRIMMED
\`\`\`"

    log "Sending diff to IBM Bob AI..."
    BOB_OUTPUT=$(bob run --log-level silent \
                 --disable-mcp \
                 --disable-subagents \
                 "$PROMPT" 2>>"$LOG_FILE") || {
      log "ERROR: Bob AI review failed for PR #$PR_NUMBER"
      continue
    }
    # Bob pretty output contains "Assistant (N) ... ────" sections
    # Extract everything between the last "Assistant (N)" header and the "Task Summary" footer
    REVIEW=$(echo "$BOB_OUTPUT" | awk '/^Assistant \([0-9]+\)/{found=1; buf=""; next} found && /^Task Summary/{exit} found{buf=buf"\n"$0} END{print buf}' | sed 's/^[[:space:]]*//')
    if [[ -z "$REVIEW" ]]; then
      # Fallback: strip the header/footer separator lines, keep the middle
      REVIEW=$(echo "$BOB_OUTPUT" | grep -v '^─\+$' | grep -v '^Task Summary' | grep -v '^Total ' | grep -v '^Assistant Messages' | grep -v '^Tool Calls' | grep -v '^Task ID' | sed '/^User ([0-9]*)/,/^Assistant ([0-9]*)/d' | sed '/^\s*$/N;/^\n$/d')
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
