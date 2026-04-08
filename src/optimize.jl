using Base.Threads

function precompute_coverage(tile::SRTMTile, cands::Vector{GridCell},
                             grid::Vector{GridCell}, cfg::Config)
    nc, ng = length(cands), length(grid)
    cov = Vector{BitVector}(undef, nc)
    println("  Precomputing coverage LoS: $nc x $ng ($(nthreads()) threads)")
    p = Atomic{Int}(0)
    @threads for ci in 1:nc
        c = cands[ci]
        bv = falses(ng)
        for gi in 1:ng
            g = grid[gi]
            haversine_km(c.lat, c.lon, g.lat, g.lon) > cfg.coverage_radius_km && continue
            check_los(tile, c.lat, c.lon, c.ele, g.lat, g.lon, g.ele,
                     cfg.antenna_height_m, cfg.rx_height_m) && (bv[gi] = true)
        end
        cov[ci] = bv
        d = atomic_add!(p, 1)
        (d+1) % 200 == 0 && @printf("    %d/%d (%.0f%%)\r", d+1, nc, (d+1)/nc*100)
    end
    println("    $nc/$nc (100%)           ")
    cov
end

function precompute_station_los(tile::SRTMTile, cands::Vector{GridCell},
                                seeds::Vector{GridCell}, cfg::Config)
    ns, nc = length(seeds), length(cands)
    all_pts = vcat(seeds, cands)
    can_see = Vector{Vector{Int}}(undef, nc)
    println("  Precomputing inter-station LoS ($(nthreads()) threads)")
    p = Atomic{Int}(0)
    @threads for ci in 1:nc
        c = cands[ci]
        visible = Int[]
        for (ai, a) in enumerate(all_pts)
            ai == ns + ci && continue
            d = haversine_km(c.lat, c.lon, a.lat, a.lon)
            d > cfg.mesh_radius_km && continue
            check_los_station(tile, c.lat, c.lon, c.ele, a.lat, a.lon, a.ele,
                            cfg.antenna_height_m) && push!(visible, ai)
        end
        can_see[ci] = visible
        d = atomic_add!(p, 1)
        (d+1) % 200 == 0 && @printf("    %d/%d (%.0f%%)\r", d+1, nc, (d+1)/nc*100)
    end
    println("    $nc/$nc (100%)           ")
    can_see, ns
end

function is_connected(station_indices, can_see, n_seeds)
    placed = Set{Int}(1:n_seeds)
    for ci in station_indices; push!(placed, n_seeds + ci); end
    visited = Set{Int}(1:n_seeds)
    queue = collect(1:n_seeds)
    while !isempty(queue)
        node = popfirst!(queue)
        if node > n_seeds
            for nb in can_see[node - n_seeds]
                nb in placed && !(nb in visited) && (push!(visited, nb); push!(queue, nb))
            end
        else
            for ci in station_indices
                ai = n_seeds + ci
                ai in placed && !(ai in visited) && node in can_see[ci] &&
                    (push!(visited, ai); push!(queue, ai))
            end
        end
    end
    length(visited) == length(placed)
end

function greedy_solve(cov, can_see, n_seeds, seeds_bv, cands, n_stations, cfg)
    ng = length(cov[1])
    covered = reduce(.|, seeds_bv; init=falses(ng))
    placed_gc = GridCell[]
    placed_ci = Int[]

    for s in 1:n_stations
        all_ai = Set{Int}(1:n_seeds)
        for ci in placed_ci; push!(all_ai, n_seeds + ci); end
        best_ci, best_new = -1, 0

        for ci in 1:length(cands)
            c = cands[ci]
            too_close = any(p -> haversine_km(c.lat, c.lon, p.lat, p.lon) < cfg.min_station_spacing_km, placed_gc)
            too_close && continue
            any(nb -> nb in all_ai, can_see[ci]) || continue
            nc = count(cov[ci] .& .!covered)
            nc > best_new && (best_new = nc; best_ci = ci)
        end
        best_ci == -1 && break
        covered .|= cov[best_ci]
        push!(placed_gc, cands[best_ci]); push!(placed_ci, best_ci)
    end
    placed_ci, count(covered)
end

function swap_refine(placed_ci, cov, can_see, n_seeds, seeds_bv, cands, cfg;
                     seed_positions=GridCell[])
    ng = length(cov[1])
    best_ci = copy(placed_ci)
    eval_cov(idxs) = count(reduce(.|, [cov[ci] for ci in idxs]; init=reduce(.|, seeds_bv; init=falses(ng))))
    best_score = eval_cov(best_ci)
    improved = true

    while improved
        improved = false
        for slot in 1:length(best_ci)
            trial = copy(best_ci)
            for ci in 1:length(cands)
                ci in best_ci && continue
                c = cands[ci]
                others = [cands[best_ci[si]] for si in 1:length(best_ci) if si != slot]
                too_close = any(p -> haversine_km(c.lat, c.lon, p.lat, p.lon) < cfg.min_station_spacing_km,
                               vcat(others, seed_positions))
                too_close && continue
                trial[slot] = ci
                score = eval_cov(trial)
                if score > best_score && is_connected(trial, can_see, n_seeds)
                    best_score = score; best_ci = copy(trial); improved = true; break
                end
            end
        end
    end
    best_ci, best_score
end

function run_optimizer(tile::SRTMTile, cfg::Config, n_stations::Int)
    base = cfg.seed_stations[1]
    grid = build_grid(tile, base.lat, base.lon, cfg.coverage_radius_km, cfg.grid_step_m)
    println("  Grid: $(length(grid)) cells")
    cands = build_grid(tile, base.lat, base.lon,
                       cfg.coverage_radius_km + cfg.mesh_radius_km, cfg.candidate_step_m)
    println("  Candidates: $(length(cands))")

    cov = precompute_coverage(tile, cands, grid, cfg)

    seeds_gc = [GridCell(s.lat, s.lon, get_elevation(tile, s.lat, s.lon)) for s in cfg.seed_stations]
    can_see, n_seeds = precompute_station_los(tile, cands, seeds_gc, cfg)

    seeds_bv = BitVector[]
    for sc in seeds_gc
        bv = falses(length(grid))
        for (gi, g) in enumerate(grid)
            haversine_km(sc.lat, sc.lon, g.lat, g.lon) > cfg.coverage_radius_km && continue
            check_los(tile, sc.lat, sc.lon, sc.ele, g.lat, g.lon, g.ele,
                     cfg.antenna_height_m, cfg.rx_height_m) && (bv[gi] = true)
        end
        push!(seeds_bv, bv)
    end

    seed_covered = reduce(.|, seeds_bv; init=falses(length(grid)))
    first_scores = Tuple{Int,Int}[]
    all_seed_ai = Set(1:n_seeds)
    for ci in 1:length(cands)
        c = cands[ci]
        any(nb -> nb in all_seed_ai, can_see[ci]) || continue
        any(s -> haversine_km(c.lat, c.lon, s.lat, s.lon) < cfg.min_station_spacing_km, seeds_gc) && continue
        push!(first_scores, (ci, count(cov[ci] .& .!seed_covered)))
    end
    sort!(first_scores, by=x -> -x[2])

    n_starts = min(cfg.n_starts, length(first_scores))
    println("  Multi-start: trying $n_starts starting positions")
    best_result, best_coverage = Int[], 0

    for (ti, (first_ci, _)) in enumerate(first_scores[1:n_starts])
        init_covered = copy(seed_covered) .| cov[first_ci]
        init_placed = vcat(seeds_gc, [cands[first_ci]])
        init_ci = [first_ci]

        for _ in 2:n_stations
            all_ai = Set{Int}(1:n_seeds)
            for ci in init_ci; push!(all_ai, n_seeds + ci); end
            best_ci, best_new = -1, 0
            for ci in 1:length(cands)
                ci in init_ci && continue
                c = cands[ci]
                any(p -> haversine_km(c.lat, c.lon, p.lat, p.lon) < cfg.min_station_spacing_km, init_placed) && continue
                any(nb -> nb in all_ai, can_see[ci]) || continue
                nc = count(cov[ci] .& .!init_covered)
                nc > best_new && (best_new = nc; best_ci = ci)
            end
            best_ci == -1 && break
            init_covered .|= cov[best_ci]
            push!(init_placed, cands[best_ci]); push!(init_ci, best_ci)
        end

        total = count(init_covered)
        total > best_coverage && (best_coverage = total; best_result = copy(init_ci))
    end

    refined_ci, refined_score = swap_refine(best_result, cov, can_see, n_seeds, seeds_bv,
                                            cands, cfg; seed_positions=seeds_gc)

    ng = length(grid)
    println("\n  Final: $refined_score/$ng ($(round(refined_score/ng*100, digits=1))%)")
    println("  Connected: $(is_connected(refined_ci, can_see, n_seeds) ? "yes" : "NO")")

    covered = reduce(.|, seeds_bv; init=falses(ng))
    station_data = [Dict("id"=>-si, "lat"=>sc.lat, "lon"=>sc.lon, "ele"=>sc.ele,
                         "new_cells"=>count(seeds_bv[si]), "total_covered"=>0, "seed"=>true)
                    for (si, sc) in enumerate(seeds_gc)]
    for (i, ci) in enumerate(refined_ci)
        c = cands[ci]
        new_cells = count(cov[ci] .& .!covered)
        covered .|= cov[ci]
        push!(station_data, Dict("id"=>i, "lat"=>c.lat, "lon"=>c.lon, "ele"=>c.ele,
                                 "new_cells"=>new_cells, "total_covered"=>count(covered)))
        @printf("    #%d: (%.5f, %.5f) %0.fm +%d → %d (%.1f%%)\n",
                i, c.lat, c.lon, c.ele, new_cells, count(covered), count(covered)/ng*100)
    end

    los_out = [Dict("lat"=>round(g.lat, digits=6), "lon"=>round(g.lon, digits=6),
                    "ele"=>round(g.ele, digits=1), "los"=>covered[i],
                    "dist"=>round(haversine_km(g.lat, g.lon, base.lat, base.lon), digits=3))
               for (i, g) in enumerate(grid)]

    (stations=station_data, los=los_out, coverage_pct=round(refined_score/ng*100, digits=1))
end
