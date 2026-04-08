#!/usr/bin/env julia
#= Entry point for the radio map tool.
   Usage: julia [-t auto] run.jl [config.toml] [--map] [--los] [--optimize N] [--all] =#

using JSON3, Dates, Printf

cd(@__DIR__)
for f in ["config", "geo", "gpx", "mesh", "srtm", "los", "correlate", "optimize", "html_map"]
    include("src/$f.jl")
end

function parse_args()
    config_path = "config.toml"
    actions = Symbol[]
    n_optimize = -1

    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if endswith(arg, ".toml")
            config_path = arg
        elseif arg == "--map"
            push!(actions, :map)
        elseif arg == "--los"
            push!(actions, :los)
        elseif arg == "--optimize"
            push!(actions, :optimize)
            if i < length(ARGS) && !startswith(ARGS[i+1], "-")
                i += 1; n_optimize = parse(Int, ARGS[i])
            end
        elseif arg == "--all"
            actions = [:map, :los, :optimize]
        end
        i += 1
    end

    isempty(actions) && (actions = [:map, :los, :optimize])
    (config_path=config_path, actions=actions, n_optimize=n_optimize)
end

function run_map(cfg::Config)
    println("\n=== Generating radio map ===")
    teams = TeamData[]
    for tc in cfg.teams
        isfile(tc.gpx) || (println("  Skipping $(tc.name): $(tc.gpx) not found"); continue)
        isfile(tc.mesh_file) || (println("  Skipping $(tc.name): $(tc.mesh_file) not found"); continue)
        push!(teams, correlate_team(tc, cfg))
    end

    for ep in cfg.extra_points
        idx = findfirst(t -> t.name == ep.team, teams)
        isnothing(idx) && continue
        base = cfg.seed_stations[1]
        dist = haversine_km(ep.lat, ep.lon, base.lat, base.lon)
        push!(teams[idx].points, CorrelatedPoint(
            ep.lat, ep.lon, ep.ele, dist, ep.rssi, ep.snr, ep.label, true))
    end

    peer_links = PeerLink[]
    for plc in cfg.peer_links
        listener_idx = findfirst(t -> t.name == plc.listener, teams)
        source_idx = findfirst(t -> t.name == plc.source, teams)
        (isnothing(listener_idx) || isnothing(source_idx)) && continue
        append!(peer_links, compute_peer_links(plc, teams, cfg))
    end

    networks = Tuple{String,String,String}[]
    outdir = cfg.output_dir
    for f in readdir(outdir)
        m = match(r"optimal_stations_(\d+)\.json", f)
        isnothing(m) && continue
        n = m.captures[1]
        los_f = "$outdir/los_$(n)station.json"
        isfile(los_f) && push!(networks, ("$(n)-station", "$outdir/$f", los_f))
    end
    sort!(networks, by=x -> parse(Int, match(r"(\d+)", x[1]).captures[1]))

    html = generate_html(cfg, teams; peer_links, station_networks=networks)
    mkpath(outdir)
    write("$outdir/radio_map.html", html)
    println("  Saved $(outdir)/radio_map.html")
end

function run_los(cfg::Config, tile::SRTMTile)
    println("\n=== Computing line-of-sight ===")
    base = cfg.seed_stations[1]
    los_data = compute_los_grid(tile, base.lat, base.lon, cfg)
    mkpath(cfg.output_dir)
    write("$(cfg.output_dir)/los_data.json", JSON3.write(los_data))
    println("  Saved $(cfg.output_dir)/los_data.json")
end

function run_optimize(cfg::Config, tile::SRTMTile, n::Int)
    println("\n=== Optimizing station placement ($n stations) ===")
    result = run_optimizer(tile, cfg, n)
    outdir = cfg.output_dir
    mkpath(outdir)
    write("$outdir/optimal_stations_$n.json", JSON3.write(result.stations))
    write("$outdir/los_$(n)station.json", JSON3.write(result.los))
    println("  Coverage: $(result.coverage_pct)%")
    println("  Saved to $outdir/")
end

function main()
    args = parse_args()
    cfg = load_config(args.config_path)
    println("Project: $(cfg.name)")
    println("Base: $(cfg.seed_stations[1].lat), $(cfg.seed_stations[1].lon)")

    tile = nothing
    if :los in args.actions || :optimize in args.actions
        base = cfg.seed_stations[1]
        srtm_path = ensure_srtm(base.lat, base.lon)
        tile = load_srtm(srtm_path)
        println("DEM: $(tile.nrows)x$(tile.ncols)")
    end

    :los in args.actions && run_los(cfg, tile)

    if :optimize in args.actions
        n = args.n_optimize > 0 ? args.n_optimize : cfg.default_n_stations
        run_optimize(cfg, tile, n)
    end

    :map in args.actions && run_map(cfg)
end

main()
