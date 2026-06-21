# Manifest.jl — single source of truth for the world-model substrate paths.
#
# Config-driven, ENV-overridable, never /tmp and never a path baked into a script (the no-tech-debt rule;
# mirrors MORK/examples/connectome/manifest.jl). Every Space persists to one `.act` under `store`.

module Manifest

export WMManifest, manifest, act_path, ensure_store, describe

const DEFAULT_STORE = expanduser("~/code/CognitiveSubstratesAI/data/worldmodel")

"Resolved substrate locations. `store` holds one `<Space>.act` per persisted Space."
struct WMManifest
    store::String
end

"Resolve the manifest (`WORLDMODEL_STORE` overrides the default store)."
manifest(; store=get(ENV, "WORLDMODEL_STORE", DEFAULT_STORE)) = WMManifest(String(store))

"Filesystem path of Space `name`'s persisted `.act` snapshot."
act_path(m::WMManifest, name::Symbol) = joinpath(m.store, string(name) * ".act")

"Create the store directory if missing; return the manifest."
ensure_store(m::WMManifest) = (isdir(m.store) || mkpath(m.store); m)

"Print the resolved store + which Space snapshots are already built on disk."
function describe(m::WMManifest)
    println("=== world-model manifest ===")
    println("  store  ", m.store, isdir(m.store) ? "  [ok]" : "  [will create]")
    if isdir(m.store)
        for f in sort(filter(endswith(".act"), readdir(m.store)))
            println("    ", rpad(f, 18), "[built]")
        end
    end
    m
end

end # module Manifest
