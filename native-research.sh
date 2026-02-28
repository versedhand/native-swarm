#!/bin/bash
# native-research.sh — Research orchestrator using Claude Code native team mode
#
# Architecture: Single claude -p coordinator process. Teammates run in-process
# (same Node.js process), sharing the API connection. No additional connections.
#
# Usage:
#   native-research.sh <depth> "<topic>" ["question1" "question2" ...]
#
# Depths:
#   quick     — 3 teammates (~2 min, ~$1)
#   standard  — 5 teammates + synthesis (~5 min, ~$3)
#   thorough  — 8 teammates + synthesis + follow-up (~10 min, ~$6)
#
# Examples:
#   native-research.sh quick "Nashville ADHD psychiatrists"
#   native-research.sh standard "Claude Code team mode" "How do teams coordinate?"
#   native-research.sh thorough "credit repair strategies" "Which items to dispute first?"

set -euo pipefail

# --- Config ---
CLAUDE_BIN="${CLAUDE_BIN:-$(which claude 2>/dev/null || echo /home/rrobinson/.nvm/versions/node/v23.11.1/bin/claude)}"
OUTPUT_BASE="${OUTPUT_BASE:-/mnt/d/obs/life-var/exchange}"
WORK_DIR="/tmp/native-research-$$"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Parse args ---
DEPTH="${1:?Usage: native-research.sh <quick|standard|thorough> \"topic\" [\"question\" ...]}"
shift
TOPIC="${1:?Missing topic}"
shift
QUESTIONS=("$@")

# --- Validate depth ---
case "$DEPTH" in
    quick)    MAX_TURNS=50  ;;
    standard) MAX_TURNS=100 ;;
    thorough) MAX_TURNS=150 ;;
    *) echo "Error: depth must be quick, standard, or thorough"; exit 1 ;;
esac

# --- Setup ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SLUG=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
OUTPUT_DIR="$OUTPUT_BASE/${SLUG}-${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

echo "=== Native Research ==="
echo "Topic: $TOPIC"
echo "Depth: $DEPTH"
echo "Questions: ${QUESTIONS[*]:-none}"
echo "Output: $OUTPUT_DIR"
echo "Max turns: $MAX_TURNS"
echo ""

# --- Build questions block ---
QUESTIONS_BLOCK=""
if [ ${#QUESTIONS[@]} -gt 0 ]; then
    QUESTIONS_BLOCK="## Specific Questions
"
    for i in "${!QUESTIONS[@]}"; do
        QUESTIONS_BLOCK+="$((i+1)). ${QUESTIONS[$i]}
"
    done
fi

# --- Build teammate definitions by depth ---
# Each teammate gets a name, domain label, and search strategy.
# All teammates write findings to $OUTPUT_DIR/findings-{name}.md

case "$DEPTH" in
    quick)
        read -r -d '' TEAMMATES << 'TMEOF' || true
TEAMMATE_SPECS:
- name: "web-broad"
  domain: "General Web Search"
  strategy: "Cast a wide net with 5-8 diverse search queries. Fetch and analyze the top 3-5 results for each query. Cover the topic broadly."
- name: "web-deep"
  domain: "Deep/Technical Web"
  strategy: "Target technical sources: forums, Reddit, Stack Exchange, Hacker News, industry blogs. Look for practitioner experience, not marketing."
- name: "data"
  domain: "Structured/Existing Data"
  strategy: "Search for existing research, reports, data tables, and structured information. Include government (.gov), academic (.edu), and industry report sources."
TMEOF
        ;;
    standard)
        read -r -d '' TEAMMATES << 'TMEOF' || true
TEAMMATE_SPECS:
- name: "web-broad"
  domain: "General Web Search"
  strategy: "Cast a wide net with 5-8 diverse search queries. Fetch and analyze the top 3-5 results for each query."
- name: "web-deep"
  domain: "Deep/Technical Web"
  strategy: "Target technical sources: forums, Reddit, Stack Exchange, Hacker News, industry blogs. Look for practitioner experience, not marketing."
- name: "data"
  domain: "Structured/Existing Data"
  strategy: "Search for existing research, reports, data tables. Include .gov, .edu, industry reports."
- name: "academic"
  domain: "Academic/Authoritative"
  strategy: "Focus on research papers, peer-reviewed studies, official reports, and authoritative institutional sources. Prioritize evidence quality over quantity."
- name: "contrarian"
  domain: "Alternative Viewpoints"
  strategy: "Actively seek dissenting opinions, contrarian takes, criticisms, and failure cases. What are the counterarguments? What goes wrong?"
TMEOF
        ;;
    thorough)
        read -r -d '' TEAMMATES << 'TMEOF' || true
TEAMMATE_SPECS:
- name: "web-broad"
  domain: "General Web Search"
  strategy: "Cast a wide net with 8-10 diverse search queries. Fetch and analyze the top results thoroughly."
- name: "web-deep"
  domain: "Deep/Technical Web"
  strategy: "Target Reddit, forums, Stack Exchange, Hacker News, industry blogs. Practitioner experience, not marketing."
- name: "data"
  domain: "Structured/Existing Data"
  strategy: "Search for reports, data tables, structured information. .gov, .edu, industry reports."
- name: "academic"
  domain: "Academic/Authoritative"
  strategy: "Research papers, peer-reviewed studies, official reports. Evidence quality over quantity."
- name: "contrarian"
  domain: "Alternative Viewpoints"
  strategy: "Dissenting opinions, criticisms, failure cases, counterarguments."
- name: "recent"
  domain: "Recent Developments"
  strategy: "Focus on the last 6-12 months only. What's new, what's changed, what's emerging?"
- name: "practitioners"
  domain: "Real-World Examples"
  strategy: "Case studies, company examples, personal accounts, before/after stories. Concrete instances."
- name: "adjacent"
  domain: "Adjacent Domains"
  strategy: "Look at adjacent/tangential fields for transferable insights. What can we learn from neighboring domains?"
TMEOF
        ;;
esac

# --- Write coordinator prompt ---
cat > "$WORK_DIR/coordinator-prompt.md" << COORDINATOR_EOF
You are a research team coordinator using Claude Code's native team mode.

## Research Topic
$TOPIC

$QUESTIONS_BLOCK

## Output Directory
All files must be written to: $OUTPUT_DIR

## Step 1: Create a Research Team

Use TeamCreate to create a team. The team should have these teammates:

$TEAMMATES

For EACH teammate, their full prompt must include:
1. Their domain and search strategy (from above)
2. The research topic: "$TOPIC"
3. Any specific questions: $QUESTIONS_BLOCK
4. Instructions to use WebSearch for 5-8 queries, then WebFetch on promising results
5. Instructions to write their findings to \`$OUTPUT_DIR/findings-{their-name}.md\` using the Write tool
6. The EXACT output format below

### Required Output Format for Each Teammate

Each teammate must write their findings file in this format:

\`\`\`markdown
---
worker: {name}
domain: {domain}
source_count: {number}
---

## Findings

### Finding: [descriptive title]
**Claim:** [One clear sentence]
**Evidence:** [Specific data points, quotes, examples]
**Source:** [URL] — [brief description]
**Confidence:** HIGH / MEDIUM / LOW

[5-10 findings per teammate]

## Unanswered Questions
[What you searched for but couldn't find]

## Sources Consulted
[ALL URLs visited with brief notes]
\`\`\`

## Step 2: Wait and Collect

After creating the team and all teammates are working, wait for them to finish.
Then read each findings file from the output directory ($OUTPUT_DIR/findings-{name}.md for each teammate).

## Step 3: Evaluate Quality

For each teammate's output, check:
- Does the file exist and have substantial content (>500 bytes)?
- Are there at least 3 findings with source URLs?
- Are findings specific (not generic)?
- Do they address the topic and questions?

If any teammate produced weak output (generic, no sources, off-topic), note this in your synthesis.

## Step 4: Synthesize

Write a comprehensive synthesis to \`$OUTPUT_DIR/synthesis.md\` in this format:

\`\`\`markdown
---
topic: $TOPIC
depth: $DEPTH
date: $(date +%Y-%m-%d)
teammate_count: N
total_sources: N
---

# Research: $TOPIC

## Executive Summary
[3-5 sentences — the most important findings]

## Key Findings

### Finding 1: [title]
**Claim:** [statement]
**Supporting sources:** [which teammates found this]
**Evidence strength:** HIGH / MEDIUM / LOW
**Key evidence:** [best data point]

[ordered by evidence strength]

## Contradictions
[Where sources disagreed, with both sides presented]

## Answers to Questions
[For each original question, a synthesized answer with citations]

## Knowledge Gaps
[What remains unanswered and where to look next]

## Source Bibliography
[Deduplicated list of all unique sources]
\`\`\`

## Step 5: Clean Up

After writing synthesis.md, use TeamDelete to remove the team.

## Rules

1. Every finding must have a source URL. No unsourced claims.
2. Don't fabricate sources or URLs.
3. "I searched and found nothing" is valuable data — include negative results.
4. Write ALL output files using the Write tool. This is the deliverable.
5. The synthesis should be comprehensive enough to stand alone — someone who reads only synthesis.md should get the full picture.
COORDINATOR_EOF

echo "Coordinator prompt: $WORK_DIR/coordinator-prompt.md"
echo "Launching coordinator (PID will follow)..."
echo ""

# --- Launch coordinator ---
# Run from clean temp dir (no CLAUDE.md, no hooks) to avoid startup overhead
cd "$WORK_DIR"

# Clear nesting guard
unset CLAUDECODE 2>/dev/null || true

# Ensure team mode is enabled
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

# Launch
START_TIME=$(date +%s)

"$CLAUDE_BIN" -p \
    "$(cat "$WORK_DIR/coordinator-prompt.md")" \
    --max-turns "$MAX_TURNS" \
    --dangerously-skip-permissions \
    > "$OUTPUT_DIR/coordinator.log" 2>&1 &

COORD_PID=$!
echo "Coordinator PID: $COORD_PID"

# --- Monitor ---
# Poll for output files with progress reporting
POLL_INTERVAL=15
HARD_TIMEOUT=600  # 10 minutes

while kill -0 $COORD_PID 2>/dev/null; do
    ELAPSED=$(( $(date +%s) - START_TIME ))

    # Count findings files
    FINDINGS_COUNT=$(ls "$OUTPUT_DIR"/findings-*.md 2>/dev/null | wc -l)
    FINDINGS_SIZE=$(du -sb "$OUTPUT_DIR"/findings-*.md 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    SYNTH_EXISTS=$([ -f "$OUTPUT_DIR/synthesis.md" ] && echo "YES" || echo "no")

    printf "\r[%3ds] findings: %d files (%s bytes) | synthesis: %s    " \
        "$ELAPSED" "$FINDINGS_COUNT" "$FINDINGS_SIZE" "$SYNTH_EXISTS"

    # Hard timeout
    if [ "$ELAPSED" -gt "$HARD_TIMEOUT" ]; then
        echo ""
        echo "TIMEOUT: Killing coordinator after ${ELAPSED}s"
        kill $COORD_PID 2>/dev/null || true
        sleep 2
        kill -9 $COORD_PID 2>/dev/null || true
        break
    fi

    # Early exit: synthesis written
    if [ "$SYNTH_EXISTS" = "YES" ]; then
        # Synthesis written — give coordinator 30s to do TeamDelete cleanup, then kill
        echo ""
        echo "Synthesis written. Waiting for cleanup..."
        sleep 30
        kill $COORD_PID 2>/dev/null || true
        sleep 3
        kill -9 $COORD_PID 2>/dev/null || true
        break
    fi

    sleep "$POLL_INTERVAL"
done

wait $COORD_PID 2>/dev/null || true
ELAPSED=$(( $(date +%s) - START_TIME ))

echo ""
echo ""
echo "=== Results (${ELAPSED}s) ==="

# --- Report ---
echo "Files in output directory:"
ls -la "$OUTPUT_DIR"/ 2>/dev/null
echo ""

if [ -f "$OUTPUT_DIR/synthesis.md" ]; then
    SIZE=$(stat -c%s "$OUTPUT_DIR/synthesis.md")
    SOURCES=$(grep -c 'https\?://' "$OUTPUT_DIR/synthesis.md" 2>/dev/null || echo "0")
    echo "Synthesis: $SIZE bytes, $SOURCES source URLs"
    echo ""
    echo "--- First 40 lines ---"
    head -40 "$OUTPUT_DIR/synthesis.md"
else
    echo "WARNING: No synthesis.md produced"
    echo ""
    # Check individual findings
    for f in "$OUTPUT_DIR"/findings-*.md; do
        [ -f "$f" ] && echo "  $(basename "$f"): $(stat -c%s "$f") bytes" || true
    done
    echo ""
    echo "--- Last 30 lines of coordinator log ---"
    tail -30 "$OUTPUT_DIR/coordinator.log" 2>/dev/null
fi

echo ""
echo "Output: $OUTPUT_DIR"
echo "Log: $OUTPUT_DIR/coordinator.log"

# Cleanup temp
rm -rf "$WORK_DIR"
