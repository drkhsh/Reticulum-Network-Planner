struct CorrelatedPoint
    lat::Float64
    lon::Float64
    ele::Float64
    dist_km::Float64
    rssi::Int
    snr::Float64
    time::String
    oneway::Bool
end

struct TeamData
    name::String
    track::Vector{GpsPoint}
    points::Vector{CorrelatedPoint}
    track_color::String
end

struct PeerLink
    from_name::String
    to_name::String
    from_lat::Float64
    from_lon::Float64
    to_lat::Float64
    to_lon::Float64
    dist_km::Float64
    rssi::Int
    snr::Float64
    time::String
end

function correlate_team(tc::TeamConfig, cfg::Config)
    base_lat = cfg.seed_stations[1].lat
    base_lon = cfg.seed_stations[1].lon

    gps = load_gpx(tc.gpx)
    raw = open(f -> JSON3.read(f, Dict{String,Any}), tc.mesh_file)
    readings = load_rssi(raw, tc.mesh_key, cfg.utc_offset)

    rev_files = isempty(tc.reverse_file) ? Tuple{String,String}[] : [(tc.reverse_file, tc.reverse_key)]
    reverse_ts = load_reverse_timestamps(rev_files, cfg.utc_offset)

    matched = CorrelatedPoint[]
    for r in readings
        pos = interpolate_position(gps, r.timestamp)
        isnothing(pos) && continue
        lat, lon, ele = pos
        dist = haversine_km(lat, lon, base_lat, base_lon)
        oneway = !has_reverse(reverse_ts, r.timestamp)
        push!(matched, CorrelatedPoint(lat, lon, ele, dist, r.rssi, r.snr, r.time_str, oneway))
    end

    @printf("  %s: %d/%d matched, %d one-way\n", tc.name, length(matched), length(readings),
            count(p -> p.oneway, matched))
    TeamData(tc.name, gps, matched, tc.color)
end

function compute_peer_links(plc::PeerLinkConfig, teams::Vector{TeamData}, cfg::Config)
    raw = open(f -> JSON3.read(f, Dict{String,Any}), plc.mesh_file)
    readings = load_rssi(raw, plc.mesh_key, cfg.utc_offset)

    listener = teams[findfirst(t -> t.name == plc.listener, teams)]
    source = teams[findfirst(t -> t.name == plc.source, teams)]

    links = PeerLink[]
    for r in readings
        lpos = interpolate_position(listener.track, r.timestamp)
        spos = interpolate_position(source.track, r.timestamp)
        (isnothing(lpos) || isnothing(spos)) && continue
        dist = haversine_km(lpos[1], lpos[2], spos[1], spos[2])
        push!(links, PeerLink(plc.listener, plc.source,
                              lpos[1], lpos[2], spos[1], spos[2],
                              dist, r.rssi, r.snr, r.time_str))
    end
    links
end
