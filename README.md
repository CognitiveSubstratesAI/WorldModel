# WorldModel

The live **PRIMUS** world-modeling application over the
[CognitiveSubstratesAI](https://github.com/CognitiveSubstratesAI) substrate — a running, stateful
**two-loop cognitive system** (Hyperon Whitepaper 2025, §4).

**Standalone by design.** WorldModel has **no hard package dependencies**: it loads on a bare Julia and
connects to substrate capabilities (MeTTa evaluation, MORK spaces, the algorithm libraries) through a
pluggable backend injected at **runtime**. So anyone can clone and use it on its own, against whatever
backend they have — an in-process `MeTTaCore` adapter, a `MorkServer`/`MettaJam` socket client, or a mock:

```julia
using WorldModel

struct MyBackend <: AbstractBackend end
WorldModel.wm_eval(::MyBackend, program) = run_it(program)   # plug in your substrate
WorldModel.wm_query(::MyBackend, pattern) = match_it(pattern)

loop = CognitiveLoop(; backend = MyBackend())
```

## Architecture

A two-loop cognitive cycle over a shared memory substrate (the 13 Spaces of §7):

- **Goal-directed loop** — MetaMo → PLN → MOSES / GEO-EVO → PC (Active Predictive Coding) → SubRep.
- **Ambient background loop** — ECAN → pattern mining (WILLIAM) → concept blending → factor-graph PLN.
- **Shared controls** — geodesic control and quantale-weakness (Occam prior).

The component algorithms are reusable libraries in the substrate; WorldModel *composes* them into the
loop **scenario-driven** (Minecraft affordance discovery, social-robot anti-hallucination) — it does not
absorb or hard-depend on them. See the docs' Architecture Decision for the rationale and built-vs-spec map.

## Status

Scaffold — the pluggable-backend seam is in place and tested; the cognitive loop is wired
scenario-driven. Docs: <https://cognitivesubstratesai.github.io/WorldModel/>.

## License

MIT — see [LICENSE](LICENSE).
