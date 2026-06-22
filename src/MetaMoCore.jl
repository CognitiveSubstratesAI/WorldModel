# MetaMoCore.jl — MetaMo mechanisms delegated to Core's canonical lib/metamo (the WorldModel→lib slice).
#
# WorldModel's MetaMo.jl is a scalar governor: per-motive `clamp(Δ, ±max_drift)` + `clamp(·, 0, 1)` + argmax
# — shape-only vs lib/metamo's OpenPsi system. WorldModel's flat `(motive id urgency)` dict does NOT map
# onto lib/metamo's 8 *semantically-fixed* OpenPsi goals, so we do NOT fake a lift. Instead this exposes the
# REAL OpenPsi mechanisms (operating on a proper 8-goal / 6-modulator / 4-stimulus state) that the goal loop
# can adopt: the safe-region projection + boundary pressure (the faithful versions of the scalar clamp) and
# the OpenPsi appraisal Ψ (which WorldModel had none of). Evaluated through Core's faithful interpreter.
# Not exported (call `MetaMoCore.x`).

module MetaMoCore

using MeTTaCore
using MeTTaCore.Interpreter
using MeTTaCore.Interpreter.StandardMeTTa

const _SPACE = Ref{Any}(nothing)
function _space()
    if _SPACE[] === nothing
        sp = Space()
        load_core_stdlib!(sp)
        libmm = joinpath(dirname(pathof(MeTTaCore)), "..", "lib", "metamo")
        for f in ("config", "helpers", "state", "accessors", "appraisal", "decision", "bimonad", "dynamics")
            load_metta!(sp, read(joinpath(libmm, "$f.metta"), String))
        end
        _SPACE[] = sp
    end
    _SPACE[]::Space
end

_vec(v) = "(" * join(string.(v), " ") * ")"
_state(goals, mods) = "(motivation $(_vec(goals)) $(_vec(mods)))"
_eval1(e) = (r = metta_run(parse_program(e)[1][2], _space()); isempty(r) ? nothing : string(r[1]))

function _parse_vec(s)
    s === nothing && return nothing
    m = match(r"\(([^()]*)\)", s)
    m === nothing ? nothing : [parse(Float64, t) for t in split(strip(m.captures[1]))]
end

"OpenPsi boundary pressure via lib/metamo: 0 inside the safe region R, →1 near/over its boundary."
boundary_pressure(goals, mods) =
    (s = _eval1("(boundaryPressure $(_state(goals, mods)))"); s === nothing ? nothing : parse(Float64, s))

"Is the motivation state inside the safe region R (gInd ≥ θ_safe, ‖G‖ ≤ G_max)? via lib/metamo."
in_safe_region(goals, mods) = _eval1("(isInSafeRegion $(_state(goals, mods)))") == "True"

"""
    project_to_safe(goals, mods) -> (goals', mods')

Hard projection into the safe region R via lib/metamo `projectToSafeRegion` — floors gInd at θ_safe and
scales ‖G‖ down to G_max. The REAL safe-region restoration WorldModel's per-component [0,1] clamp cannot do.
"""
function project_to_safe(goals, mods)
    st = _state(goals, mods)
    (_parse_vec(_eval1("(motivationGoals (projectToSafeRegion $st))")),
     _parse_vec(_eval1("(motivationModulators (projectToSafeRegion $st))")))
end

"""
    appraise(goals, mods, stimulus) -> mods'

Full OpenPsi appraisal Ψ (eq #4) via lib/metamo `openPsiAppraise`: a 4-channel stimulus
(novelty, conduciveness, risk, effort) → the 6 updated modulators. WorldModel had no appraisal at all.
"""
appraise(goals, mods, stimulus) =
    _parse_vec(_eval1("(motivationModulators (openPsiAppraise $(_state(goals, mods)) (stimulus $(_vec(stimulus)))))"))

end # module MetaMoCore
