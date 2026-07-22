# PLNCore.jl — PLN that DELEGATES to Core's canonical lib/pln (the WorldModel→lib remediation).
#
# Instead of re-implementing PLN's truth formulas in Julia (PLN.jl shipped only deduction — 1 of the
# ~11 canonical formulas, with no chainer / factor graph / ECAN), this evaluates the REAL
# `Core/lib/pln/pln_core_logic.metta` through Core's faithful MeTTa interpreter. No new substrate, no
# adapter beyond a thin atom↔Julia marshalling: WorldModel runs the canonical algorithm.
#
# Per the engine-per-workload design (Core docs/src/backends.md): the interpreter is the faithful
# evaluator (it reduces the grounded arithmetic in the truth formulas); WorldModel calls it via mc_run's
# sibling entry `metta_run`. All-Julia, so the crossing is zero-copy (no FFI, unlike CeTTa's C↔Rust).

module PLNCore

using MeTTaCore
using MeTTaCore.Interpreter
using MeTTaCore.Interpreter.StandardMeTTa
using ..Registry: SpaceRegistry
using ..Beliefs: beliefs
using ..PLN: node_stv

# NOTE: deliberately NOT exporting `STV`/`truth_deduction`/`select_action` — they intentionally mirror
# PLN's names, so exporting would collide with `using .PLN` in WorldModel. Callers use `PLNCore.x`.

"A PLN simple truth value (mirrors PLN.STV): strength `s` ∈ [0,1], confidence `c` ∈ [0,1)."
const STV = NamedTuple{(:s, :c), Tuple{Float64, Float64}}

# Lazily-built, process-cached Core space holding the canonical lib/pln (stdlib + stv + core logic).
const _SPACE = Ref{Any}(nothing)

function _space()
    if _SPACE[] === nothing
        sp = Space()
        load_core_stdlib!(sp)
        libpln = joinpath(dirname(pathof(MeTTaCore)), "..", "lib", "pln")
        load_metta!(sp, read(joinpath(libpln, "stv.metta"), String))
        load_metta!(sp, read(joinpath(libpln, "pln_core_logic.metta"), String))
        _SPACE[] = sp
    end
    _SPACE[]::Space
end

_stv_str(t) = "(stv $(t.s) $(t.c))"

"Evaluate a MeTTa expression that returns an `(stv s c)` and marshal it back to an `STV` (or `nothing`)."
function _eval_stv(expr::AbstractString)
    res = metta_run(parse_program(expr)[1][2], _space())
    isempty(res) && return nothing
    m = match(r"\(stv\s+([-\d.eE]+)\s+([-\d.eE]+)\)", string(res[1]))
    m === nothing ? nothing : (s = parse(Float64, m.captures[1]), c = parse(Float64, m.captures[2]))::STV
end

"""
    truth_deduction(P, Q, R, PQ, QR) -> Union{STV,Nothing}

PLN deduction via the CANONICAL `lib/pln` `Truth_Deduction` (faithful MeTTa, evaluated through Core),
replacing PLN.jl's Julia re-implementation. Same five-STV interface; returns the lib's `(stv s c)`
(including its `(stv 1 0)` ignorance fallback when the consistency preconditions fail).
"""
truth_deduction(P::STV, Q::STV, R::STV, PQ::STV, QR::STV) =
    _eval_stv("(Truth_Deduction $(_stv_str(P)) $(_stv_str(Q)) $(_stv_str(R)) $(_stv_str(PQ)) $(_stv_str(QR)))")

"""
    select_action(reg, goal; into=:Srule) -> Vector{Tuple{String,Float64}}

Canonical action-selection over Srule, best-first. Beyond the 1-hop `X ⇒ goal` scan that
`PLN.select_action` does, this adds the 2-hop TRANSITIVE candidates `X ⇒ Y ⇒ goal`, scored by the
canonical lib/pln deduction (`truth_deduction`) — multi-hop inference the shallow stand-in cannot do.
This is the canonical formula on the LIVE goal-loop path (mid_step!), not just available.
"""
function select_action(reg::SpaceRegistry, goal::AbstractString; into::Symbol = :Srule)
    impls = Tuple{String, String, Float64, Float64}[]            # (a, b, s, c) for each a ⇒ b
    for (k, s, c, _t) in beliefs(reg; into = into)
        parts = split(String(k), "=>")
        length(parts) == 2 || continue
        push!(impls, (String(parts[1]), String(parts[2]), s, c))
    end
    score = Dict{String, Float64}()
    bump!(id, v) = (score[id] = max(get(score, id, -Inf), v))
    for (a, b, s, c) in impls                                    # 1-hop:  X ⇒ goal
        b == goal && bump!(a, s * c)
    end
    for (a, b, sab, cab) in impls                                # 2-hop:  X ⇒ Y ⇒ goal (deduction)
        for (y, g, sbg, cbg) in impls
            (y == b && g == goal) || continue
            # ABSENCE SKIPS the candidate — matching lib/pln's own `(= (STV $stv) (empty))`: an unknown
            # endpoint means the deduction has no premises, so the candidate must VANISH rather than be
            # scored. (Previously node_stv fabricated (0,0), which failed `_consistent`'s `as > 0`, took
            # the (s=1,c=0) fallback and inserted every 2-hop candidate at a flat 0.0 — no ranking signal,
            # yet selectable when no 1-hop candidate existed.) Skipping BEFORE truth_deduction also drops
            # a parse+metta_run+regex round-trip per pair, which was pure waste on the live mid_step! path.
            P = node_stv(reg, a; into); Q = node_stv(reg, b; into); R = node_stv(reg, goal; into)
            (P === nothing || Q === nothing || R === nothing) && continue
            tv = truth_deduction(P, Q, R, (s = sab, c = cab), (s = sbg, c = cbg))
            tv === nothing || bump!(a, tv.s * tv.c)
        end
    end
    out = sort!(collect(score); by = x -> -x[2])
    return [(id, v) for (id, v) in out]
end

end # module PLNCore
