# Native Swarm — Team Mode Research

Uses Claude Code's native team mode for multi-agent research. **Proven working Feb 27, 2026** — 3-teammate quick research produced 51KB of structured findings + synthesis from a single API connection in ~10 minutes.

## Status: WORKING — Ready for Migration

Headless batch mode (`native-research.sh`) is proven. In-session mode (agent uses Teammate tool directly) is the eventual target but requires team tools in the session (env var must be set before session starts).

## Enable

```bash
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

Already in `~/.bashrc`. New sessions get team tools automatically.

## Quick Start

```bash
# Quick research (3 teammates)
/life-code/native-swarm/native-research.sh quick "topic" "question 1" "question 2"

# Standard research (5 teammates)
/life-code/native-swarm/native-research.sh standard "topic" "question"

# Thorough research (8 teammates)
/life-code/native-swarm/native-research.sh thorough "topic" "question"
```

Output goes to `/life-var/exchange/{slug}-{timestamp}/`.

## Tool API (from official system prompts)

The team mode uses a **single tool called `Teammate`** with multiple operations. Teammates are spawned via the **`Task` tool** with `team_name` and `name` parameters.

### Teammate Tool Operations

| Operation | Purpose | Who |
|-----------|---------|-----|
| `spawnTeam` | Create a team (name + description) | Lead |
| `write` | Send message to ONE teammate by name | Anyone |
| `broadcast` | Send message to ALL teammates (expensive — N messages) | Anyone |
| `requestShutdown` | Ask a teammate to stop | Lead |
| `approveShutdown` | Accept shutdown request and exit | Teammate |
| `rejectShutdown` | Decline shutdown, keep working | Teammate |
| `approvePlan` | Approve a teammate's plan | Lead |
| `rejectPlan` | Reject plan with feedback | Lead |
| `cleanup` | Remove team + task directories | Lead |
| `discoverTeams` | List available teams | Anyone |
| `requestJoin` / `approveJoin` / `rejectJoin` | Dynamic team membership | Anyone/Lead |

### Spawning Teammates

Teammates are created using the **Task tool** with `team_name` and `name` parameters:
```json
{
  "subagent_type": "general-purpose",
  "name": "web-broad",
  "team_name": "research-topic",
  "prompt": "You are a research agent...",
  "description": "web-broad researcher"
}
```

### Communication Model

- **Teammates' plain text output is NOT visible** to the lead or other teammates
- To communicate, teammates MUST use `Teammate(operation: "write", target_agent_id: "team-lead", value: "...")`
- Messages from teammates are **automatically delivered** to the lead (no inbox polling needed)
- The lead sees queued messages when their current turn ends

### Shutdown Protocol

Must follow this order:
1. `Teammate(operation: "requestShutdown", target_agent_id: "worker-name")` for each teammate
2. Wait for each to `approveShutdown`
3. `Teammate(operation: "cleanup")` to remove team + task directories
4. Only THEN prepare final response

### Task System Integration

Teams have a 1:1 correspondence with task lists (Team = Project = TaskList):
- Team config: `~/.claude/teams/{team-name}/config.json`
- Task list: `~/.claude/tasks/{team-name}/`
- Teammates use TaskCreate, TaskUpdate, TaskList for work coordination
- Tasks are assigned via `TaskUpdate(owner: "teammate-name")`

## Architecture

```
native-research.sh
  └── claude -p (coordinator process, runs from /tmp)
        ├── Teammate(spawnTeam, "research-{topic}")
        ├── Task(name: "web-broad", team_name: "...", prompt: "...")
        ├── Task(name: "web-deep", team_name: "...", prompt: "...")
        ├── Task(name: "data", team_name: "...", prompt: "...")
        │     └── [teammates run in-process, do WebSearch + WebFetch]
        ├── Teammates write findings to files via Write tool
        ├── Coordinator receives completion messages (auto-delivered)
        ├── Coordinator reads findings, evaluates quality, synthesizes
        ├── Coordinator requestShutdown → approveShutdown → cleanup
        └── Output: synthesis.md + findings-{name}.md
```

All teammates run **in-process** (`backendType: "in-process"`) — they share the coordinator's API connection. No additional sessions needed.

## Teammate Domains by Depth

| Depth | Teammates | Description |
|-------|-----------|-------------|
| **quick** | web-broad, web-deep, data | General search + forums/Reddit + structured data |
| **standard** | + academic, contrarian | + authoritative sources + dissenting views |
| **thorough** | + recent, practitioners, adjacent | + last 6 months + case studies + adjacent fields |

## Output Structure

```
/life-var/exchange/{slug}-{timestamp}/
├── findings-web-broad.md    # 10-15KB, 10+ findings with URLs
├── findings-web-deep.md     # 10-15KB, focused on forums/Reddit
├── findings-data.md         # 10-15KB, .gov/.edu/official sources
├── synthesis.md             # 10-15KB, comprehensive synthesis
└── coordinator.log          # Full coordinator stdout (empty until process ends)
```

## Proven Test Results (Feb 27)

| Metric | Result |
|--------|--------|
| Topic | "David Spielman Quirkiatry Nashville psychiatrist ADHD autism" |
| Depth | quick (3 teammates) |
| Total output | 51,236 bytes |
| Findings | 33 structured findings across 3 teammates |
| Source URLs | 65 unique URLs |
| Synthesis | 12,308 bytes with bibliography, answers to both questions |
| Elapsed | ~10 minutes |
| API connections | 1 (coordinator, teammates in-process) |

## Comparison to Old Systems

| Aspect | Native Team Mode | Research Swarm MCP | Subprocess Swarm |
|--------|-----------------|-------------------|-----------------|
| Workers per research | 3-8 (in-process) | 3-8 (subprocesses) | 3-8 (subprocesses) |
| API connections | 1 | N+1 (workers + synth) | N |
| Rate limit impact | None | High | High |
| Quality scoring | Semantic (LLM evaluates) | Regex (file size, URLs, keywords) | None |
| Follow-up iteration | Coordinator can message teammates | Retry with same prompt | None |
| Output quality | Excellent (tested) | Good (tested) | Varies |
| Infrastructure | 1 bash script (~200 lines) | Python MCP server (~1400 lines) | Python library (~850 lines) |
| Cron/batch capable | Yes | Yes | Yes |
| In-session capable | Yes (with Teammate tool) | No (MCP, runs external) | No |
| Synthesis | Coordinator does it natively | Separate synthesis worker | None |

## Migration Path

1. **Now**: Use `native-research.sh` for headless batch research
2. **In-session**: When agent has Teammate tool, use it directly (no shell script needed)
3. **Deprecate**: research-swarm MCP (`/life-code/research-swarm/`)
4. **Keep**: Subprocess swarm (`/life-code/swarm/`) for non-research parallel work

## In-Session Protocol

When an agent has the Teammate tool, it can run research directly:

1. `Teammate(operation: "spawnTeam", team_name: "research-{slug}")` — create team
2. For each domain: `Task(subagent_type: "general-purpose", name: "{domain}", team_name: "research-{slug}", prompt: "...")` — spawn teammate
3. Teammates do research and write findings to exchange directory
4. Teammates send completion message via `Teammate(operation: "write", target_agent_id: "team-lead", value: "Done")`
5. Lead receives messages automatically, reads findings files
6. Lead evaluates quality and synthesizes
7. For each teammate: `Teammate(operation: "requestShutdown", target_agent_id: "{name}")`
8. Wait for `approveShutdown` from each
9. `Teammate(operation: "cleanup")` — remove team resources

## Known Issues

1. **Coordinator lingers after synthesis** — The shutdown protocol takes time. Monitoring loop kills after 30s grace.
2. **Log file stays empty until exit** — `claude -p` buffers stdout.
3. **Team cleanup sometimes incomplete** — `~/.claude/teams/` artifacts may remain. Safe to delete.
4. **tmux required** — Team mode creates tmux sessions internally.

## Source Documentation

Official system prompts (from `Piebald-AI/claude-code-system-prompts` repo):
- `tool-description-teammatetool.md` — Full Teammate tool operations
- `tool-description-teammatetools-operation-parameter.md` — Operation enum
- `system-reminder-team-coordination.md` — Teammate injection prompt
- `system-reminder-team-shutdown.md` — Shutdown protocol
- `system-prompt-teammate-communication.md` — Communication rules
- `agent-prompt-exit-plan-mode-with-swarm.md` — Plan → swarm workflow

Cloned to: `/life-var/tmp/claude-code-system-prompts/`

## File Layout

| File | Purpose |
|------|---------|
| `native-research.sh` | Headless batch research script |
| `README.md` | This file |
