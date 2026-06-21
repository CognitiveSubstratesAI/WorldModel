# Substrate.jl — the MORK/PathMap backing for a Space.
#
# This is the ONLY module that touches MORK/PathMap. A Space is a persistent byte-trie (a MORK `Space`);
# atoms are s-expressions; persistence is a `.act` snapshot (cold-mmap reload); queries are prefix-anchored
# zipper walks (derive-by-query). Everything here mirrors the connectome substrate's proven primitives
# (MORK/examples/connectome). Keeping all substrate calls in one module lets the registry stay logical.

module Substrate

using MORK:
    Space, new_space, space_add_all_sexpr!, space_dump_all_sexpr, space_val_count, UNIT_VAL
using PathMap: act_from_zipper, act_save, act_open_mmap,
    read_zipper_at_path, zipper_to_next_val!, zipper_path, set_val_at!

export Space,
    fresh, add_sexpr!, val_count, dump_atoms, snapshot_act!, load_act!, walk_prefix

"A fresh, empty Space (its own MORK byte-trie)."
fresh() = new_space()

"Add one or more whitespace-separated s-expressions to the Space."
add_sexpr!(s::Space, src::AbstractString) = space_add_all_sexpr!(s, src)

"Number of atoms stored in the Space."
val_count(s::Space) = space_val_count(s)

"All atoms in the Space as s-expression strings."
function dump_atoms(s::Space)::Vector{String}
    return [
        String(strip(l)) for l in split(space_dump_all_sexpr(s), '\n') if !isempty(strip(l))
    ]
end

"""
    snapshot_act!(s, path) -> path

Persist the Space to `path` as a `.act` snapshot (`act_from_zipper` → `act_save`). Mirrors
`build_s_ent!`'s persistence half. Creates the parent directory if needed.
"""
function snapshot_act!(s::Space, path::AbstractString)
    isdir(dirname(path)) || mkpath(dirname(path))
    act_save(act_from_zipper(s.btm, _ -> UInt64(0)), path)
    return path
end

"""
    load_act!(s, path) -> Int

Restore a `.act` snapshot into the live Space `s` by copying every stored byte-path back in (cold-mmap the
snapshot, walk it, `set_val_at!`). Returns the atom count restored. This is the writable counterpart to the
connectome's read-only cold-mmap query.
"""
function load_act!(s::Space, path::AbstractString)::Int
    tree = act_open_mmap(path)
    rz = read_zipper_at_path(tree, UInt8[])
    n = 0
    while zipper_to_next_val!(rz)
        set_val_at!(s.btm, collect(zipper_path(rz)), UNIT_VAL)
        n += 1
    end
    return n
end

"""
    walk_prefix(f, s, prefix)

Derive-by-query: descend the trie to byte-`prefix` and invoke `f(rel_bytes)` for every atom under it
(`rel_bytes` are relative to the anchor). The O(subtrie) primitive behind prefix-scoped Space queries —
the connectome's `read_zipper_at_path` frontier walk.
"""
function walk_prefix(f::Function, s::Space, prefix::Vector{UInt8})
    rz = read_zipper_at_path(s.btm, prefix)
    while zipper_to_next_val!(rz)
        f(collect(zipper_path(rz)))
    end
    return nothing
end

end # module Substrate
