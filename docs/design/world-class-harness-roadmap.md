# World-Class Harness Roadmap For Codex And Claude Code

Date: `2026-04-12`
Status: `strategic roadmap`
Audience: `project owner`

## 1. Executive Summary

`agent_base` already has unusually strong foundations for a serious agent harness: a deterministic acceptance spine in `docs/manual/verification-truth-matrix.md`, a clear runtime contract in `scripts/codex-wrapper.sh`, repo-local semantic capability transport in `scripts/launch-semantic-mcp.sh`, and a real release gate in `test/integration/harness_release_gate.sh`. The current design docs around boundary and trust, especially `docs/design/harness-plugin-boundary.md`, `docs/design/harness-plugin-mcp-trust-matrix.md`, and `docs/design/safe-merge-protocol.md`, also show the right fail-closed instinct.

The next step is not to add more surface area. The next step is to convert these foundations into a unified harness architecture that can make Codex and Claude Code behave consistently under one policy, one task contract, one evidence model, and one release decision path.

As of `2026-04-12`, the highest-leverage path is:

1. compile policy once and enforce it across both runtimes
2. standardize task execution behind a common task contract and capability adapter
3. measure both runtimes on the same eval and benchmark harness
4. make every meaningful action replayable through a full provenance graph
5. add safer preview and sandbox execution before widening autonomy

This document is intentionally stable strategy. Dated benchmark runs, rerun artifacts, and per-task evidence should remain in volatile locations rather than being embedded here.

## 2. Current Strengths

`agent_base` is not starting from zero. Its current strengths are already close to what many teams only discover after painful failures.

- `Truth and acceptance discipline`: `docs/manual/verification-truth-matrix.md` already separates reasoning from deterministic checks and gives the repo a real acceptance authority.
- `Wrapper and runtime contract`: `AGENTS.md` plus `scripts/codex-wrapper.sh` make runtime policy explicit instead of leaving model effort, search, and sandbox behavior ambiguous.
- `Semantic MCP foundation`: `scripts/launch-semantic-mcp.sh` establishes a repo-local capability plane instead of pushing critical context into a remote black box.
- `Release gate foundation`: `test/integration/harness_release_gate.sh` and `scripts/quality_gate.sh` provide a concrete checkpoint where claims can be tested rather than narrated.
- `Provenance and fail-closed posture`: the existing design docs already bias toward repo-local authority, trust matrices, and fail-closed boundaries instead of optimistic orchestration.

These strengths matter because they are the right substrate for a world-class harness. The gap is not conceptual direction; the gap is turning these good local mechanisms into one coherent end-to-end control system.

## 3. Ranked Top 10 Gaps

1. **Policy compiler is missing.** The repo has policy sources, but not a compiled, machine-enforceable contract that normalizes acceptance, permissions, routing, and evidence rules across Codex and Claude Code. World-class harnesses do not rely on each runtime to interpret prose consistently.
2. **There is no common task contract and capability adapter.** The system still depends too much on runtime-specific prompting and wrapper behavior. A single task envelope should define inputs, expected artifacts, allowed tools, check requirements, and completion boundaries independent of which agent executes it.
3. **Cross-runtime eval and benchmarking are not first-class yet.** The harness needs a standard way to run the same task slices against Codex and Claude Code, compare correctness, latency, cost, retry behavior, and failure modes, and record results as volatile evidence.
4. **Full provenance graph and replay are incomplete.** The repo has provenance instincts, but not a full graph that links task request, policy version, runtime selection, tool calls, artifacts, checks, reviewer decisions, and release outcome into one replayable chain.
5. **Preview and sandbox execution are not yet a formal product surface.** The harness should be able to run a task in a contained preview mode that exercises tools, checks, and artifact generation without granting merge-level authority.
6. **Backend integrity gate is under-specified.** There is a release gate, but the repo still needs a stricter integrity layer for authority-bearing state transitions such as policy compilation, artifact registration, provenance writes, replay validation, and release decision inputs.
7. **Release controller is not yet explicit.** The current release gate is a strong foundation, but the harness needs a controller that decides when a task can move from draft to preview to verified to releasable, based on policy and evidence rather than ad hoc orchestration.
8. **Policy-gated autonomy and exception handling are not formalized enough.** The fail-closed posture is correct, but the harness should classify tasks by risk tier and make normal execution autonomous within policy while reserving exception approval for privileged operations, external side effects, and multi-step releases.
9. **Cost, latency, and router control are still too implicit.** A world-class harness needs observable routing policy across models and runtimes, with explicit tradeoffs among cost, latency, reliability, and task class rather than static wrapper defaults alone.
10. **Multi-repo or tenant-aware control plane should exist later, but not yet.** Today the harness is repo-local by design, which is correct. The gap is not immediate implementation; it is designing the future control-plane boundary so multi-repo governance can arrive later without breaking current repo authority.

## 4. P0 / P1 / P2 Roadmap

### P0

P0 should turn the current repo from a strong set of guardrails into a coherent single-repo execution system.

- Build a `policy compiler` that ingests authority sources such as `AGENTS.md`, `.agent_rules/RULES.md`, `docs/manual/verification-truth-matrix.md`, and role docs, then emits a normalized contract consumable by both Codex and Claude Code.
- Define a `common task contract` for all execution slices. The contract should cover task identity, scope, role, allowed capabilities, deterministic checks, artifact destinations, and completion boundary.
- Introduce a `capability adapter` layer that maps the common task contract onto each runtime without changing task semantics.
- Stand up `cross-runtime eval and benchmarking` on a fixed task suite so the owner can compare Codex and Claude Code on the same harness-defined slices.
- Expand provenance into a `full provenance graph` with replayable identifiers for policy version, task contract, runtime decision, tool actions, check outputs, and release outcome.

### P1

P1 should make autonomy safer and operationally clearer.

- Add `preview and sandbox execution` so tasks can run in a constrained mode before they are allowed to affect authoritative state or release paths.
- Implement a `backend integrity gate` that validates policy artifacts, provenance writes, replay completeness, and evidence integrity before release decisions can consume them.
- Promote the current release gate into a proper `release controller` with explicit state transitions such as draft, previewed, verified, blocked, and releasable.
- Add `policy-gated autonomy and exception handling` so the harness can let normal execution continue within approved policy while escalating only boundary-crossing or privileged cases.
- Keep the browser stack layered: `Playwright` is the verification substrate, `Chrome DevTools MCP` is the debugging companion, and `Browser Use` remains a policy-gated high-power integration.

### P2

P2 should improve economics and prepare scale without diluting the current repo-local model.

- Add `cost, latency, and router controls` that pick runtime and model settings from measured policy instead of fixed defaults alone.
- Create `tenant-aware or multi-repo control-plane design` only after the single-repo policy compiler, task contract, provenance graph, preview flow, and integrity gates are stable.
- Keep repo-local authority intact while extracting only non-authoritative coordination surfaces that are proven reusable.

The key sequencing rule is simple: do not build a broader control plane before the single-repo control loop is deterministic, replayable, and benchmarked.

## 5. What Not To Build Yet

Several tempting directions would create surface area without increasing harness quality.

- Do not build a `generic chat UI`. The harness wins on policy, evidence, replay, and release safety, not on becoming another conversational shell.
- Do not invest in `heavy vector memory` as a core architecture bet. The repo already has a better path through explicit policy, semantic MCP, provenance, and task contracts.
- Do not prioritize `plugin marketplace` work yet. `docs/design/harness-plugin-boundary.md` and `docs/design/harness-plugin-mcp-trust-matrix.md` already imply the right answer: authority should remain repo-local until the control model is mature.

If the owner wants world-class behavior soonest, the principle is to deepen control and verification before broadening distribution and UX.

## 6. Source Links

- OpenAI Codex: <https://platform.openai.com/docs/codex>
- OpenAI Responses and tool use: <https://platform.openai.com/docs/guides/tools?api-mode=responses>
- OpenAI Responses migration guidance: <https://platform.openai.com/docs/guides/responses-vs-chat-completions>
- Anthropic Claude Code overview: <https://docs.anthropic.com/en/docs/claude-code/overview>
- Anthropic Claude Code MCP: <https://docs.anthropic.com/en/docs/claude-code/mcp>
- Anthropic MCP overview: <https://docs.anthropic.com/en/docs/mcp>
