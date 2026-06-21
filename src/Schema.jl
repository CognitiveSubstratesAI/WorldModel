# Schema.jl — the canonical 14 world-model Spaces as DATA.
#
# Not 14 implementations: 14 rows (PRIMUS-world-modeling_v2 §4.2 / Appendix A). Adding or removing a
# canonical Space is a one-line edit here; ad-hoc Spaces are created the same way via `create_space!`.
# SYMBOLIC spaces are live on MORK/PathMap now; DENSE/HMH bind their backends when that infra lands.

module Schema

using ..Registry: SpaceRegistry, SYMBOLIC, DENSE, HMH, create_space!, has_space

export WM_SPACE_SCHEMA, seed_world_model!

"`(name, kind, role)` for each canonical Space (Appendix A; roles abbreviated)."
const WM_SPACE_SCHEMA = (
    (:Senv, SYMBOLIC, "environment interface — observations / actions"),
    (:Sevid, SYMBOLIC, "evidence store — immutable shards, CIDs [R2]"),
    (:Sent, SYMBOLIC, "entities + relations — identity hypotheses [R1,R4]"),
    (:Smap, SYMBOLIC, "spatiotemporal map — layout, decay [R6,R10]"),
    (:Srule, SYMBOLIC, "rules + uncertain inference — PLN [R4,R7,R10]"),
    (:Smotive, SYMBOLIC, "motives + certificates — policy governor (MetaMo)"),
    (:Sopt, SYMBOLIC, "options/subgoals — SubRep-certified [R5]"),
    (:Sxfer, SYMBOLIC, "transfer/composition — TransWeave [R9]"),
    (:Sprog, SYMBOLIC, "program space — MOSES/GEO-EVO [R5]"),
    (:Smine, SYMBOLIC, "pattern mining/compression — WILLIAM [R5,R11]"),
    (:Sctx, DENSE, "dense context workspace [R3]"),
    (:Sdyn, DENSE, "predictive dynamics + control — fast path (FabricPC) [R7,R11]"),
    (:Shmh, HMH, "HMH associative memory — episodes/skills [R3,R5,R6,R11]"),
    (:Skernel, DENSE, "kernel/MKME — set→vector summaries")
)

"""
    seed_world_model!(reg) -> SpaceRegistry

Create the 14 canonical Spaces from [`WM_SPACE_SCHEMA`](@ref), skipping any already present (so it is safe
to call against a store that already has persisted `.act` snapshots).
"""
function seed_world_model!(reg::SpaceRegistry)
    for (name, kind, _role) in WM_SPACE_SCHEMA
        has_space(reg, name) || create_space!(reg, name; kind=kind)
    end
    return reg
end

end # module Schema
