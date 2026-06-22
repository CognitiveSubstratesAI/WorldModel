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

"""
    govern(goals, mods, stimulus, candidates) -> (; chosen, goals, mods) | nothing

The full canonical MetaMo governance step (`metamoGovern`, dynamics.metta): Ψ appraise the OpenPsi state
under `stimulus` → 𝔻 MAGUS-decide the best action among `candidates` → homeostatic-damp → project to the
safe region R. Each candidate is a NamedTuple `(; id, corrs, risk, dg)` (8-vector goal correlations, scalar
risk, 8-vector ΔG). Returns the chosen action `id` (the goal to pursue) and the safe next motive state.
This is the goal loop's motive governor (§A.9 / infrastructure: S_motive → MetaMo → action selection).
"""
# ── native-Julia MAGUS score 𝔻 (eq #10/#11), bisimulation-validated against lib/metamo magusScore (1e-6) ──
# Grounding magusScore as an op does NOT help (it's called internally by magusBestLoop's rule body, which
# the grounded-op path never tokenizes). The three-oracle cross-check showed the 8.6s is Core's tree-walker,
# NOT the algorithm (CeTTa ~50ms, PeTTa/SWI-Prolog ~7.6ms). So `govern` runs the DECISION in native Julia
# (zero-copy, the documented best path without MeTTa-IL): lib only for the cheap appraisal Ψ.
_msig(x) = 1.0 / (1.0 + exp(-x))
# (goal 1-based idx, relevant-modulator 1-based idxs, meta-drive) — gInd=1 gTrans=2 gHelp=3 gCurio=4 gNovel=5 gSelf=6 gEthic=7 gSoc=8
const _MAGUS_PRIM = [(3, [4], :ind), (4, [2], :trans), (5, [3], :trans), (7, [5, 6], :ind), (8, [1, 3], :dual), (6, [3, 4], :dual)]
const _MAGUS_GROWTH = [4, 5, 6]   # gCurio, gNovel, gSelf
function _magus_score(g, m, c, risk, dg)
    iS = _msig((g[1] - 0.5) * 6); tS = _msig((g[2] - 0.5) * 6)
    caution = (m[5] + m[6]) / 2; growth = (m[2] + m[3]) / 2
    base = 0.0
    for (gi, mi, drv) in _MAGUS_PRIM
        meta = drv === :ind ? 0.5 + 0.5 * iS : drv === :trans ? 0.5 + 0.5 * tS : 0.5 + 0.25 * (iS + tS)
        base += g[gi] * (sum(m[k] for k in mi) / length(mi)) * meta * c[gi]
    end
    ce = c[4] * c[7]
    conflict = ce < -0.2 ? exp(abs(ce) * 3) : 0.0
    explore = sum(c[i] for i in _MAGUS_GROWTH) / 3
    gshift = sum(clamp(dg[i] * 10, 0, 1) for i in _MAGUS_GROWTH) / 3
    base - (0.5 * g[1] * caution * risk + conflict) + 0.5 * g[2] * growth * (0.7 * max(0.0, explore) + 0.3 * gshift)
end

# native-Julia OpenPsi appraisal Ψ (eq #4), bisimulation-validated against lib/metamo openPsiAppraise (1e-6).
# Lets `govern` run FULLY native (no MeTTa eval) — the lib's ~0.7s tree-walk was all that kept Core slower
# than CeTTa (~50ms). Updates the 6 modulators from the 4-channel stimulus; goals unchanged.
function _appraise_native(g, m, st)
    gInd, gTrans = g[1], g[2]
    val, ar, ap, res, thr, sec = m[1], m[2], m[3], m[4], m[5], m[6]
    nov, con, rsk, eff = st[1], st[2], st[3], st[4]
    bnd(v) = _msig(4.0 * (v - 0.5))
    af = _msig((ar - 0.5) * 5); tS = exp(gTrans - 0.5); iS = exp(gInd - 0.5)
    bn = nov * (1 - rsk); dc = (eff + rsk) / 2
    dV = 0.75*con + 0.25*bn - (0.55*rsk + 0.15*eff)
    dA = nov*(1 + 0.5*af) + 0.15*rsk - 0.35*eff
    dAp = 0.65*bn + 0.35*con - 0.75*rsk
    dR = 0.55*con + 0.35*eff + 0.20*rsk
    dT = 0.70*rsk + 0.25*dc - 0.15*con
    dS = 0.80*rsk + 0.20*eff - (0.30*bn + 0.10*con)
    [bnd(val+dV), bnd(ar+dA*tS), bnd(ap+dAp*tS), bnd(res+dR), bnd(thr+dT*iS), bnd(sec+dS*iS)]
end

function govern(goals, mods, stimulus, candidates)
    am = _appraise_native(collect(Float64, goals), collect(Float64, mods), collect(Float64, stimulus))  # Ψ, native
    am === nothing && return nothing
    best = nothing; bestscore = -Inf
    for c in candidates                               # 𝔻 in native Julia — the 8.6s magusDecide → µs
        s = _magus_score(collect(Float64, goals), am, collect(Float64, c.corrs), float(c.risk), collect(Float64, c.dg))
        s > bestscore && (bestscore = s; best = c)
    end
    best === nothing && return nothing
    (chosen = String(best.id), goals = collect(Float64, goals), mods = am)
end

end # module MetaMoCore
