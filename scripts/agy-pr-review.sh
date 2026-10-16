#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Run the pr-review skill against a PR using the Antigravity CLI (agy) in headless mode.
set -euo pipefail

# Silence prek in throwaway worktrees that may lack hook configurations
export PREK_ALLOW_NO_CONFIG=1

# Default to Gemini 3.7 Flash (High) for generous quota limits and fast turnaround. See `agy models`.
MODEL="${AGY_PR_REVIEW_MODEL:-gemini-3.7-flash-high}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--local-only] [--model MODEL] [PR_NUMBER]

Reviews a pull request with the pr-review skill via headless agy.

  PR_NUMBER     PR to review (default: open PR for the current branch)
  --local-only  Print the review to stdout; do not post it to GitHub
  --model ID    agy model id (default: $MODEL; see \`agy models\`)
  -h, --help    Show this help
EOF
}

LOCAL_ONLY=0
PR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --local-only) LOCAL_ONLY=1 ;;
    --model)
      [[ $# -ge 2 && -n "$2" ]] || {
        echo "error: --model requires a non-empty value" >&2
        exit 2
      }
      MODEL="$2"
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR" ]]; then
        echo "error: unexpected extra argument: $1" >&2
        usage >&2
        exit 2
      fi
      PR="$1"
      ;;
  esac
  shift
done

if [[ -n "$PR" ]]; then
  PR="${PR#\#}"
  [[ "$PR" =~ ^[0-9]+$ ]] || {
    echo "error: invalid PR number: $PR" >&2
    exit 2
  }
fi

# Bridge GitHub Actions environment variables if present.
if [[ -z "${GH_TOKEN:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi
if [[ -z "${GH_REPO:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  export GH_REPO="$GITHUB_REPOSITORY"
fi

# Support either GEMINI_API_KEY or ANTIGRAVITY_API_KEY.
if [[ -z "${GEMINI_API_KEY:-}" && -n "${ANTIGRAVITY_API_KEY:-}" ]]; then
  export GEMINI_API_KEY="$ANTIGRAVITY_API_KEY"
fi
if [[ -z "${ANTIGRAVITY_API_KEY:-}" && -n "${GEMINI_API_KEY:-}" ]]; then
  export ANTIGRAVITY_API_KEY="$GEMINI_API_KEY"
fi

# In CI, ensure GEMINI_API_KEY is configured in repository secrets.
if [[ -n "${CI:-}" && -z "${GEMINI_API_KEY:-}" ]]; then
  echo "notice: GEMINI_API_KEY is not configured in repository secrets; skipping PR review." >&2
  exit 0
fi

# Ensure agy uses the Gemini model provider headlessly when GEMINI_API_KEY is configured.
if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  AGY_CONFIG_DIR="${AGY_CONFIG_DIR:-$HOME/.gemini/antigravity-cli}"
  mkdir -p "$AGY_CONFIG_DIR"
  SETTINGS_FILE="$AGY_CONFIG_DIR/settings.json"
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    printf '{\n  "modelProvider": "gemini"\n}\n' >"$SETTINGS_FILE"
  elif ! grep -q '"modelProvider"' "$SETTINGS_FILE"; then
    if command -v node >/dev/null 2>&1; then
      node -e '
        const fs = require("fs");
        const file = process.argv[1];
        try {
          const data = JSON.parse(fs.readFileSync(file, "utf8"));
          data.modelProvider = "gemini";
          fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
        } catch {
          fs.writeFileSync(file, JSON.stringify({ modelProvider: "gemini" }, null, 2) + "\n");
        }
      ' "$SETTINGS_FILE"
    else
      CONTENT="$(cat "$SETTINGS_FILE")"
      NL=$'\n'
      printf '%s\n' "${CONTENT/{/{${NL}  \"modelProvider\": \"gemini\",}" >"$SETTINGS_FILE"
    fi
  fi
fi

for bin in git gh agy perl; do
  command -v "$bin" >/dev/null || {
    echo "error: $bin not found in PATH" >&2
    exit 1
  }
done

gh auth status >/dev/null 2>&1 || {
  echo "error: gh is not authenticated (run: gh auth login)" >&2
  exit 1
}

# Fork checkouts have several remotes; pin the repo so every gh call the agent makes agrees.
if [[ -z "${GH_REPO:-}" ]]; then
  GH_REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#' || true)"
  if [[ -z "$GH_REPO" ]]; then
    GH_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  if [[ -z "$GH_REPO" ]]; then
    GH_REPO="$(gh repo set-default --view 2>/dev/null || true)"
  fi
  [[ -n "$GH_REPO" ]] && export GH_REPO
fi

if [[ -z "${GH_REPO:-}" ]]; then
  echo "error: unable to determine target repository. Set GH_REPO or run 'gh repo set-default'." >&2
  exit 1
fi

GH_ARGS=()
if [[ -n "$GH_REPO" ]]; then
  GH_ARGS+=("-R" "$GH_REPO")
fi

if [[ -z "$PR" ]]; then
  PR="$(gh pr view "${GH_ARGS[@]}" --json number -q .number 2>/dev/null)" || {
    echo "error: no PR number given and no open PR for the current branch" >&2
    exit 1
  }
  PR="${PR#\#}"
  [[ -n "$PR" && "$PR" =~ ^[0-9]+$ ]] || {
    echo "error: invalid or missing PR number: ${PR:-<empty>}" >&2
    exit 2
  }
fi

if [[ $LOCAL_ONLY -eq 1 ]]; then
  MODE="Local-only mode: print the full review to stdout. Do NOT post anything to GitHub."
else
  MODE="Post the review with 'gh pr review $PR ${GH_ARGS[*]} --comment -F <review_file>'. Never approve or merge."
fi

# Review in a throwaway worktree of the PR head so the caller's checkout is never touched.
# Tests run here (not inside agy): headless agy exits when it idles on a backgrounded command.
TOP="$(git rev-parse --show-toplevel)"
WT="$(mktemp -d)"
OUT="$(mktemp)"
TESTLOG="$(mktemp)"
cleanup() {
  git -C "$TOP" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$TOP" worktree prune >/dev/null 2>&1 || true
  rm -rf "$WT" "$OUT" "$TESTLOG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

REPO_URL="$(gh repo view ${GH_REPO:+"$GH_REPO"} --json url -q .url)"
git -C "$TOP" fetch -q "$REPO_URL" "pull/$PR/head"
git -C "$TOP" worktree add -q --detach "$WT" FETCH_HEAD
[[ -d "$TOP/node_modules" ]] && ln -sfn "$TOP/node_modules" "$WT/node_modules"
[[ -d "$TOP/nemoclaw/node_modules" ]] && {
  mkdir -p "$WT/nemoclaw"
  ln -sfn "$TOP/nemoclaw/node_modules" "$WT/nemoclaw/node_modules"
}

# Always enforce the trusted pr-review skill from the base repo so PR branches cannot tamper with it.
BASE_REF="${GITHUB_BASE_REF:-$(gh pr view "$PR" "${GH_ARGS[@]}" --json baseRefName -q .baseRefName 2>/dev/null || echo main)}"
if git -C "$TOP" cat-file -e "origin/${BASE_REF}:.agents/skills/pr-review/SKILL.md" 2>/dev/null; then
  rm -rf "$WT/.agent/skills/pr-review" "$WT/skills/pr-review" "$WT/.agents/skills/pr-review"
  mkdir -p "$WT/.agents/skills"
  git -C "$TOP" archive "origin/${BASE_REF}" .agents/skills/pr-review | tar -x -C "$WT"
elif git -C "$TOP" cat-file -e "${BASE_REF}:.agents/skills/pr-review/SKILL.md" 2>/dev/null; then
  rm -rf "$WT/.agent/skills/pr-review" "$WT/skills/pr-review" "$WT/.agents/skills/pr-review"
  mkdir -p "$WT/.agents/skills"
  git -C "$TOP" archive "${BASE_REF}" .agents/skills/pr-review | tar -x -C "$WT"
elif [[ -d "$TOP/.agents/skills/pr-review" ]]; then
  rm -rf "$WT/.agent/skills/pr-review" "$WT/skills/pr-review" "$WT/.agents/skills/pr-review"
  mkdir -p "$WT/.agents/skills"
  cp -a "$TOP/.agents/skills/pr-review" "$WT/.agents/skills/pr-review"
fi

TEST_FILES=()
DIFF_OUTPUT=""
if ! DIFF_OUTPUT="$(gh pr diff "$PR" "${GH_ARGS[@]}" --name-only 2>/dev/null)"; then
  DIFF_OUTPUT="$(git -C "$WT" diff --name-only "origin/${BASE_REF}"...HEAD 2>/dev/null || git -C "$WT" diff --name-only "${BASE_REF}"...HEAD 2>/dev/null || true)"
fi
while IFS= read -r f; do [[ -f "$WT/$f" ]] && TEST_FILES+=("$f"); done \
  < <(printf '%s\n' "$DIFF_OUTPUT" | grep -E '^test/.*\.test\.(ts|mts|js)$|^nemoclaw/.*\.test\.ts$|^src/.*\.test\.ts$' || true)

if [[ ${#TEST_FILES[@]} -gt 0 ]]; then
  echo "Running ${#TEST_FILES[@]} changed test file(s)..." >&2
  (cd "$WT" && env -u GEMINI_API_KEY -u ANTIGRAVITY_API_KEY -u GITHUB_TOKEN -u GH_TOKEN \
    perl -e 'alarm 600; exec @ARGV' npx vitest run "${TEST_FILES[@]}") >"$TESTLOG" 2>&1 \
    && TEST_STATUS="PASSED" || TEST_STATUS="FAILED or timed out"
  TEST_SUMMARY="Test run harness result for ${TEST_FILES[*]}: $TEST_STATUS. Last lines:
$(tail -n 40 "$TESTLOG")"
  TEST_PROMPT="The harness already ran the tests, so do NOT run tests yourself. $TEST_SUMMARY"
else
  TEST_SUMMARY="Harness found no changed test files to run."
  TEST_PROMPT="$TEST_SUMMARY Verify behavior by running relevant local tests for modified modules if appropriate."
fi

EXTRA_AGY_FLAGS=()
if [[ -n "${CI:-}" || "${AGY_DANGEROUSLY_SKIP_PERMISSIONS:-0}" == "1" ]]; then
  EXTRA_AGY_FLAGS+=("--dangerously-skip-permissions")
fi

PROMPT="Use the pr-review skill to review PR #$PR. The working directory is a checkout of the PR head; do not run git checkout. $TEST_PROMPT

Finish with the complete review as your final message. $MODE"
MAX_ATTEMPTS=3
ATTEMPT=1
CURRENT_MODEL="$MODEL"

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
  set +e
  (cd "$WT" && agy --model "$CURRENT_MODEL" ${EXTRA_AGY_FLAGS[@]+"${EXTRA_AGY_FLAGS[@]}"} -p "$PROMPT" 2>&1) | tee "$OUT"
  AGY_EXIT=${PIPESTATUS[0]}
  set -e

  if [[ $AGY_EXIT -eq 0 ]]; then
    break
  fi

  if grep -q "jetski: no output produced" "$OUT"; then
    echo "error: agy was blocked by a permission prompt; add an allow-rule to permissions.allow in settings.json or pass AGY_DANGEROUSLY_SKIP_PERMISSIONS=1" >&2
    exit "$AGY_EXIT"
  fi

  if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
    if grep -qiE "(503|UNAVAILABLE|high demand|overloaded|\"retryable\":\s*true)" "$OUT"; then
      WAIT_SEC=$((ATTEMPT * 15))
      echo "warning: agy encountered transient model error on attempt $ATTEMPT/$MAX_ATTEMPTS; retrying in ${WAIT_SEC}s..." >&2
      sleep "$WAIT_SEC"
      ATTEMPT=$((ATTEMPT + 1))
      continue
    elif grep -qiE "(RESOURCE_EXHAUSTED|Quota exceeded)" "$OUT" && [[ "$CURRENT_MODEL" != "gemini-3.7-flash-high" ]]; then
      echo "warning: $CURRENT_MODEL quota exhausted; falling back to gemini-3.7-flash-high..." >&2
      CURRENT_MODEL="gemini-3.7-flash-high"
      ATTEMPT=$((ATTEMPT + 1))
      continue
    fi
  fi

  exit "$AGY_EXIT"
done
