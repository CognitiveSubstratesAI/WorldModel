# Mining.jl — pattern mining / compression over a Space, into Smine (WILLIAM; §4.8, §A.13).
#
# Smine runs the ambient loop's async mining + compression: discover recurring regularities, compress
# experience, propose abstractions. This wires the canonical algorithm — WILLIAM (the AdaptiveCompression
# package's §15.6 three-stage trie miner via MorkSupercompiler) — NOT a stand-in. A per-Space PROCESS that
# reads a symbolic Space's atoms and writes the top-k frequent/compressive patterns into Smine.

module Mining

using ..Registry: SpaceRegistry, atoms, add!, query_head
using AdaptiveCompression: mine_patterns

export mine!, mined_patterns

# Parse WILLIAM's "((Pair (pat) w) (Pair (pat) w) …)" output into (pattern_string, weight) pairs.
function _parse_pairs(out::AbstractString)
    res = Tuple{String, Float64}[]
    s = strip(out)
    (length(s) >= 2 && s[1] == '(' && s[end] == ')') || return res
    inner = s[2:(prevind(s, lastindex(s)))]
    depth = 0
    gstart = 0
    for i in eachindex(inner)
        c = inner[i]
        if c == '('
            depth == 0 && (gstart = i)
            depth += 1
        elseif c == ')'
            depth -= 1
            if depth == 0
                body = strip(inner[(gstart + 1):(i - 1)])     # "Pair (pat) w"
                startswith(body, "Pair") || continue
                rest = strip(body[5:end])                     # "(pat) w"
                sp = findlast(' ', rest)
                sp === nothing && continue
                w = tryparse(Float64, strip(rest[(sp + 1):end]))
                w === nothing && continue
                push!(res, (String(strip(rest[1:(sp - 1)])), w))
            end
        end
    end
    return res
end

"""
    mine!(reg; from=:Sent, into=:Smine, k=8, max_depth=4) -> Vector{Tuple{String,Float64}}

WILLIAM pattern mining (the ambient loop's mining hook): run the AdaptiveCompression trie miner over the
atoms of Space `from`, store the top-`k` frequent/compressive patterns (with weights) as `(pattern P w)`
atoms in Smine, and return them. Compresses recurring experience into reusable structure (§A.13).
"""
function mine!(reg::SpaceRegistry; from::Symbol=:Sent, into::Symbol=:Smine,
    k::Int=8, max_depth::Int=4)
    data = atoms(reg, from)
    isempty(data) && return Tuple{String, Float64}[]
    pairs = _parse_pairs(mine_patterns("(" * join(data, " ") * ")", k, max_depth))
    for (pat, w) in pairs
        add!(reg, into, "(pattern $pat $w)")
    end
    return pairs
end

"The mined-pattern atoms currently stored in Smine."
mined_patterns(reg::SpaceRegistry; into::Symbol=:Smine) = query_head(reg, into, "pattern")

end # module Mining
