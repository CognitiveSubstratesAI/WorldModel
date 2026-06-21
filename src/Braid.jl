# Braid.jl — the inter-space bridging flows (PRIMUS-world-modeling_v2 §4.3–4.5, §5 diagram).
#
# The world model is a braided object: the Spaces (Registry) are the nodes, these operators are the arrows.
# The SYMBOLIC-substrate flows are REAL on MORK now — evidence anchoring (→ Sevid), Γ grounding
# (Sevid → Sent/Smap/Srule with provenance), and R2 re-perception. The HMH/dense arrows of the diagram
# (𝓔_hmh: symbolic→Shmh, 𝓓_hmh: Shmh→Sctx, Λ: symbolic→Sctx+gating, kernel μR) are the NEXT braid layer:
# they bind when the Shmh/Sctx/Sdyn backends (HMH / FabricPC) land, and are deliberately ABSENT here rather
# than mocked.

module Braid

using ..Registry: SpaceRegistry, add!, query_head, hmh_index, dense_store
using ..HMHStore: store_episode!, retrieve, densify
using ..Dense: put_vec!, get_vec, attach_predictor!, predict_dense
using ..Kernel: kernel_mu

export content_id, store_evidence!, ground!, evidence_of, fetch_evidence
export encode_hmh!, retrieve_hmh, densify_hmh
export lift!, kernel_summary!, attach_dynamics!, predict_dynamics

"Content ID for an evidence payload — stable content addressing (§4.3)."
content_id(payload) = string(hash(payload) % 0xffffffff; base=16, pad=8)

"""
    store_evidence!(reg, payload; modality="obs") -> cid

Γ step (a) / R2: store `payload` as an immutable evidence shard `(evidence cid modality payload)` in Sevid
and return its content ID. Symbols point here; evidence is never overwritten (§4.3, §6.1.1).
"""
function store_evidence!(
    reg::SpaceRegistry, payload::AbstractString; modality::AbstractString="obs"
)
    cid = content_id((modality, payload))
    add!(reg, :Sevid, "(evidence $cid $modality $payload)")
    return cid
end

"""
    ground!(reg, key, atom, cid; into=:Sent) -> key

Γ grounding (§4.4): assert `atom` (an entity/relation s-expr) into symbolic space `into`, anchored to
evidence `cid` via an `(EvidenceOf key cid)` provenance pointer keyed by the entity id `key`. Atoms are
*indices into evidence*, not replacements for it (R2). E.g. ground an unknown block:
`ground!(reg, "u1", "(entity u1 unknown-block)", cid)`.
"""
function ground!(reg::SpaceRegistry, key::AbstractString, atom::AbstractString,
    cid::AbstractString;
    into::Symbol=:Sent)
    add!(reg, into, atom)
    add!(reg, into, "(EvidenceOf $key $cid)")
    return key
end

"""
    evidence_of(reg, key; into=:Sent) -> Vector{String}

Re-perception (R2): the evidence CIDs anchoring entity `key` — trace a symbol back to the evidence that
supports it, so it can be re-perceived / re-interpreted. Derive-by-query over the `(EvidenceOf …)` atoms.
"""
function evidence_of(reg::SpaceRegistry, key::AbstractString; into::Symbol=:Sent)
    needle = "(EvidenceOf $key "
    cids = String[]
    for a in query_head(reg, into, "EvidenceOf")
        startswith(a, needle) &&
            push!(cids, String(strip(a[(length(needle) + 1):(end - 1)])))
    end
    return cids
end

"""
    fetch_evidence(reg, cid) -> Vector{String}

Fetch the evidence shard(s) with content ID `cid` from Sevid — the raw payload behind a grounded symbol,
retrieved when a missing detail later matters (the cure for symbolic blindness, §4.3).
"""
fetch_evidence(reg::SpaceRegistry, cid::AbstractString) =
    [a for a in query_head(reg, :Sevid, "evidence") if startswith(a, "(evidence $cid ")]

# ── HMH arrows of the braid (§4.4, §6.1.2) — Shmh associative memory ────────────────────────────────

"""
    encode_hmh!(reg, key, slots; pointers=String[], into=:Shmh) -> key

𝓔_hmh: compile a symbolic record (role-filler `slots`: `role => (type, filler_symbol)`) into a single HMH
episode hypervector stored in Shmh under `key`, with `pointers` back to the symbolic core / evidence (§4.4).
"""
encode_hmh!(reg::SpaceRegistry, key::Symbol,
    slots::AbstractDict{Symbol, Tuple{Symbol, Symbol}}; pointers::Vector{String}=String[],
    into::Symbol=:Shmh) = store_episode!(hmh_index(reg, into), key, slots; pointers=pointers)

"""
    retrieve_hmh(reg, slots; topk=3, into=:Shmh) -> Vector{Tuple{Symbol,Float64}}

Structured associative recall from Shmh: the `topk` stored records most similar to the query record — past
trials / skills / affordances retrieved by structure even when symbolic descriptions differ (§6.1.2).
"""
retrieve_hmh(reg::SpaceRegistry, slots::AbstractDict{Symbol, Tuple{Symbol, Symbol}};
    topk::Int=3, into::Symbol=:Shmh) = retrieve(hmh_index(reg, into), slots; topk=topk)

"""
    densify_hmh(reg, key; into=:Shmh) -> Vector

𝓓_hmh: the dense hypervector for record `key` — the dense input neural modules in Sctx/Sdyn can consume.
"""
densify_hmh(reg::SpaceRegistry, key::Symbol; into::Symbol=:Shmh) =
    densify(hmh_index(reg, into), key)

# ── Dense / green arrows of the braid (§4.5, App C) — Λ lift, kernel μR, Sdyn conditioning ──────────

"""
    lift!(reg, key, query; into=:Sctx) -> Vector{Float64}

Λ lift (§4.5): retrieve the top Shmh record for `query` (role-filler slots), densify it (𝓓_hmh), and store
the resulting dense context vector under `key` in Sctx — the densified-retrieval half of building a context
vector for the dense controllers.
"""
function lift!(reg::SpaceRegistry, key::Symbol,
    query::AbstractDict{Symbol, Tuple{Symbol, Symbol}}; into::Symbol=:Sctx)
    hits = retrieve_hmh(reg, query; topk=1)
    isempty(hits) && error("lift!: Shmh has no records to retrieve")
    return put_vec!(dense_store(reg, into), key, densify_hmh(reg, hits[1][1]))
end

"""
    kernel_summary!(reg, vkeys, out; from=:Sctx, into=:Skernel) -> Vector{Float64}

Kernel μR (§4.5): kernel-mean-embed the named `from`-Space context vectors (MORKTensorNetworks sum-product
semiring Gram) into a single summary stored under `out` in Skernel — a set→vector summary that conditions
gating / re-ranking.
"""
function kernel_summary!(reg::SpaceRegistry, vkeys::AbstractVector{Symbol}, out::Symbol;
    from::Symbol=:Sctx, into::Symbol=:Skernel)
    ds = dense_store(reg, from)
    mu, _w = kernel_mu([get_vec(ds, k) for k in vkeys])
    return put_vec!(dense_store(reg, into), out, mu)
end

"""
    attach_dynamics!(reg, in_dim, hidden, out_dim; into=:Sdyn, rng) -> dense store

Bind a FabricPC predictive-coding model to Sdyn (the dynamics/control Space). Structure is real; training is
a later per-Space process.
"""
attach_dynamics!(reg::SpaceRegistry, in_dim::Int, hidden::Int, out_dim::Int;
    into::Symbol=:Sdyn, kwargs...) =
    attach_predictor!(dense_store(reg, into), in_dim, hidden, out_dim; kwargs...)

"""
    predict_dynamics(reg, x; into=:Sdyn, rng) -> Vector{Float64}

Condition Sdyn: run its FabricPC predictor forward on context vector `x` (the Sctx → Sdyn arrow).
"""
predict_dynamics(
    reg::SpaceRegistry, x::AbstractVector{<:Real}; into::Symbol=:Sdyn, kwargs...
) =
    predict_dense(dense_store(reg, into), x; kwargs...)

end # module Braid
