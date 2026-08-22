# Mining.jl — pattern mining / compression over a Space, into Smine (WILLIAM; §4.8, §A.13).
#
# Smine runs the ambient loop's async mining + compression: discover recurring regularities, compress
# experience, propose abstractions. A per-Space PROCESS that reads a symbolic Space's atoms and writes
# the top-k patterns into Smine.
#
# CALLS `MorkSupercompiler.run_trie_miner` DIRECTLY (2026-08-05). It previously went through
# `AdaptiveCompression.mine_patterns`, which was a STRING SHIM around this very function —
# `AdaptiveCompression.jl:119-128` unpacks text to `Vector{SNode}`, calls `run_trie_miner`, and
# re-serialises; we then re-parsed that text back into pairs. Same algorithm, two extra round trips.
# Removing it drops a dependency whose only checkout lives OUTSIDE the workspace (`~/WILLIAM.retired`)
# with a remote that 403s — i.e. an unrestorable single point of failure under Core.
#
# ⚠️ WHAT THIS IS AND IS NOT. `run_trie_miner` is a FREQUENCY miner: it scores by
# `count * log(1 + total/count)` (TF-IDF-shaped) and sorts descending. It is NOT WILLIAM's
# incremental compression, and calling it "codec-search" (as CODEMAP did) overstates it. All three
# normative sources rank by DESCRIPTION LENGTH, not support:
#   * Franz IC theory (Franz/Antonenko/Soletskyi 2020) — shortest-feature-first, primary key l(f),
#     tie-break l(f'), gated by the strict compression condition l(f)+l(r) < l(x). It defines NO
#     notion of support anywhere.
#   * MORK-WILLIAM clarifications (Goertzel, Sept 2025) — gain(r,S) = L(S) − L(S') − C(r), keep while
#     cumulative gain > 0.
#   * AdaptiMORK v8 §4.5 (normative) — ΔL used for "promotion decisions, precedence ordering, rule
#     retirement"; its sort key is (−ΔL, −span, start, type_id) with NO frequency term. Frequency is
#     licensed only as a candidate-generation GATE (occs >= 3, applied BEFORE ΔL is computed).
# So this hook mines frequent patterns, which is useful and is what it has always done — but it does
# not deliver WILLIAM's compression guarantee, and nothing downstream should assume it does.
# MorkSupercompiler's own schema DSL keeps the two apart: `define-trie-miner` (§10.3.2, implemented,
# this) vs `define-codec-search` (§10.3.3, a metadata stub with no runtime body).

module Mining

using ..Registry: SpaceRegistry, atoms, add!, query_head
import MorkSupercompiler

export mine!, mined_patterns

"""
    mine!(reg; from=:Sent, into=:Smine, k=8, max_depth=4) -> Vector{Tuple{String,Float64}}

Frequency pattern mining (the ambient loop's mining hook): run MorkSupercompiler's trie miner over the
atoms of Space `from`, store the top-`k` frequent/compressive patterns (with weights) as `(pattern P w)`
atoms in Smine, and return them. Compresses recurring experience into reusable structure (§A.13).
"""
function mine!(reg::SpaceRegistry; from::Symbol=:Sent, into::Symbol=:Smine,
    k::Int=8, max_depth::Int=4)
    data = atoms(reg, from)
    isempty(data) && return Tuple{String, Float64}[]
    # Per-atom parse with SKIP-ON-FAILURE, mirroring the shim's `_unpack_collapse_list`: `data` is
    # already split by `dump_atoms`, and one unparseable atom must not abort the whole batch.
    data_atoms = MorkSupercompiler.SNode[]
    for a in data
        try
            append!(data_atoms, MorkSupercompiler.parse_program(a))
        catch
            continue
        end
    end
    isempty(data_atoms) && return Tuple{String, Float64}[]
    results = MorkSupercompiler.run_trie_miner(
        MorkSupercompiler.TEMPLATE_EVIDENCE_CAPSULE, data_atoms; k=k, max_depth=max_depth)
    pairs = [
        (isempty(pat) ? "()" : "(" * join(string.(pat), " ") * ")", w) for
        (pat, w) in results
    ]
    for (pat, w) in pairs
        add!(reg, into, "(pattern $pat $w)")
    end
    return pairs
end

"The mined-pattern atoms currently stored in Smine."
mined_patterns(reg::SpaceRegistry; into::Symbol=:Smine) = query_head(reg, into, "pattern")

end # module Mining
