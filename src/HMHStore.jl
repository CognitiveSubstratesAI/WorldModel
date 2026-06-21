# HMHStore.jl — the HMH-backed substrate for the Shmh associative-memory Space.
#
# Shmh stores role-filler episode hypervectors (HMH / RHMH §8) plus pointers back to the symbolic core and
# evidence (§4.4). 𝓔_hmh encodes a symbolic record into ONE episode hypervector; retrieval is by hypervector
# similarity (structured associative recall — "similar situations even when descriptions differ", §6.1.2);
# 𝓓_hmh densification is the hypervector itself (BipolarMAP = {±1}^D, the algebra channel of Appendix B).
#
# This is the ONLY module that touches HMH/FactorVSA, mirroring Substrate.jl's isolation of MORK/PathMap.

module HMHStore

using FactorVSA: HV, BipolarMAP, random_hv
using HMH: RoleBook, role!, Episode, encode_episode, recover_slot, consolidate

export HMHIndex, hmh_fresh, store_episode!, retrieve, densify, record_keys, record_pointers
export consolidate!

const DEFAULT_DIM = 1024

"""
    HMHIndex

One Shmh index: the shared role atoms (`rb`), a deterministic symbol→filler codebook (`fillers`), a fixed
schema atom, and per-record `episodes` / encoded `codes` / back-`pointers`.
"""
mutable struct HMHIndex
    dim::Int
    rb::RoleBook
    fillers::Dict{Symbol, HV{BipolarMAP}}
    schema::HV{BipolarMAP}
    episodes::Dict{Symbol, Episode}
    codes::Dict{Symbol, HV{BipolarMAP}}
    pointers::Dict{Symbol, Vector{String}}
end

"A fresh, empty HMH index of dimension `dim`."
hmh_fresh(dim::Int=DEFAULT_DIM) = HMHIndex(
    dim, RoleBook(dim), Dict{Symbol, HV{BipolarMAP}}(), random_hv(BipolarMAP, dim),
    Dict{Symbol, Episode}(), Dict{Symbol, HV{BipolarMAP}}(),
    Dict{Symbol, Vector{String}}())

# deterministic filler hypervector for a symbol (lazily created, stable within an index)
_filler!(idx::HMHIndex, sym::Symbol) =
    get!(() -> random_hv(BipolarMAP, idx.dim), idx.fillers, sym)

_episode(idx::HMHIndex, slots::AbstractDict{Symbol, Tuple{Symbol, Symbol}}) =
    Episode(
        idx.schema;
        slots=Dict{Symbol, Tuple{Symbol, HV{BipolarMAP}}}(
            role => (τ, _filler!(idx, fsym)) for (role, (τ, fsym)) in slots)
    )

"""
    store_episode!(idx, key, slots; pointers=String[]) -> key

𝓔_hmh: encode a symbolic record into ONE role-filler episode hypervector and store it under `key` with
back-pointers. `slots` maps `role => (type, filler_symbol)` — the record's role-filler structure (§6.1.2).
"""
function store_episode!(idx::HMHIndex, key::Symbol,
    slots::AbstractDict{Symbol, Tuple{Symbol, Symbol}}; pointers::Vector{String}=String[])
    E = _episode(idx, slots)
    idx.episodes[key] = E
    idx.codes[key] = encode_episode(E, idx.rb)
    idx.pointers[key] = pointers
    return key
end

# bipolar similarity — normalized dot of the ±1 channels (1.0 = identical)
_sim(a::HV{BipolarMAP}, b::HV{BipolarMAP}) =
    sum(Float64.(a.data) .* Float64.(b.data)) / length(a.data)

"""
    retrieve(idx, slots; topk=3) -> Vector{Tuple{Symbol,Float64}}

Structured associative recall: encode a query record (same `role => (type, filler_symbol)` form) and return
the `topk` stored records by hypervector similarity, best first (§6.1.2).
"""
function retrieve(
    idx::HMHIndex, slots::AbstractDict{Symbol, Tuple{Symbol, Symbol}}; topk::Int=3
)
    Hq = encode_episode(_episode(idx, slots), idx.rb)
    scored = Tuple{Symbol, Float64}[(key, _sim(Hq, H)) for (key, H) in idx.codes]
    sort!(scored; by=x -> -x[2])
    return scored[1:min(topk, length(scored))]
end

"𝓓_hmh: the dense hypervector for record `key` (the algebra channel, Appendix B)."
densify(idx::HMHIndex, key::Symbol) = idx.codes[key].data

"Back-pointers to the symbolic core / evidence for record `key`."
record_pointers(idx::HMHIndex, key::Symbol) = get(idx.pointers, key, String[])

"All stored record keys."
record_keys(idx::HMHIndex) = sort!(collect(keys(idx.codes)))

"""
    consolidate!(idx, key) -> key | nothing

Episodic-semantic consolidation (RHMH Eq 77): bundle all stored episodes into one template hypervector
and store it under `key` — recurring slots reinforce, idiosyncratic ones average out (schema formation).
The ambient loop's memory-consolidation step. Returns `nothing` if there are no episodes yet.
"""
function consolidate!(idx::HMHIndex, key::Symbol)
    eps = collect(values(idx.episodes))
    isempty(eps) && return nothing
    idx.codes[key] = consolidate(eps, idx.rb)
    return key
end

end # module HMHStore
