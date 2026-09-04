# baw-cd-pr-reviewer-bot

An automated PR reviewer bot that polls GitHub repositories every 20 minutes, sends PR diffs to IBM Bob AI, and posts structured code review comments — running on a RHEL machine.

## How it works

```
RHEL cron (every 20 min)
        ↓
poll-prs.sh
        ↓
gh api → fetch open PRs for each watched repo
        ↓
For each new/updated PR (tracked by commit SHA):
        ↓
gh api → fetch PR diff
        ↓
bob -p "review this diff" → IBM Bob AI
        ↓
gh api → post review comment as bot user
        ↓
state file written (prevents duplicate reviews)
```

## Directory layout (on RHEL)

```
/opt/baw-cd-pr-reviewer-bot/
├── poll-prs.sh          # main bot script
├── repos.txt            # list of repos to watch
├── state/               # SHA-based reviewed markers
└── logs/
    ├── review.log       # detailed per-review log
    └── cron.log         # cron stdout/stderr

/etc/baw-cd-pr-reviewer-bot/
└── config.env           # credentials (not in git)
```

## Installation on RHEL

```bash
# Clone the repo
git clone https://github.com/ananthram001/baw-cd-pr-reviewer-bot.git
cd baw-cd-pr-reviewer-bot

# Run installer as root
sudo bash install.sh
```

## Configuration

### 1. Set credentials

```bash
vi /etc/baw-cd-pr-reviewer-bot/config.env
```

```bash
BOBSHELL_API_KEY=bob_prod_bob-user_XXXX...   # your IBM Bob token
GH_TOKEN=ghp_XXXX...                          # bot GitHub account PAT (repo scope)
```

### 2. Add repos to watch

```bash
vi /opt/baw-cd-pr-reviewer-bot/repos.txt
```

```
# One repo per line: owner/repo
ibm/my-baw-repo
myorg/cp4ba-automation
```

### 3. Test manually

```bash
source /etc/baw-cd-pr-reviewer-bot/config.env
/opt/baw-cd-pr-reviewer-bot/poll-prs.sh
```

### 4. Watch logs

```bash
tail -f /opt/baw-cd-pr-reviewer-bot/logs/review.log
```

## Cron schedule

Installed automatically by `install.sh`:

```
*/20 * * * * source /etc/baw-cd-pr-reviewer-bot/config.env && /opt/baw-cd-pr-reviewer-bot/poll-prs.sh
```

To change frequency:
```bash
crontab -e
```

## Re-review behaviour

- Each PR is tracked by `repo + PR number + commit SHA`
- When a new commit is pushed to an open PR, the SHA changes → bot reviews again automatically
- Closed/merged PRs are ignored (only `state=open` PRs are polled)

## Logs

```bash
# Live review log
tail -f /opt/baw-cd-pr-reviewer-bot/logs/review.log

# Cron execution log
tail -f /opt/baw-cd-pr-reviewer-bot/logs/cron.log
```

## Requirements

- RHEL 8/9
- Node.js 20+
- GitHub CLI (`gh`)
- IBM Bob Shell (`@bob-shell/cli`)
- `jq`
