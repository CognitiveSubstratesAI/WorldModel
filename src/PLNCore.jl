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
using ..Registry: SpaceRegistry, query_head
using ..Beliefs: beliefs, assert_belief!
using ..Braid: evidence_of
using ..PLN: node_stv

# NOTE: deliberately NOT exporting `STV`/`truth_deduction`/`select_action` — they intentionally mirror
# PLN's names, so exporting would collide with `using .PLN` in WorldModel. Callers use `PLNCore.x`.

"A PLN simple truth value (mirrors PLN.STV): strength `s` ∈ [0,1], confidence `c` ∈ [0,1)."
const STV = NamedTuple{(:s, :c), Tuple{Float64, Float64}}

# Interpreter-side names are NOT exported (MettaLoop.jl qualifies them the same way) — alias explicitly.
const _I = MeTTaCore.Interpreter
const _S = MeTTaCore.Interpreter.StandardMeTTa

# Lazily-built, process-cached Core space holding the canonical lib/pln (stdlib + stv + core logic).
const _SPACE = Ref{Any}(nothing)

function _space()
    if _SPACE[] === nothing
        sp = Space()
        load_core_stdlib!(sp)
        libpln = joinpath(dirname(pathof(MeTTaCore)), "..", "lib", "pln")
        load_metta!(sp, read(joinpath(libpln, "stv.metta"), String))
        load_metta!(sp, read(joinpath(libpln, "pln_core_logic.metta"), String))
        load_metta!(sp, read(joinpath(libpln, "base_rate.metta"), String))   # BaseRateTv on canonical Truth_w2c
        load_metta!(sp, read(joinpath(libpln, "decay.metta"), String))       # R10 decay law + rate
        _register_wm_ops!()
        load_metta!(sp, read(joinpath(@__DIR__, "..", "lib", "base_rate_refresh.metta"), String))
        load_metta!(sp, read(joinpath(@__DIR__, "..", "lib", "ambient_policy.metta"), String))
        _SPACE[] = sp
    end
    _SPACE[]::Space
end

# ── substrate accessors as GROUNDED ATOMS ─────────────────────────────────────────────────────────
# The base-rate refresh is DRIVEN FROM MeTTa (lib/base_rate_refresh.metta). Julia's only job on that
# path is reaching the trie and writing an atom back — no arithmetic, no iteration, no policy. The
# SpaceRegistry stays host-side behind a HANDLE token (the by-handle discipline OmegaClaw's tick loop
# uses); only tokens and numbers cross the ABI.
const _REGS = Dict{String, SpaceRegistry}()
const _REG_CTR = Ref(0)

"Register `reg` behind a short handle token the MeTTa driver can pass around."
wm_handle!(reg::SpaceRegistry) = (h = "wm$(_REG_CTR[] += 1)"; _REGS[h] = reg; h)
wm_release!(h::AbstractString) = (delete!(_REGS, h); nothing)

_astr(a) = (a isa _S.Grounded && a.value isa AbstractString) ? String(a.value) : string(a)
_anum(a) = (a isa _S.Grounded && a.value isa Real) ? Float64(a.value) : something(tryparse(Float64, string(a)), 0.0)
_gnum(x::Real) = _I.ExecOk(_S.Atom[_S.Grounded(Float64(x))])
_gunit() = _I.ExecOk(_S.Atom[_S.Expression(_S.Atom[])])

# `(HEAD KEY CLASS)` → CLASS, else nothing. The one shape `ground!`/mid_step! write.
function _class_of(a::AbstractString, head::AbstractString)
    toks = split(strip(a)[2:(end - 1)])
    (length(toks) == 3 && toks[1] == head) ? String(toks[3]) : nothing
end

# NO once-only guard. Registration is writing fixed keys into a Dict — idempotent by construction — and
# a `_WM_OPS_REGISTERED[] && return` guard bought nothing while actively breaking things: once the flag
# was set, resetting `_SPACE[]` to pick up edited rules re-loaded the .metta but SKIPPED registering any
# newly-added op, so the new rules referenced tokens that did not exist. Those calls then reduced to
# themselves, and `(superpose $rows)` over an unreduced `(wm-belief-rows h S)` superposed its three
# TOKENS instead of the rows — the same shape as the bug documented in base_rate_refresh.metta:35-37,
# arriving by a different route. A cache whose invalidation is partial is worse than no cache.
function _register_wm_ops!()
    R = _I.TOKEN_REGISTRY

    R["wm-universe"] = _S.Grounded(_I.Operation("wm-universe", function (xs::Vector{_S.Atom})
        length(xs) == 3 || return _I.ExecNoReduce()
        reg = get(_REGS, _astr(xs[1]), nothing); reg === nothing && return _gnum(0)
        head = _astr(xs[3])
        _gnum(count(a -> _class_of(a, head) !== nothing, query_head(reg, Symbol(_astr(xs[2])), head)))
    end))

    R["wm-class-count"] = _S.Grounded(_I.Operation("wm-class-count", function (xs::Vector{_S.Atom})
        length(xs) == 4 || return _I.ExecNoReduce()
        reg = get(_REGS, _astr(xs[1]), nothing); reg === nothing && return _gnum(0)
        head = _astr(xs[3]); cls = _astr(xs[4])
        _gnum(count(a -> _class_of(a, head) == cls, query_head(reg, Symbol(_astr(xs[2])), head)))
    end))

    R["wm-classes"] = _S.Grounded(_I.Operation("wm-classes", function (xs::Vector{_S.Atom})
        length(xs) == 4 || return _I.ExecNoReduce()
        reg = get(_REGS, _astr(xs[1]), nothing); reg === nothing && return _I.ExecOk(_S.Atom[_S.Expression(_S.Atom[])])
        head = _astr(xs[3]); lim = max(round(Int, _anum(xs[4])), 0)
        cls = sort!(unique(String[c for c in (_class_of(a, head)
                                              for a in query_head(reg, Symbol(_astr(xs[2])), head))
                                  if c !== nothing]))                   # sorted ⇒ deterministic
        _I.ExecOk(_S.Atom[_S.Expression(_S.Atom[_S.Sym(c) for c in Iterators.take(cls, lim)])])
    end))

    R["wm-put-belief!"] = _S.Grounded(_I.Operation("wm-put-belief!", function (xs::Vector{_S.Atom})
        length(xs) == 6 || return _I.ExecNoReduce()
        reg = get(_REGS, _astr(xs[1]), nothing); reg === nothing && return _gunit()
        assert_belief!(reg, _astr(xs[3]), _anum(xs[4]), _anum(xs[5]), _anum(xs[6]);
                       into=Symbol(_astr(xs[2])))
        _gunit()
    end))

    # ── R10 ambient re-validation accessors ───────────────────────────────────────────────────────
    # `(row key c0 t0)` per CURRENT belief — resolved by `beliefs`, so latest-wins is applied ONCE, in
    # the one place that knows the resolution rule. The decay law, the staleness threshold and the
    # priority are all applied on the MeTTa side (WorldModel/lib/ambient_policy.metta); this hands over
    # rows and nothing else.
    R["wm-belief-rows"] = _S.Grounded(_I.Operation("wm-belief-rows", function (xs::Vector{_S.Atom})
        length(xs) == 2 || return _I.ExecNoReduce()
        reg = get(_REGS, _astr(xs[1]), nothing)
        reg === nothing && return _I.ExecOk(_S.Atom[_S.Expression(_S.Atom[])])
        rows = _S.Atom[_S.Expression(_S.Atom[_S.Sym("row"), _S.Sym(k),
                                             _S.Grounded(c), _S.Grounded(t0)])
                       for (k, _s, c, t0) in beliefs(reg; into=Symbol(_astr(xs[2])))]
        _I.ExecOk(_S.Atom[_S.Expression(rows)])
    end))

    # How much evidence still anchors `key` — the count `EvidenceConfidence` consumes.
    R["wm-evidence-count"] = _S.Grounded(_I.Operation("wm-evidence-count", function (xs::Vector{_S.Atom})
        length(xs) == 3 || return _I.ExecNoReduce()
        reg = get(_REGS, _astr(xs[1]), nothing); reg === nothing && return _gnum(0)
        _gnum(length(evidence_of(reg, _astr(xs[3]); into=Symbol(_astr(xs[2])))))
    end))

    # Current strength of `key`, or the symbol `no-belief`. NOT 0.0 — absence is not a truth value, and
    # a fabricated zero is what silently poisoned PLN's `as > 0` precondition before.
    R["wm-belief-strength"] = _S.Grounded(_I.Operation("wm-belief-strength", function (xs::Vector{_S.Atom})
        length(xs) == 3 || return _I.ExecNoReduce()
        reg = get(_REGS, _astr(xs[1]), nothing)
        reg === nothing && return _I.ExecOk(_S.Atom[_S.Sym("no-belief")])
        key = _astr(xs[3])
        for (k, s, _c, _t) in beliefs(reg; into=Symbol(_astr(xs[2])))
            k == key && return _gnum(s)
        end
        _I.ExecOk(_S.Atom[_S.Sym("no-belief")])
    end))

    return nothing
end

"""
    refresh_base_rates!(reg, t; into=:Sent, head="entity") -> Vector{String}

Recompute every class's extensional base rate in the `(head _ class)` universe of space `into` and store
it as that node's belief — **driven from MeTTa** (`WorldModel/lib/base_rate_refresh.metta`). This Julia
function is marshalling only: take a handle, run the rule, hand back which classes were refreshed.

The arithmetic (`|ext|/|universe|`, `Truth_w2c`) is in `Core/lib/pln/base_rate.metta`; the iteration and
the skip-on-absence decision are in the refresh rule. Nothing here re-derives a truth-value formula.
"""
function refresh_base_rates!(reg::SpaceRegistry, t::Real;
    into::Symbol=:Sent, head::AbstractString="entity",
    into_rule::Symbol=:Srule, limit::Int=64)
    h = wm_handle!(reg)
    try
        metta_run(parse_program(
            "(refresh-base-rates! \"$h\" $into $head $into_rule $(float(t)) $limit)")[1][2], _space())
        # report what now has an extension — the rule wrote exactly these (absence is skipped)
        cls = String[]
        for a in query_head(reg, into, head)
            c = _class_of(a, head); c === nothing || push!(cls, c)
        end
        return sort!(unique(cls))
    finally
        wm_release!(h)
    end
end

# ── R10: staleness + re-validation, DRIVEN FROM MeTTa (WorldModel/lib/ambient_policy.metta) ───────
#
# These three used to live in `Beliefs.jl` as Julia: the decay law `c0*exp(-lambda*(t-t0))`, a
# `threshold=0.5` staleness cut, and `c_new = n/(n+1)` under a comment naming the canonical `Truth_w2c`
# it was transcribing. They are here now for a structural reason, not a stylistic one: `Beliefs.jl` is
# `include`d BEFORE this module and `PLNCore` already does `using ..Beliefs`, so a call from Beliefs into
# the interpreter would close a dependency cycle. Being unable to reach the canonical formula is exactly
# what made someone write it out again — so the code moved to where the library is reachable.

"Evaluate a nullary MeTTa policy atom (e.g. `(revalidate-budget)`) to a number."
function _policy_num(name::AbstractString)
    res = metta_run(parse_program("($name)")[1][2], _space())
    isempty(res) && error("PLNCore: ambient policy atom `($name)` did not reduce to a value — " *
                          "check WorldModel/lib/ambient_policy.metta")
    v = tryparse(Float64, strip(string(res[1])))
    v === nothing && error("PLNCore: ambient policy atom `($name)` reduced to `$(res[1])`, not a number")
    return v
end

"The ambient loop's re-validation budget — the MeTTa atom `(revalidate-budget)`."
revalidate_budget() = round(Int, _policy_num("revalidate-budget"))
"The ambient loop's per-universe base-rate budget — the MeTTa atom `(base-rate-limit)`."
base_rate_limit() = round(Int, _policy_num("base-rate-limit"))
"The staleness cut — the MeTTa atom `(stale-threshold)`."
stale_threshold() = _policy_num("stale-threshold")

"""
    decayed_confidence(c0, t0, t; lambda=nothing) -> Float64

Effective confidence at time `t` under staleness decay (§6.1.3, R10) — evaluated through the CANONICAL
`DecayedConfidence` in `Core/lib/pln/decay.metta`, with `lambda` defaulting to that library's own
`(BeliefDecayRate)`. Both the curve and the rate are atoms: an evolutionary search over the agent's
cognition can replace exponential decay with something else without a Julia edit.
"""
function decayed_confidence(c0::Real, t0::Real, t::Real; lambda::Union{Real,Nothing}=nothing)
    λ = lambda === nothing ? "(BeliefDecayRate)" : string(float(lambda))
    res = metta_run(parse_program(
        "(DecayedConfidence $(float(c0)) $(float(t0)) $(float(t)) $λ)")[1][2], _space())
    isempty(res) && error("PLNCore: DecayedConfidence did not reduce — check Core/lib/pln/decay.metta")
    return parse(Float64, strip(string(res[1])))
end

"""
    stale_candidates(reg, t; into=:Srule) -> Vector{Tuple{String,Float64}}

The beliefs that have decayed below the staleness threshold at time `t`, MOST URGENT FIRST, as
`(key, priority)`.

MeTTa decides both policy questions — what counts as stale (`belief-stale?`, over `Core/lib/pln`'s
`DecayedConfidence`/`BeliefDecayRate`) and how urgent each one is (`staleness-priority`). Julia does the
substrate read and the mechanical sort.

DETECTION, not spending: keys whose evidence has all disappeared are still reported, because "this
belief has decayed and nothing can rescue it" is a fact a caller wants. The anchoring test belongs to
`ambient_revalidate!`, which is where the budget is.
"""
function stale_candidates(reg::SpaceRegistry, t::Real; into::Symbol=:Srule)
    h = wm_handle!(reg)
    try
        res = metta_run(parse_program(
            "(stale-candidates \"$h\" $into $(float(t)))")[1][2], _space())
        out = Tuple{String, Float64}[]
        for m in eachmatch(r"\(cand\s+(\S+?)\s+([-\d.eE]+)\)", isempty(res) ? "" : string(res[1]))
            push!(out, (String(m.captures[1]), parse(Float64, m.captures[2])))
        end
        # most-decayed first; key as a deterministic tie-break so equal-priority ties don't wobble
        sort!(out; by = x -> (-x[2], x[1]))
        return out
    finally
        wm_release!(h)
    end
end

"""
    stale_beliefs(reg, t; into=:Srule) -> Vector{String}

The keys of beliefs whose decayed confidence at `t` has fallen below the staleness threshold — the
re-validation candidates a dynamic world must re-check (R10), MOST URGENT FIRST. See `stale_candidates`.
"""
stale_beliefs(reg::SpaceRegistry, t::Real; into::Symbol=:Srule) =
    first.(stale_candidates(reg, t; into=into))

"""
    revalidate_belief!(reg, key, t; into=:Srule, evidence_into=:Sent) -> Union{NamedTuple,Nothing}

R10 RE-VALIDATION, driven from MeTTa (`revalidate-one!`): refresh a belief's CONFIDENCE from the evidence
that currently anchors the symbol and reset its decay clock to `t`. Returns the refreshed
`(key, s, c, t)`, or `nothing` when there is no such belief or no surviving evidence.

**Strength is PRESERVED** and the confidence comes from the canonical `EvidenceConfidence` (= `Truth_w2c`,
k = 1) — so a revalidated confidence lands on the same evidence scale as every other truth value in the
system. **No evidence ⇒ `nothing`**: the belief keeps decaying rather than being propped up, which is the
honest outcome for a symbol nothing supports any more and is what keeps decay meaningful.
"""
function revalidate_belief!(reg::SpaceRegistry, key::AbstractString, t::Real;
    into::Symbol=:Srule, evidence_into::Symbol=:Sent)
    h = wm_handle!(reg)
    try
        res = metta_run(parse_program(
            "(revalidate-one! \"$h\" $into $evidence_into $(float(t)) $key)")[1][2], _space())
        isempty(res) && return nothing
        m = match(r"\(revalidated\s+(\S+?)\s+([-\d.eE]+)\)", string(res[1]))
        m === nothing && return nothing                     # `unsupported` / `absent` ⇒ left to decay
        c = parse(Float64, m.captures[2])
        s = nothing
        for (k, sv, _c, _t) in beliefs(reg; into=into); k == key && (s = sv; break); end
        s === nothing && return nothing
        return (key=String(key), s=s, c=c, t=float(t))
    finally
        wm_release!(h)
    end
end

"""
    ambient_revalidate!(reg, t; into=:Srule, evidence_into=:Sent, budget=revalidate_budget())
        -> (; stale, revalidated, examined)

One ambient R10 pass: take the most-urgent candidates and refresh them, up to `budget`.

The budget counts SUCCESSFUL refreshes, not candidates examined — a key that declines (its evidence is
gone) must not consume a slot, or it holds that slot on every future pass too. That is the starvation
bug this replaces: the previous loop did `Iterators.take(stale, 16)` over a KEY-SORTED list, so 16
unrescuable keys sorting early meant no later belief was ever re-validated again, permanently.
`examined` reports how many candidates were walked, so a truncated pass is visible rather than silently
looking complete.
"""
function ambient_revalidate!(reg::SpaceRegistry, t::Real; into::Symbol=:Srule,
    evidence_into::Symbol=:Sent, budget::Int=revalidate_budget())
    cands = stale_candidates(reg, t; into=into)
    revalidated = String[]
    examined = 0
    for (key, _p) in cands
        length(revalidated) >= max(budget, 0) && break
        examined += 1
        revalidate_belief!(reg, key, t; into=into, evidence_into=evidence_into) === nothing ||
            push!(revalidated, key)
    end
    return (; stale=first.(cands), revalidated=revalidated, examined=examined)
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
