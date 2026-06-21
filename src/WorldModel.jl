# WorldModel — the live PRIMUS world-modeling application (infrastructure spine).
#
# The world model is a braid of named Spaces (PRIMUS-world-modeling_v2 §4.2 / Appendix A). The substrate is
# MORK/PathMap: each Space is a persistent byte-trie (one `.act` per Space), exactly as the connectome
# substrate (MORK/examples/connectome) already does — spaces coexist in one metagraph via shared
# identifiers, are created/deleted at RUNTIME (never hardcoded), persist to disk, and are queried by
# prefix-anchored zipper walks (derive-by-query).
#
# Layering (one concern per file):
#   Manifest   — config-driven paths/store/.act locations
#   Substrate  — the ONLY module touching MORK/PathMap (trie ops, .act persistence, prefix walks)
#   Registry   — the dynamic Space registry (logical layer)
#   Schema     — the 14 canonical Spaces as DATA + seeding
#
# STATUS: infrastructure spine (dynamic persistent Space registry). Next: prefix-anchored query layer,
# then the Γ/Λ bridging braid + two-loop scaffold; algorithms (PLN, SubRep, MOSES, …) are per-Space
# processes bound last, after the infra is solid.

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

using .Manifest
using .Substrate
using .HMHStore
using .Dense
using .Kernel
using .Registry
using .Schema
using .Braid
using .Beliefs

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
# Beliefs — truth values + staleness on the symbolic core (R10)
export assert_belief!, beliefs, decayed_confidence, stale_beliefs

end # module WorldModel
