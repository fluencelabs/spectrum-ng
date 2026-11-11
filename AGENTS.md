---
iskron:
  graph: r43
  holon: 2425
  agent_role: 1629
  contract: 41
  stamp: 2026-11-11
---
# spectrum-ng
GitOps definition of Fluence spectrum clusters: the Talos bootstrap and the Flux applications each cluster pulls at the version pinned in its GitRepository.

## Project
- **Nature**: production — mainnet (fra-flix-01, poz-bey-c01) holds tenant VMs, no relaxations; stage and testnet are test environments (agreed: owner, case 598).
- **Cost of breakage**: stage and testnet are tests, breakage is tolerable; mainnet — tenant VMs' network, disks and startup. A merge to `main` rolls out to stage by itself (`{branch: main}`); testnet and mainnet get a change only through a pin change, not right away (graph, #2389). Not every release can be rolled back to the previous tag: before changing the mainnet pin, check whether the release rolls back, and say so plainly if it does not (agreed: owner, case 598).
- **Consumers**: the stage, testnet and mainnet (fra-flix-01, poz-bey-c01) clusters — through the GitRepository `flux-system/spectrum` (graph, #2389); breakage is learned from alerts: Alertmanager → Grafana Cloud → Slack and email (graph, #1676); there is no on-call (agreed: owner, case 598).
- **Stack**: Kubernetes on Talos; Flux (flux-operator, Kustomize, HelmRelease, OCI/Git sources); devshell — Nix flake via direnv.
- **Gate**: no callable gate — `just check` (render of all clusters, kubeconform `-strict`, yamllint, actionlint, `nixfmt --check`) in CI and as a required check comes as a separate change later (agreed: owner, case 598); before a push — `kubectl kustomize` of every touched cluster. CI on PRs checks only the PR title (semantic) and runs actionlint + renovate-validator on `.github/**`.
- **Merge**: a human merges the PR (`gh pr merge --squash --admin`); the agent brings the PR to readiness (agreed: owner, case 598).
- **Layout**: there are no component READMEs — the map is in "Project structure"; the first one to touch a component moves its part of the map into that component's README; gotchas live as graph nodes on holon #2425.
- **Feedback reflection**: yes (template default).
- **Interop with a workflow suite**: none — no coercive suite found.

## Persistence rules
State lives in the **repo** or in the **graph** — nowhere else. The harness's built-in memory (memory directory, conversation summaries, `/tmp`, machine-local files) is **forbidden entirely, not by category**; a temporary directory is only the session's scratch, and the session cleans it up.
- **Repo**: code, configs, rituals (how to act here), branch state.
- **Graph**: decisions, questions of substance (vimarshas), plans (the transformation map), lessons; gotchas — per the "Layout" slot. Do not retell the graph in the repo — link to it.
- **Case** (a conversation on a graph node): one-off assignments, questions, agreements, acceptance; the course and outcome of work — as lines of its summary ("Work goes in the graph" below); the state of what the work changes — in the graph.
- **Fetch state, do not recall it.** A "we decided…" with no source — read the graph or the repo before acting.
- **A node is not written until the one who pulls it is named** — which kriya breaks if it disappears? Shelters and the form of the record — the `writing` skill.
- **Whose fact is it?** — always ask, above the harness's memory instruction; before finishing, route every lasting fact of the conversation: a code property, ritual, command, procedure of this repo → this file; a gotcha → its home per "Layout"; the meaning of code (decisions, grounds, links) and knowledge that outlives a refactor → this repo's graph, a decision as a node right away; servers, deployment, dated debts (the date in the node's `attrs`) → this repo's graph; a question of substance, a commitment → a vimarsha; a one-off → a word in the case; course of work → node modes; about another project → its graph. Rules and practices of the project itself go here by authority. The user's own matters are not written here — where they live is decided by the `iskron` door.
- **Project instructions are the committed files of the working tree (AGENTS.md, the hooks file) and the project graph**: never a global instructions file, harness memory or user hooks; personal preferences are not copied into the project; installing the delivery (bridge, plugin) is delivery, not configuration.
- The memory directory is **evacuated and frozen**: held by the memory-guard `PreToolUse` hook (block, exit 2), no stub is created; the hook does not read the `rituals:` field — when turning off `guard`, remove the hook too. Evacuation comes before freezing; nothing unread is deleted.

## Session lifecycle
A list of rules — one line per rule; the full norm is the "Cross-cutting norms" of the `iskron` skill.
- **The graph is the work, git is how it arrived.** SHAs, branches, PR numbers, "merged" are not written to the graph (bodies, names, attributes); provenance goes in the record's `reasoning`; in a case — freely.
- **Session start** — the "Start" section of the `iskron` door, before actions and through to readiness, not just reading. Addresses come from the cover; entry by a `start` line, the receipt and a subagent's own bridge — per the door's `start.md` reference.
- **Cleanup — with every finished piece** ("Cleanup" in the "Cross-cutting norms" of the `iskron` skill): scratch and your own development caches — in the same move, worktree and branch — "Branch discipline"; from cases where no move of yours is awaited — your lines with an outcome and `leave` (the lead — `propose_close` or handing over the lead). Stay only where you await an answer or lead something unclosed.
- **Graph craft belongs to the decider**: reading for a decision, the decision, weaving, integration and acceptance ("Graph craft" in the "Cross-cutting norms" of the `iskron` skill). Subagents with their own satellite bridge get the bulk work on a ready decision: code, gate, review, verification, editing many affected nodes with references to the decision and its neighbourhood; search along the `recall` ladder — `recaller` (the decider opens the finding personally), intake of a complex story — `ingester`; the launcher checks the result.
- **Starting work: graph, then project, then code.** (1) graph reconnaissance (`entry`): what is recorded about the place of change, open vimarshas, what was decided and rejected; (2) the integration field (`integrity`, section below); (3) design (`design`), then code. Skipping only on an explicit "work right away" or another named protocol, the reconnaissance debt goes to reconcile; a human's silence is not permission.
- **A decision goes to the graph the moment it is made**, wherever it came from (chat, socket, agents' agreement) — into the repo's holon by editing what it affects and its links, the thesis as its own node, modes per `writing`; what counts as fulfilment — in the node; who decided — in `reasoning` and the case, not in the node. A changed situation — likewise, right away.
- **A task is described before it starts — as what it is.** A one-off — in one case: the assignment and agreement as words, course and outcome as lines per the `iskron` door's `cases.md`; if it arrived without a case — open one (`open_room` on the subject's node or `iskron_case(action="talk", about=<subject>)`) before the first change outside. To the graph — the transitions it changes, and decisions. A vimarsha is only a question of substance or a commitment; a kriya is a repeatable transition. Telling a task from a legitimate one-sided edge kriya — per `reconcile`, pass 2.
- **Work goes in the graph** — the "Cross-cutting norms" of the `iskron` door; before a move in a case read its `cases.md` reference, and when leading a case — also `leading.md`. That is where the distinction of graph and case, addressing, the form of course/outcome and handing over the lead live; the method is not copied here.
- **Merge → graph.** A push that opened or updated a PR shipped nothing; the sequence hangs on the merge event, not on a lull. The PR is merged on the forge, not by a session command — the merge hook is silent: run the sequence yourself once you see `MERGED` (`gh pr view <n> --json state`). All acts are mandatory — except for work by reference from an agent (assignment by references, report in the case): there weaving, closing along the axis and reconciliation belong to the assigner, and the doer owns the transformation seed and the delivery modes (the `vahta` skill):
  - **Weave** (`weaving`): what shipped — into the target system as nodes and edges, not a paragraph; repo mechanics stay in git. Zero nodes and arrows after a substantive wave — say plainly why.
  - **Advance the map**: open work — `anga` to the transformation; one `genre=hint` seed per transformation — only what cannot be recovered by reading the graph and cases; live cases — as a pointer to reading them (`iskron_case(action="at")`, `read`), a number only where a substantive choice cannot otherwise be recovered.
  - **Switch modes** by evidence on the carrier (`REALITY.md`, **reality-audit**), not by the merge: a merge moves the nodes of what the code carries; practice (`anagata→vartamana`) — a rollout or run seen on the carrier (`anumita`), observed — `pratyakshita`.
  - **Close along the axis** (`inquiry`): `addressed_by` to the carrying node; `visarjana` — when the answer stands as a node, the repo shows it and reality shows reachability (where it does not — the user's word); otherwise present it to the owner. In the same move — the `posed_to` inbox (woken by a change at the anchor, not by age), `propose_close` with evidence.
  - **Reconcile — `reconcile`**: nodes against code, code against graph, what was dropped is recorded and referenceable; the remainder — as vimarshas.
  - **Feedback reflection** — on merge and on closing a session without a merge: experience *about the method* (a skill, rule or surface failed or surprised) — as a case, not an opinion, after checking against what has been said, into the work graph anchored on the tool's node, addressed to its steward; about the method in general — along the route of the `feedback` skill. Zero records is a valid outcome.
  - **Vocabulary pass**: borrowed words (list — principle 8) in the landed text and nodes — name them to the human and ask what they are called in the project; do not substitute them yourself.
- **A design is not ready until decisions, risks and lifecycle are in the graph** — whatever skill elicited it; an external design/spec file is a draft for intake in the same session, the graph holds the decisions. Without an owner: decisions and risks — now, the transformation — with a telos for confirmation.
- **Execution suites lead execution** (plan, TDD, debugging, review); the graph carries memory and design: execution decisions and risks go to the graph before the session ends.
- **A claim you made is not a claim you accept.** A behavioural claim is closed by a cold `verifier`: the brief is the claim, the carrier and the falsifier from `REALITY.md`; wait for the verdict. No such role — observe the carrier yourself, never the source.
- **Hook merging**: entries of different suites in the hooks file coexist — add alongside, do not overwrite others'.
- The start, push and merge rituals are carried by the delivery per the cover; memory-guard — Claude Code: in the repo (`.claude/settings.json`).
- **Keep this file honest.** The contract is the number after the "AGENTS.md CONTRACT:" label (written in the skill's own language) at the start of the `iskronify` skill description: compare it with the cover's `contract` without loading anything. Higher than `contract`, or the sources moved after `stamp` (`git log -1 --format=%cd -- <those files>`) — run `iskronify` as the first move, in a clean tree and the work branch, per the "Who runs the pass" rule; the pass does not wait for a human, slot order — Step 1 of `iskronify`. **Lower than `contract`** — the file is ahead of the delivery: do not downgrade and do not call the pass, update the shadowing copy of `iskronify` and reread the description. A line of this file diverges from the skill — say so aloud (in the case to the assigner, otherwise to the human): `contract` lower — the skill is right; higher — the file is right; equal — a template defect, feedback to the steward of the skills delivery (the `feedback` skill).
- **Keep the toolchain fresh**: updates are on by default, take them as the channel delivers. A channel without auto-update (an unpacked copy) — check the version before the session or move off it.

### Stage self-check
The gate is green and a coherent stage is finished (a PR opened or updated, or you are about to touch nodes beyond the initial ones) — reread the branch diff against trunk: bugs, fragile spots, weak error handling, DRY/SOLID violations, missing or useless tests, files over 150 lines and god units. Fix in the same branch or say plainly that nothing came up; do not invent findings. Per stage, not only at the end.

### Cold review of a batch
- **Self-check — always, cold review after it — where required below**: you see your own work as you intended it.
- **Review before merge — per the repo policy**: the forge's `main` ruleset — squash only, linear history, one code owner approval (`.github/CODEOWNERS`) after the last push, all threads resolved; no required status checks — the CI above does not gate the merge. Cold review by the `reviewer` role — on every batch before requesting approval; the reviewer is not the author of the diff. CI, render of the affected clusters and a targeted check for a security threat (a secret outside the `${VAR}` template) or data loss (`prune`, deleting a PVC/CRD) — on every batch.
- Review — by the `reviewer` role, **in a separate worktree**: where the spawning tool provides isolation (Claude Code — `isolation`) — with it; where it does not — the lead lays down a detached tree (`git worktree add --detach .worktrees/<name> <head>`), the path goes into the brief as a line "work only there", the ban on editing — as a second line; in the report — "manual isolation". Neither — say that there was no cold review. Only a push has a guard: a stage without a push is yours to hold.
- The reviewer's brief is the branch diff against trunk, the focus holon with its steward role and references to the diff's nodes, not a retelling; the integration field and the report — per the `reviewer` role; `NEEDS_CONTEXT` is a graph defect: finish the design, weave in, pose vimarshas, repeat the review. A finding you disagree with — reject it with a recorded "why".

### Role file tails
#### worker
- Before reporting — `kubectl kustomize clusters/<cluster>` of every affected cluster: zero errors; a secret — only as a `${VAR}` template, the value is not put into git.

### Branch discipline
One branch and one PR per batch: items and subagents' work merge into it locally. **A branch lives in its own worktree inside the repo** (`git worktree add .worktrees/<branch> -b <branch> origin/main`; `.worktrees/` is in `.gitignore`), not in the main checkout and not next to the repo: sessions share the main checkout, and a `checkout` there wipes others' work. After merge: `git worktree remove` of your tree, `git branch -d` of the merged branch and others already in `main`, your development caches; `git pull` in the main checkout; weave what shipped into the graph; the next branch — from a fresh `origin/main`; confirm cleanup before the next task. **An abandoned tree** (branch in `main` or deleted on the forge, clean copy) may be cleaned up by any agent of the repo (`git worktree remove`, `prune`, `git branch -d`); do not touch uncommitted or unmerged work — name it to its holder or the human.

## Working principles
1. **Think before code.** Name assumptions; when unsure, ask *what exactly* is unclear. **A question to the human — in words, not by a choice tool**: as text — only to the one answering now; one that outlives the turn — as an `ask` card in the case ("Question to the human" of the `iskron` door; no case — take one; no place — their standing bridge); the harness's option-picking tool — never. Push back when you see a simpler move or a false premise. Touch the live system before trusting a type, a name, a doc.
2. **Simplicity first.** The minimum for the task; no speculative features, abstractions for one-offs, handling of the impossible. Validate at boundaries.
3. **Stay within the repo boundary.** Edits — only in the working directory; outside it — reading carriers, the session scratch and the delivery home. Another holon — a vimarsha on its node (`anga` to the transformation) and a word to its steward in the case (`iskron_case(action="talk", about=<subject>)`). **Do not take others' code into context** — neither by reading, nor by cloning, nor by subagent reconnaissance: what you need comes from the graph (that repo's holon, phenomena, relays, inquiries) or by a word to the steward; what is neither there nor in the answer — a `posed_to` vimarsha to them.
4. **A second implementation is an event to report.** Derive both places via `integrity`, name them to the human, propose reunification or a named fork; a new consumer comes in with its edges in the same move.
5. **Surgical changes.** Touch what the task needs; do not reformat or refactor neighbouring code; keep the style; the linter is authoritative; delete only what your change made dead, flag the rest, do not delete it.
6. **Goal-driven execution.** A bug — with a failing test before the patch. Multi-step work — `step → check` pairs. Runtime — in the real environment. The falsifier — before looking; observe the carrier (`REALITY.md`), not the source.
7. **Read before answering an open question** — from what is recorded, not from training data (the `recall` skill). Search output is a lead, not data: read structure and links with `iskron_look`, `iskron_orient`; to a subagent — reconnaissance of code and files (`reader`), graph search (`recaller`); reading what was found for a decision is yours.
8. **Think in the graph, speak the project's language.** The graph vocabulary (kriya, phenomenon, holon, role, vimarsha, modes) is for reasoning; to the human — the project's words, until they use the term first. Borrowed words about work — ticket, task, sprint, backlog, epic, story, done, blocker, committed — do not substitute them yourself: name them and ask what they are called in the project ("Vocabulary pass"); say: question, change, what is open, what this unblocks.

## Integration field — only from the graph
- The root of the traversal is the focus holon and the steward role from the cover. Do not keep a list of shared surfaces and consumers here and do not ask the human for one — foreign things the graph does not model go in "External surfaces".
- For every change name the nodes whose embodiment is in the diff and run `integrity`: a phenomenon — `iskron_orient(lens="trace")` both ways; a kriya — the `next` thread and the `ahara`/`utpatti`/`upadhi` relays; an exit into another holon — to its steward role.
- A dependency not found by the traversal is a model defect: finish the design (`design`), weave it in (`weaving`), waiting — as a `posed_to` vimarsha and a word in the case. A public handle with no trace in the graph is either unneeded or a graph debt. A new consumer is in when the code and the edges appeared in one move.

## External surfaces — what you use and do not own
- **Before work, pin the touched part of the surface** (a foreign API, SDK, CLI, protocol, schema, Helm chart, CRD) as a node in the graph, with its version.
- **Pratyaksha before shabda**: observation with your own hands (a call, `--help`, `helm show values`, an installed CRD) outranks docs, docs outrank memory, memory is not a source. `pratyakshita` — only what was observed.
- **Weave the link**: the surface node — `upadhi` (or `ahara`/`utpatti`) to the kriya that acts through it.
- **Keep in step**: a divergence or a new version — edit the node in the same move, lower the epistemic mode if you did not observe it.
- Source code at a surface carries `(graph …, node #N)` — read that node before working.

## Reality — what a claim is checked against
The carrier table is the root `REALITY.md`, read when the occasion arises: before saying of behaviour "it works", switching a mode or closing a question on a claim about execution — read the row of your claim class and observe its carrier; the row goes into the `verifier` and `reviewer` brief in full. The first row — a change applied on a cluster: the GitRepository and Flux Kustomization of the live cluster, not the render. Ceiling — classes without a reachable observation — is there too. Learned a carrier that is not in the table — write the row there at the same time.

## Graph ↔ repo: what lives where
| Concern | Repo | Graph |
|---|---|---|
| Code, configs, lockfiles | ✓ | |
| Commands, conventions, stack | ✓ (AGENTS.md) | |
| Reality carriers | ✓ (REALITY.md) | |
| Gotchas | | ✓ node on holon #2425, this file links to it |
| Branch state, what is in flight | git + PR (case number in the body) | ✓ (`genre=hint` seed of the transformation) |
| Methodology, ontology | | ✓ |
| Decisions | | ✓ (as a node, right away) |
| Questions of substance, commitments | | ✓ (vimarshas) |
| Plans | | ✓ (transformation map) |
| One-off task, conversation, shift handover | | ✓ (case + transformation seed) |
| Commit history, PRs, SHAs | git | (never in the graph) |

**No `HANDOVER.md` is created**: branch state has homes — `git branch`/`log`, the open PR and the case by the number in its body, node modes, the transformation seed; a hand-written file is the only one of them that lies silently. The forge is unreachable — progress is read from modes and the seed.

## Commands
| What | Command |
|---|---|
| Devshell (just, gh, kubectl, helm, virtctl, flux, nixfmt) | `direnv allow` (`.envrc`: `use flake`) or `nix develop` |
| Nix formatting | `nix fmt` (nixfmt-rfc-style) |
| Build a cluster overlay | `kubectl kustomize clusters/<cluster>` |
| Build all clusters | `for c in clusters/*; do kubectl kustomize "$c" >/dev/null \|\| echo "FAIL $c"; done` |
| Watch a PR | `gh pr checks <n> --watch`; merged or not — `gh pr view <n> --json state` |

## Project structure
- `bootstrap/` — `bootstrap.yml` (flux-operator, its CRDs and FluxInstance, in one file) and `bootstrap/` (kustomization: `instance.yml`, `spectrum.yml` — GitRepository + Kustomization spectrum); the version strings in `bootstrap.yml` and `spectrum.yml` are moved by release-please (`extra-files`) — do not edit them by hand.
- `clusters/<cluster>/kustomization.yml` — `bootstrap`, `dev`, `stage`, `testnet`, `mainnet`: which `flux/apps` and `flux/repositories` groups the cluster gets.
- `flux/apps/<group>/` — `fluence`, `flux-system`, `ingress`, `kube-system`, `kubevirt`, `networking`, `observability`, `storage`, `system`.
- `flux/repositories/{git,helm,oci}/` — Flux sources.
- `docs/` — `adding-a-cluster.md`, `egress-network-parameterization.md`, `kube-oidc-proxy-access.md`.
- `.github/` — CI workflows (including the daily `cve-scan.yml` → `scripts/cve-scan.sh`), `release-please/`, `renovate.json`, `CODEOWNERS`.
- `README.md` — manual prerequisites after bootstrap (ConfigMap `spectrum-vars` / `spectrum-manual-vars`, secrets).

## Code conventions
- **Repository content is English only**: code, comments, docs, agent config, commit messages, PR titles and bodies.
- **Meaning lives in the graph, code references it**: rationale, rejected alternatives, integration design — a node; in code — "(graph `@cloudless/fluence`, node #N)", and for what was rejected too ("not caching: #N"). Mechanics — in words on the spot. Having referenced a node, check that the node says it; if it diverged — edit the node.
- A new per-cluster variable — a row in the `README.md` table in the same commit.
- A secret in the repo — only as a `${VAR}` template (Flux postBuild substitution from `spectrum-vars` / `spectrum-manual-vars`); the value is not put into git.
- Do not declare the GitRepository `flux-system/spectrum` in any manifest that Flux applies: it would overwrite the clusters' pin (graph, #2389).
- **Test discipline**: there are no tests; the evidence of a batch is the `kubectl kustomize` render of every affected cluster, behaviour — on the cluster per `REALITY.md`.

## What to update when
- `AGENTS.md` — **what can be learned from a graph node is not written here**; it holds what is needed before the agent reaches the graph (commands, entry into orientation, invariants outside the linter, stop-forks). Pruning prose means moving it into carrying nodes, not deleting it.
- `REALITY.md` — when a carrier of a claim class appeared, changed or turned out unreachable; dated measurements — to the graph.
- A component README — in the same commit that moves, renames or creates the component's files.
- The project graph — every merge ("Session lifecycle").

## Git workflow
- **Conventional commits** (`feat:`/`fix:`/`chore:`/`refactor:`/`docs:`/`test:`), scope — the application group (`fix(kube-ovn): …`); branches `feat/…`, `fix/…`, `chore/…`; PR titles in the same format — CI checks them, release-please cuts the version from them.
- **PR body — one or two lines**: what changed, the case number. The course of work and its lines stay in the case and are not copied to the PR.
- **No co-author trailer and no mention of Claude** (lines like "Generated with Claude Code" and similar) in commits and PR bodies, unless the user asked.
- **Gate — one call**: there is no callable gate (`just check` — later, "Project"); before a push — `kubectl kustomize` of every touched cluster (the "Commands" table).
- **No pre-commit hook** — the gate runs before the push.
- **A batch branch does not live without a PR**: pushed — open a PR in the same move (a draft if the batch is not assembled).
- **Definition of done**: the PR into `main` is merged (`gh pr view <n> --json state`); stage sits on `{branch: main}` and gets the change by itself with the merge; the other clusters — only through a release-please release and a pin change in their GitRepository (graph, #2389).
- **Never** `--no-verify`, `--force`, `--no-gpg-sign`, `git reset --hard` without an explicit instruction.
