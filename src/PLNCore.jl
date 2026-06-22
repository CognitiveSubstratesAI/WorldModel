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

# NOTE: deliberately NOT exporting `STV`/`truth_deduction` — they intentionally mirror PLN's names, so
# exporting them would collide with `using .PLN` in WorldModel. Callers use `PLNCore.truth_deduction`.

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

end # module PLNCore
