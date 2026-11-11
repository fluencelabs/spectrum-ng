# Reality — what a claim is checked against
The graph is the model of the work, the repo is part of its embodiment; named here is the third — what the work becomes when it runs, and how to look at it. The carrier depends on the claim: behaviour is decided by the assembled product, not by the source that was supposed to produce it; the content of a source or a norm is the text itself; tests are a rung of evidence, not a carrier.

The rows were proposed by an iskronify pass from the code and the graph; the agent's access to the clusters is agreed by the owner, the carriers are not yet confirmed by them (case 598).

| Claim class | Canonical carrier | How to observe | Who can |
|---|---|---|---|
| A change is applied on a cluster (stage — with the merge to `main`; testnet, mainnet — after the pin change) | The GitRepository `flux-system/spectrum` and the Flux Kustomizations of the live cluster (graph, #2389) | `kubectl -n flux-system get gitrepository spectrum -o jsonpath='{.status.artifact.revision}'` = the expected revision; `kubectl -n flux-system get kustomization` — `lastAppliedRevision` at it and `Ready=True` on all (except `piraeus-operator-crd`); falsifier — an old revision or `Ready=False` for longer than the `dependsOn` cascade. Access — through beam-agent on the infra cluster (graph, #2389, #448) | user; agent — read-only through beam-agent (infra kubeconfig); writes to a cluster — only on a human's word |
| An application works on a cluster (pod up, alert fires, traffic flows) | the live object in the cluster: pod, Service/Gateway, vmalert rule | `kubectl get`/`describe` of the object in the cluster of the carrier above; for an alert — its state in vmalert/Alertmanager | user; agent — as above |
| A cluster manifest builds | the overlay render of the current tree | `kubectl kustomize clusters/<cluster>` — exit 0; falsifier — a render error | agent |
| A release is published | a tag on origin | `git ls-remote origin refs/tags/vX.Y.Z` — non-empty | agent |
| A PR is merged, CI is green | the PR on GitHub | `gh pr view <n> --json state`; `gh pr checks <n>` | agent |
| Content of a doc, norm, README | the text itself in `main` | `git show origin/main:<path>` | agent |

**Ceiling**: past cluster state and "what runs where" without access to the cluster — inference only (the `gotk_resource_info` metric, an operator's word); behaviour on testnet and mainnet without access through beam-agent — `provisional`, not "verified"; behaviour of the private registry `containers.cloudless.dev` without credentials.

**The table grows through use.** A session taught something the table does not hold (an unnamed carrier, an observation reachable or unreachable — then into *Ceiling*, a wrong command here) — write the row at the same time, before closing the work that taught it. Only what is needed for observation goes here; dated measurements and history — as nodes in the graph.
