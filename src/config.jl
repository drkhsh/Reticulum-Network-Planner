using TOML

struct SeedStation
    lat::Float64
    lon::Float64
    name::String
end

struct TeamConfig
    name::String
    gpx::String
    mesh_file::String
    mesh_key::String
    color::String
    reverse_file::String
    reverse_key::String
end

struct PeerLinkConfig
    listener::String
    source::String
    mesh_file::String
    mesh_key::String
end

struct ExtraPoint
    team::String
    lat::Float64
    lon::Float64
    ele::Float64
    rssi::Int
    snr::Float64
    label::String
end

struct Config
    name::String
    output_dir::String
    utc_offset::Int
    coverage_radius_km::Float64
    grid_step_m::Float64
    antenna_height_m::Float64
    rx_height_m::Float64
    mesh_radius_km::Float64
    candidate_step_m::Float64
    min_station_spacing_km::Float64
    n_starts::Int
    default_n_stations::Int
    seed_stations::Vector{SeedStation}
    teams::Vector{TeamConfig}
    peer_links::Vector{PeerLinkConfig}
    extra_points::Vector{ExtraPoint}
end

function load_config(path::String)::Config
    raw = TOML.parsefile(path)
    proj = get(raw, "project", Dict())
    tz = get(raw, "timezone", Dict())
    cov = get(raw, "coverage", Dict())
    opt = get(raw, "optimizer", Dict())

    seeds = [SeedStation(s["lat"], s["lon"], get(s, "name", "Base $(i)"))
             for (i, s) in enumerate(get(raw, "seed_stations", []))]

    teams = [TeamConfig(
        t["name"], t["gpx"], t["mesh_file"], t["mesh_key"],
        get(t, "color", "blue"),
        get(t, "reverse_file", ""),
        get(t, "reverse_key", ""))
        for t in get(raw, "teams", [])]

    peers = [PeerLinkConfig(p["listener"], p["source"], p["mesh_file"], p["mesh_key"])
             for p in get(raw, "peer_links", [])]

    extras = [ExtraPoint(e["team"], e["lat"], e["lon"], e["ele"],
                         Int(e["rssi"]), Float64(e["snr"]), get(e, "label", "extrapolated"))
              for e in get(raw, "extra_points", [])]

    Config(
        get(proj, "name", "Radio Map"),
        get(proj, "output_dir", "output"),
        get(tz, "utc_offset", 0),
        get(cov, "radius_km", 7.0),
        get(cov, "grid_step_m", 50.0),
        get(cov, "antenna_height_m", 3.0),
        get(cov, "rx_height_m", 1.5),
        get(opt, "mesh_radius_km", 2.7),
        get(opt, "candidate_step_m", 150.0),
        get(opt, "min_station_spacing_km", 1.0),
        get(opt, "n_starts", 20),
        get(opt, "default_n_stations", 7),
        seeds, teams, peers, extras
    )
end
