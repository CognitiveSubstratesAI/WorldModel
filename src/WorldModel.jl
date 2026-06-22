# WorldModel — the live PRIMUS world-modeling application (infrastructure spine).
#
# The world model is a braid of named Spaces (PRIMUS-world-modeling_v2 §4.2 / Appendix A). The substrate is
# MORK/PathMap: each Space is a persistent byte-trie (one `.act` per Space), exactly as the connectome
# substrate (MORK/examples/connectome) already does — spaces coexist in one metagraph via shared
# identifiers, are created/deleted at RUNTIME (never hardcoded), persist to disk, and are queried by
# prefix-anchored zipper walks (derive-by-query).
#
# Layering (one concern per file): substrate adapters (Substrate=MORK/PathMap, HMHStore=HMH/FactorVSA,
# Dense=FabricPC, Kernel=MORKTensorNetworks) → Registry (dynamic Space registry) → Schema (14 Spaces as
# data) → Braid (Γ/Λ/𝓔/𝓓/μR inter-space flows) → Beliefs (TV/staleness) → the algorithm PROCESSES (PLN,
# SubRep, Mining=WILLIAM, MetaMo, MOSES/GEO-EVO, TransWeave) → Loops (two-loop × three-rate cycle).
#
# STATUS: complete at the architecture level — 14 Spaces (real substrate) → braid → two-loop → 7 per-Space
# processes, all on the live stack, no mocks. Remaining is hardening (train Sdyn; .act-persist HMH/dense)
# and the in-code documented depth-limits of MOSES/MetaMo/GEO-EVO/TransWeave.

module WorldModel

const WORLDMODEL_VERSION = v"0.3.0"

include("Manifest.jl")
include("Substrate.jl")
include("HMHStore.jl")
include("Dense.jl")
include("Kernel.jl")
include("Registry.jl")
include("Schema.jl")
include("Braid.jl")
include("Beliefs.jl")
include("PLN.jl")
include("PLNCore.jl")
include("SubRep.jl")
include("SubRepCore.jl")
include("Mining.jl")
include("MetaMo.jl")
include("MOSES.jl")
include("TransWeave.jl")
include("Loops.jl")

using .Manifest
using .Substrate
using .HMHStore
using .Dense
using .Kernel
using .Registry
using .Schema
using .Braid
using .Beliefs
using .PLN
using .PLNCore
using .SubRep
using .SubRepCore
using .Mining
using .MetaMo
using .MOSES
using .TransWeave
using .Loops

# ── Public surface ────────────────────────────────────────────────────────────────────────────────
# Config / store
export WMManifest, manifest, act_path, ensure_store, describe
# Registry + Space lifecycle
export SpaceKind, SYMBOLIC, DENSE, HMH, WMSpace, SpaceRegistry
export create_space!,
    delete_space!, has_space, list_spaces, space_kind, store_dir, hmh_index
# Scoped operations
export add!, atoms, count_atoms, query_head, persist!
# Canonical schema
export WM_SPACE_SCHEMA, seed_world_model!
# Braid — inter-space flows: symbolic (Γ grounding + evidence anchoring + R2) and HMH (𝓔/𝓓 + recall)
export content_id, store_evidence!, ground!, evidence_of, fetch_evidence
export encode_hmh!, retrieve_hmh, densify_hmh
# HMH store surface (Shmh backend)
export HMHIndex, record_keys, record_pointers
# Dense — green braid arrows (Λ lift, kernel μR, Sdyn FabricPC predictor) + dense store surface
export lift!, kernel_summary!, attach_dynamics!, predict_dynamics
export DenseStore, dense_store, get_vec, has_vec, vec_keys, has_predictor
# Kernel / MKME service (Skernel, MORKTensorNetworks-backed)
export kernel_mu, gram, mmd
# PLN — uncertain inference over Srule (the goal loop's reasoning process)
export STV, truth_deduction, node_stv, impl_stv, assert_implication!, deduce, select_action
# SubRep — option admission over Sopt (CDS gate + certificates + zero-shot reuse)
export cds_margin, cds_admit, admit_option!, admitted_options, reuse_options
# Mining — WILLIAM pattern mining over a Space into Smine
export mine!, mined_patterns
# MetaMo — the motive governor over Smotive (appraise → damp → decide)
export set_motive!, motives, govern!, dominant_motive
# MOSES / GEO-EVO — evolutionary program synthesis over Sprog (geo = weakness-regularized)
export synthesize!, geo_synthesize!, programs
# TransWeave — transfer/composition over Sxfer (BD-residual bounded-order-effect certificate, R9)
export add_correspondence!,
    correspondence, transfer, bd_residual, admit_transfer!, transfers
# Loops — the two-loop × three-rate cognitive cycle over the braid (§3.1, §3.4)
export CognitiveLoop, Observation, fast_step!, mid_step!, slow_step!, run_cycle!
# Beliefs — truth values + staleness on the symbolic core (R10)
export assert_belief!, beliefs, decayed_confidence, stale_beliefs

end # module WorldModel
