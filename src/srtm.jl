using Downloads

struct SRTMTile
    data::Matrix{Int16}
    lat_origin::Int
    lon_origin::Int
    nrows::Int
    ncols::Int
    resolution::Float64
end

function srtm_tile_name(lat::Float64, lon::Float64)::String
    lat_i = floor(Int, lat)
    lon_i = floor(Int, lon)
    ns = lat_i >= 0 ? "N" : "S"
    ew = lon_i >= 0 ? "E" : "W"
    @sprintf("%s%02d%s%03d", ns, abs(lat_i), ew, abs(lon_i))
end

function ensure_srtm(lat::Float64, lon::Float64; cache_dir::String=".srtm_cache")::String
    tile = srtm_tile_name(lat, lon)
    mkpath(cache_dir)
    hgt_path = joinpath(cache_dir, "$tile.hgt")
    isfile(hgt_path) && return hgt_path

    gz_path = hgt_path * ".gz"
    ns_dir = tile[1:3]
    url = "https://s3.amazonaws.com/elevation-tiles-prod/skadi/$ns_dir/$tile.hgt.gz"
    println("Downloading SRTM tile $tile...")
    Downloads.download(url, gz_path)
    run(`gunzip -f $gz_path`)
    println("  Saved to $hgt_path")
    hgt_path
end

function load_srtm(path::String)::SRTMTile
    fs = stat(path).size
    npix = round(Int, sqrt(fs / 2))
    raw = read(path)
    data = Matrix{Int16}(undef, npix, npix)
    for i in 1:npix, j in 1:npix
        idx = ((i-1) * npix + (j-1)) * 2 + 1
        data[i, j] = Int16(raw[idx]) << 8 | Int16(raw[idx+1])
    end
    m = match(r"([NS])(\d+)([EW])(\d+)", basename(path))
    lat = parse(Int, m[2]) * (m[1] == "N" ? 1 : -1)
    lon = parse(Int, m[4]) * (m[3] == "E" ? 1 : -1)
    SRTMTile(data, lat, lon, npix, npix, 1.0 / (npix - 1))
end

function get_elevation(tile::SRTMTile, lat::Float64, lon::Float64)::Float64
    row = (tile.lat_origin + 1.0 - lat) / tile.resolution + 1
    col = (lon - tile.lon_origin) / tile.resolution + 1
    r0, c0 = floor(Int, row), floor(Int, col)
    r1, c1 = r0 + 1, c0 + 1
    (r0 < 1 || r1 > tile.nrows || c0 < 1 || c1 > tile.ncols) && return NaN
    fr, fc = row - r0, col - c0
    e = (Float64(tile.data[r0, c0]), Float64(tile.data[r0, c1]),
         Float64(tile.data[r1, c0]), Float64(tile.data[r1, c1]))
    any(x -> x == -32768.0, e) && return NaN
    (1-fr)*(1-fc)*e[1] + (1-fr)*fc*e[2] + fr*(1-fc)*e[3] + fr*fc*e[4]
end
