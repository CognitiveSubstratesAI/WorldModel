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
using ..Dense: put_vec!, get_vec, attach_predictor!, predict_dense, train_dense!
using ..Kernel: kernel_mu
using Random: AbstractRNG, default_rng
using SHA: sha256                      # evidence CIDs — see `content_id` (was a truncated 32-bit hash)

export content_id, store_evidence!, ground!, evidence_of, fetch_evidence
export encode_hmh!, retrieve_hmh, densify_hmh
export lift!, kernel_summary!, attach_dynamics!, predict_dynamics, train_dynamics!

"""
Content ID for an evidence payload — stable content addressing (§4.3).

WAS a TRUNCATED 32-BIT Julia hash: `string(hash(payload) % 0xffffffff; base=16, pad=8)`. Evidence
anchoring is the referential glue of the whole braid (§5.4: a symbolic assertion "should usually point
to content-addressed evidence in `S_evid`"), so a CID collision does not merely mislabel — it SILENTLY
MERGES two distinct evidence shards under one id. `evidence_of` then reports one symbol as supported by
the other's evidence, and `wm-evidence-count` (which feeds `EvidenceConfidence`) INFLATES. Confidence
rising because two unrelated observations hashed alike is the worst failure shape available here:
silent, and in the direction of over-confidence. Birthday collision ≈65k shards — reachable, since
`_perceive` mints a shard per distinct input.

Now canonical SHA-256, matching `OmegaClaw/src/Gate.jl:55` (`bytes2hex(sha256(...))`) — the same
primitive was already in the tree one package away. The payload is LENGTH-PREFIXED before hashing
(`_canon`, mirroring `Gate.jl:22`) so that a composite payload cannot alias a different field split:
without it `("ab","c")` and `("a","bc")` hash identically.

⚠️ NOT the end state. In a byte-trie THE PATH IS THE CONTENT ADDRESS — whitepaper §2.1 calls Atomspace
"a typed, CONTENT-ADDRESSED metagraph", and MORK already ships structural content-addressing
(`MORK/src/kernel/Sinks.jl:769` `HashSink`, mirroring upstream `sinks.rs`, hashing a SUB-TRIE via
`zipper_fork!` + path enumeration). The correct long-run design stores evidence in a prefix-scoped trie
region and uses its path as the id, needing no hash at all. That presupposes the shared-Atomspace work
(Figure 3's centre), so this is the honest interim: a real digest instead of a 32-bit one, chosen so it
does not foreclose the trie-path design. Do NOT "upgrade" this to `_zipper_subtrie_hash` — that returns
a `UInt64` and is built for VERIFICATION, not identity; it would trade a 32-bit collision risk for a
64-bit one.

COMPATIBILITY: CIDs are never written as literals anywhere (verified: no CID constants in tests or
fixtures — every one comes from `store_evidence!` at runtime), and a shard and its `(EvidenceOf sym cid)`
link are persisted together, so previously-persisted `.act` state stays internally consistent. The only
behavioural change is that re-storing a payload that was first stored under the old scheme yields a new
id and will not dedupe against the old shard.

⚠️ SUBSTRATE CONSTRAINT — 128 bits, NOT the full digest, and this is NOT the bug being fixed.
MORK symbols are capped at 63 BYTES by the Rule-of-64 encoding (`MORK/src/expr/Expr.jl:6`:
`SymbolSize: 0b1100_SSSS (0xC1..0xFF) — S = 1..63 bytes follow`). A full SHA-256 hex digest is 64
characters — one over — and MORK TRUNCATES IT SILENTLY: the atom stores and reads back fine, one
character shorter than written, so `fetch_evidence` can never match the id it was given. Measured:
    cid    = 2a22…7878e   (64)
    stored = (evidence 2a22…7878 vision saw-a-tree)   (63 — final char gone, no error)
So the id is the FIRST 128 BITS of the digest. That is a deliberate, sized truncation, not the
32-bit accident it replaces: birthday collision moves from ~65 000 shards to ~1.8e19, and 32 hex
characters leave headroom under the 63-byte cap for any future prefixing. Do not raise it to 64.
"""
const _CID_HEX = 32                       # 128 bits — see the Rule-of-64 note above (max 63)
content_id(payload) = bytes2hex(sha256(codeunits(_canon_payload(payload))))[1:_CID_HEX]

# length-prefixed canonical encoding (`len:bytes;`) — no field-boundary aliasing. Mirrors
# `OmegaClaw/src/Gate.jl:22` `_canon`. A scalar payload is encoded as a single field.
function _canon_payload(payload)::String
    fields = payload isa AbstractVector || payload isa Tuple ? String[string(f) for f in payload] :
                                                               String[string(payload)]
    io = IOBuffer()
    for f in fields
        b = codeunits(f)
        print(io, length(b), ':'); write(io, b); print(io, ';')
    end
    String(take!(io))
end

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

"""
    train_dynamics!(reg, transitions; hidden=64, lr=0.01, epochs=100, adam=false, rng, into=:Sdyn)
        -> (dense store, energy history)

Train the Sdyn FabricPC forward model on `(x_t → x_{t+1})` `transitions` — a vector of `(Vector, Vector)`
pairs of equal length — so `predict_dynamics`/`fast_step!` become a LEARNED forward model instead of the
untrained `initialize_params` graph. Stacks the pairs into rows-are-batch matrices and delegates to
`Dense.train_dense!`, which attaches a fresh `x → h → y` predictor sized to the data if none is bound and
writes the trained params back into the Sdyn dense store. This closes the ADR-061 "Sdyn in-loop training"
gap (structure + forward pass were live; only the `train_pcn` call was missing).
"""
function train_dynamics!(reg::SpaceRegistry, transitions::AbstractVector;
    hidden::Int=64, lr::Real=0.01, epochs::Real=100, adam::Bool=false,
    rng::AbstractRNG=default_rng(), into::Symbol=:Sdyn)
    isempty(transitions) && error("train_dynamics!: no transitions to train on")
    X = permutedims(reduce(hcat, [Float64.(first(t)) for t in transitions]))   # (N, D_in)  rows = batch
    Y = permutedims(reduce(hcat, [Float64.(last(t)) for t in transitions]))    # (N, D_out) rows = batch
    return train_dense!(dense_store(reg, into), X, Y;
        hidden=hidden, lr=lr, epochs=epochs, adam=adam, rng=rng)
end

end # module Braid
