# WorldModel

The live PRIMUS world-modeling application — a braid of named **Spaces** over the CognitiveSubstratesAI
substrate, built directly from `PRIMUS-world-modeling_v2` (Goertzel, 2025).

The world model is **not a monolith**: it is a heterogeneous braid of Spaces (paper §4.2 / Appendix A),
each on its natural substrate, coupled by shared identifiers and explicit bridging operators (Γ, Λ,
𝓔ₕₘₕ, 𝓓ₕₘₕ, kernel μR). Spaces are **data**, created and deleted at runtime — never hardcoded.

## Layering (one concern per file)

| Module | Role | Substrate |
|---|---|---|
| `Manifest` | config-driven store / `.act` paths (ENV-overridable, never `/tmp`) | — |
| `Substrate` | symbolic Spaces: byte-trie ops, `.act` persistence, prefix walks | **MORK / PathMap** |
| `HMHStore` | `Shmh` associative memory: episode hypervectors, recall | **HMH / FactorVSA** |
| `Dense` | dense Spaces: vector store + `Sdyn` predictive-coding model | **FabricPC** |
| `Kernel` | kernel / MKME service: Gram, μR set→vector, MMD | **MORKTensorNetworks** |
| `Registry` | the dynamic Space registry (logical layer over all backends) | — |
| `Schema` | the 14 canonical Spaces as data + seeding | — |
| `Braid` | inter-space flows (the diagram's arrows) | — |
| `Beliefs` | truth values + staleness decay (R10) | — |

## The 14 Spaces (3 representational regimes)

- **🩶 Symbolic** (MORK/PathMap): `Senv` `Sevid` `Sent` `Smap` `Srule` `Smotive` `Sopt` `Sxfer` `Sprog`
  `Smine` — atoms + truth values; each its own persistent `.act` trie, sharing identifiers.
- **🟦 HMH** (HMH/FactorVSA): `Shmh` — role-filler episode hypervectors, structured associative recall.
- **🟩 Dense** (FabricPC + MORKTensorNetworks): `Sctx` (context vectors) · `Sdyn` (PC dynamics model) ·
  `Skernel` (kernel/MKME summaries).

## The braid (inter-space operators)

- **Γ grounding** + evidence anchoring + **R2** re-perception (`store_evidence!`, `ground!`,
  `evidence_of`, `fetch_evidence`)
- **𝓔ₕₘₕ / retrieve / 𝓓ₕₘₕ** (`encode_hmh!`, `retrieve_hmh`, `densify_hmh`)
- **Λ lift** + **kernel μR** + Sctx→Sdyn conditioning (`lift!`, `kernel_summary!`, `attach_dynamics!`,
  `predict_dynamics`)

## Status

Built and tested **on the real substrate, no mocks** (`Pkg.test()`): the Space spine (dynamic +
`.act`-persistent), all three regimes bound to their substrate, and the symbolic + HMH + dense braid
arrows. Honest gaps: the two-loop orchestration (goal + ambient, three rates) and the per-Space
**algorithm processes** (PLN→`Srule`, SubRep→`Sopt`, MOSES→`Sprog`, WILLIAM→`Smine`, …) are not built
yet; the `Sdyn` predictor is structurally real but **untrained**; HMH/dense Spaces are in-memory (not
`.act`-persisted).

## Use

```julia
using WorldModel
reg = SpaceRegistry()                 # store from the manifest (WORLDMODEL_STORE-overridable)
seed_world_model!(reg)                # the 14 canonical Spaces
cid = store_evidence!(reg, "frame_0042"; modality="vision")
ground!(reg, "u1", "(entity u1 unknown-block)", cid)   # Γ → Sent, evidence-anchored
encode_hmh!(reg, :trial1, Dict(:item=>(:block,:u1), :func=>(:role,:conductor)))  # 𝓔ₕₘₕ → Shmh
v = lift!(reg, :ctx1, Dict(:item=>(:block,:u1), :func=>(:role,:conductor)))       # Λ → Sctx
```

## License

MIT — see [LICENSE](LICENSE).
