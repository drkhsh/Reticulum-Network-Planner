function check_los(tile::SRTMTile, blat, blon, bele, tlat, tlon, tele,
                   antenna_h, rx_h; step_m=20.0)
    bh, th = bele + antenna_h, tele + rx_h
    dist_m = haversine_km(blat, blon, tlat, tlon) * 1000
    dist_m < 30 && return true
    ns = max(2, round(Int, dist_m / step_m))
    dl, dn, dh = (tlat-blat)/ns, (tlon-blon)/ns, (th-bh)/ns
    for s in 1:ns-1
        te = get_elevation(tile, blat + dl*s, blon + dn*s)
        isnan(te) && continue
        te > bh + dh*s && return false
    end
    true
end

function check_los_station(tile::SRTMTile, l1, n1, e1, l2, n2, e2,
                           antenna_h; step_m=20.0)
    check_los(tile, l1, n1, e1, l2, n2, e2, antenna_h, antenna_h; step_m)
end

struct GridCell
    lat::Float64
    lon::Float64
    ele::Float64
end

function build_grid(tile::SRTMTile, clat, clon, radius_km, step_m)
    dl = step_m / 111320.0
    dn = step_m / (111320.0 * cos(deg2rad(clat)))
    lr = radius_km / 111.32
    nr = radius_km / (111.32 * cos(deg2rad(clat)))
    cells = GridCell[]
    for lat in clat-lr:dl:clat+lr, lon in clon-nr:dn:clon+nr
        haversine_km(lat, lon, clat, clon) > radius_km && continue
        e = get_elevation(tile, lat, lon)
        isnan(e) && continue
        push!(cells, GridCell(lat, lon, e))
    end
    cells
end

function compute_los_grid(tile::SRTMTile, base_lat, base_lon, cfg::Config)
    base_ele = get_elevation(tile, base_lat, base_lon)
    grid = build_grid(tile, base_lat, base_lon, cfg.coverage_radius_km, cfg.grid_step_m)
    println("  $(length(grid)) grid cells")

    los_data = []
    n_los, n_nlos = 0, 0
    for g in grid
        dist = haversine_km(g.lat, g.lon, base_lat, base_lon)
        is_los = check_los(tile, base_lat, base_lon, base_ele,
                          g.lat, g.lon, g.ele, cfg.antenna_height_m, cfg.rx_height_m)
        push!(los_data, Dict("lat"=>round(g.lat, digits=6), "lon"=>round(g.lon, digits=6),
                             "ele"=>round(g.ele, digits=1), "los"=>is_los,
                             "dist"=>round(dist, digits=3)))
        is_los ? (n_los += 1) : (n_nlos += 1)
    end
    @printf("  LoS: %d, NLoS: %d (%.1f%%)\n", n_los, n_nlos, n_los/(n_los+n_nlos)*100)
    los_data
end
