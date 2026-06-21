# Registry.jl — the dynamic Space registry (the logical layer over the substrate).
#
# Spaces are DATA, created and deleted at RUNTIME — never hardcoded Julia types. Each symbolic Space is a
# persistent MORK trie (via Substrate); dense/HMH Spaces are registered but bind their backend (FabricPC /
# HMH) only when that infra lands — until then their ops error loudly (registered ≠ backed; never mocked).

module Registry

using ..Manifest
using ..Substrate
using ..HMHStore
using ..Dense

export SpaceKind, SYMBOLIC, DENSE, HMH, WMSpace, SpaceRegistry
export create_space!, delete_space!, has_space, list_spaces, space_kind
export add!, atoms, count_atoms, query_head, persist!, store_dir, hmh_index, dense_store

"Representational regime of a Space (§3.2/§4.2). SYMBOLIC = a MORK trie; DENSE/HMH bind later."
@enum SpaceKind SYMBOLIC DENSE HMH

"One Space: a name + kind + its backend + the `.act` it persists to."
mutable struct WMSpace
    name::Symbol
    kind::SpaceKind
    backend::Any   # Substrate.Space (SYMBOLIC) | HMHStore.HMHIndex (HMH) | nothing (DENSE, pending)
    act_path::String
end

"The live registry of Spaces over one manifest-resolved store."
mutable struct SpaceRegistry
    manifest::Manifest.WMManifest
    spaces::Dict{Symbol, WMSpace}
end
function SpaceRegistry(m::Manifest.WMManifest=Manifest.manifest())
    Manifest.ensure_store(m)
    return SpaceRegistry(m, Dict{Symbol, WMSpace}())
end

store_dir(reg::SpaceRegistry) = reg.manifest.store

"""
    create_space!(reg, name; kind=SYMBOLIC) -> Symbol

Create a Space at runtime. A SYMBOLIC space gets a fresh MORK trie, RESTORED from its `.act` if one already
exists on disk (idempotent, like the connectome's `build_s_ent!`). DENSE/HMH spaces are registered pending
their backend. Errors if `name` already exists.
"""
function create_space!(reg::SpaceRegistry, name::Symbol; kind::SpaceKind=SYMBOLIC)
    haskey(reg.spaces, name) && error("space :$name already exists")
    ap = Manifest.act_path(reg.manifest, name)
    backend = nothing
    if kind == SYMBOLIC
        backend = Substrate.fresh()
        isfile(ap) && Substrate.load_act!(backend, ap)
    elseif kind == HMH
        backend = HMHStore.hmh_fresh()
    elseif kind == DENSE
        backend = Dense.dense_fresh()
    end
    reg.spaces[name] = WMSpace(name, kind, backend, ap)
    return name
end

"""
    delete_space!(reg, name; rm_disk=false) -> Bool

Remove a Space at runtime (drop from the registry; optionally delete its `.act` snapshot). Returns whether
a space was removed.
"""
function delete_space!(reg::SpaceRegistry, name::Symbol; rm_disk::Bool=false)
    haskey(reg.spaces, name) || return false
    rm_disk && isfile(reg.spaces[name].act_path) && rm(reg.spaces[name].act_path)
    delete!(reg.spaces, name)
    return true
end

has_space(reg::SpaceRegistry, name::Symbol) = haskey(reg.spaces, name)
list_spaces(reg::SpaceRegistry) = sort!(collect(keys(reg.spaces)))
space_kind(reg::SpaceRegistry, name::Symbol) = reg.spaces[name].kind

function _trie(reg::SpaceRegistry, name::Symbol)
    haskey(reg.spaces, name) || error("space :$name does not exist")
    s = reg.spaces[name]
    s.kind == SYMBOLIC ||
        error(
            "space :$name is $(s.kind); MORK atom ops apply to SYMBOLIC spaces (use the HMH ops for Shmh)"
        )
    return s.backend::Substrate.Space
end

"""
    hmh_index(reg, name) -> HMHStore.HMHIndex

The HMH index backing the HMH-kind Space `name` (e.g. `Shmh`). Errors if `name` is not HMH-backed.
"""
function hmh_index(reg::SpaceRegistry, name::Symbol)
    haskey(reg.spaces, name) || error("space :$name does not exist")
    s = reg.spaces[name]
    s.kind == HMH || error("space :$name is $(s.kind), not HMH-backed")
    s.backend === nothing && error("space :$name HMH backend not bound")
    return s.backend
end

"""
    dense_store(reg, name) -> Dense.DenseStore

The dense backend behind the DENSE-kind Space `name` (e.g. `Sctx`, `Sdyn`, `Skernel`). Errors if `name`
is not DENSE-backed.
"""
function dense_store(reg::SpaceRegistry, name::Symbol)
    haskey(reg.spaces, name) || error("space :$name does not exist")
    s = reg.spaces[name]
    s.kind == DENSE || error("space :$name is $(s.kind), not DENSE-backed")
    s.backend === nothing && error("space :$name dense backend not bound")
    return s.backend
end

"Add atom(s) (s-expression string) to Space `name`."
add!(reg::SpaceRegistry, name::Symbol, sexpr::AbstractString) =
    (Substrate.add_sexpr!(_trie(reg, name), sexpr); nothing)

"All atoms in Space `name` as s-expression strings."
atoms(reg::SpaceRegistry, name::Symbol) = Substrate.dump_atoms(_trie(reg, name))

"Number of atoms in Space `name`."
count_atoms(reg::SpaceRegistry, name::Symbol) = Substrate.val_count(_trie(reg, name))

"""
    query_head(reg, name, head) -> Vector{String}

Derive-by-query: atoms in Space `name` whose head symbol is `head` (e.g. `query_head(reg, :Sent,
"EvidenceOf")`). The basis for prefix-scoped lookups — seeds/links are *derived*, never pre-baked.
"""
function query_head(reg::SpaceRegistry, name::Symbol, head::AbstractString)
    open_pre = "(" * head * " "
    solo = "(" * head * ")"
    return String[a for a in atoms(reg, name) if startswith(a, open_pre) || a == solo]
end

"""
    persist!(reg, name) -> path

Snapshot Space `name` to its `.act` on disk (survives restart; `create_space!` restores it). Returns the
path written.
"""
persist!(reg::SpaceRegistry, name::Symbol) =
    Substrate.snapshot_act!(_trie(reg, name), reg.spaces[name].act_path)

end # module Registry
