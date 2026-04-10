using Downloads
using Printf

# WorldPop Global 2020 1km UN-adjusted, per-country GeoTIFF. Add more countries
# as needed — the dataset covers all ISO-3 country codes.
const WORLDPOP_URLS = Dict{String,String}(
    "usa" => "https://data.worldpop.org/GIS/Population/Global_2000_2020_1km_UNadj/2020/USA/usa_ppp_2020_1km_Aggregated_UNadj.tif",
)

struct PopRaster
    origin_lon::Float64
    origin_lat::Float64
    dx::Float64
    dy::Float64
    ncols::Int
    nrows::Int
    nodata::Float32
    # Sparse: only decoded pixels we asked for. Key = (row, col), value = population.
    values::Dict{Tuple{Int,Int},Float32}
end

function ensure_worldpop(path::String, country::String="usa")
    if isfile(path) && filesize(path) > 1_000_000
        return path
    end
    url = get(WORLDPOP_URLS, lowercase(country), nothing)
    url === nothing && error("no WorldPop URL for country \"$country\" — add one to WORLDPOP_URLS in src/population.jl")
    mkpath(dirname(path))
    println("  Downloading WorldPop $(uppercase(country)) 1km raster (~50 MB)...")
    Downloads.download(url, path)
    println("  Saved $path")
    path
end

# --- BigTIFF IFD parsing --------------------------------------------------

struct IFDEntry
    tag::UInt16
    typ::UInt16
    count::UInt64
    value::UInt64   # raw 8-byte value slot (may be inline data or offset)
end

const TIFF_TYPE_SIZES = Dict{UInt16,Int}(
    1=>1, 2=>1, 3=>2, 4=>4, 5=>8, 6=>1, 7=>1, 8=>2, 9=>4, 10=>8,
    11=>4, 12=>8, 16=>8, 17=>8, 18=>8,
)

function parse_bigtiff_ifd(io::IO)
    seekstart(io)
    magic = read(io, 2)
    String(magic) == "II" || error("only little-endian TIFF supported")
    version = read(io, UInt16)
    version == 43 || error("expected BigTIFF (version=43), got $version")
    offsize = read(io, UInt16)
    offsize == 8 || error("unexpected BigTIFF offset size")
    _ = read(io, UInt16)
    ifd_off = read(io, UInt64)

    seek(io, ifd_off)
    n = read(io, UInt64)
    entries = IFDEntry[]
    for _ in 1:n
        tag = read(io, UInt16)
        typ = read(io, UInt16)
        cnt = read(io, UInt64)
        valbytes = read(io, 8)
        val = reinterpret(UInt64, valbytes)[1]
        push!(entries, IFDEntry(tag, typ, cnt, val))
    end
    entries
end

function get_entry(entries::Vector{IFDEntry}, tag::Integer)
    for e in entries
        e.tag == UInt16(tag) && return e
    end
    nothing
end

function read_entry_array(io::IO, e::IFDEntry, ::Type{T}) where T
    tsz = TIFF_TYPE_SIZES[e.typ]
    total = Int(e.count) * tsz
    if total <= 8
        # Inline
        buf = reinterpret(UInt8, [e.value])
        return [reinterpret(T, buf[(i-1)*tsz+1 : i*tsz])[1] for i in 1:e.count]
    else
        seek(io, e.value)
        return [read(io, T) for _ in 1:e.count]
    end
end

# --- LZW decoder (TIFF variant) -------------------------------------------

# TIFF LZW uses MSB-first bit packing, early-change code-width growth.
function lzw_decode(src::Vector{UInt8})
    out = UInt8[]
    CLEAR, EOI = UInt16(256), UInt16(257)
    dict = Vector{Vector{UInt8}}(undef, 4096)
    for i in 0:255
        dict[i+1] = UInt8[UInt8(i)]
    end
    next_code = UInt16(258)
    code_width = 9

    bit_buf = UInt64(0)
    bit_count = 0
    pos = 1
    prev::Vector{UInt8} = UInt8[]

    @inline function read_code()
        while bit_count < code_width
            if pos > length(src)
                return UInt16(EOI)
            end
            bit_buf = (bit_buf << 8) | UInt64(src[pos])
            pos += 1
            bit_count += 8
        end
        code = UInt16((bit_buf >> (bit_count - code_width)) & ((UInt64(1) << code_width) - 1))
        bit_count -= code_width
        code
    end

    while true
        code = read_code()
        code == EOI && break
        if code == CLEAR
            next_code = UInt16(258)
            code_width = 9
            prev = UInt8[]
            continue
        end

        if code < next_code
            s = dict[code + 1]
        elseif code == next_code && !isempty(prev)
            s = vcat(prev, prev[1:1])
        else
            error("invalid LZW code $code (next=$next_code)")
        end

        append!(out, s)

        if !isempty(prev) && next_code < 4096
            dict[next_code + 1] = vcat(prev, s[1:1])
            next_code += 1
        end
        prev = s

        # TIFF "early change": bump width when next_code will hit the max
        if next_code == UInt16((1 << code_width) - 1) && code_width < 12
            code_width += 1
        end
    end
    out
end

# --- Horizontal predictor (TIFF predictor=2) ------------------------------

# For 32-bit samples, horizontal differencing is applied on full 32-bit words
# with carry propagation, not per-byte. For float samples we reinterpret as
# UInt32, cumulatively sum, then reinterpret back.
function undo_predictor2_u32!(bytes::Vector{UInt8}, width::Int, nrows::Int)
    row_words = width
    words = reinterpret(UInt32, bytes)
    for r in 0:nrows-1
        base = r * row_words
        for i in 2:row_words
            words[base + i] = words[base + i] + words[base + i - 1]
        end
    end
end

# --- Strip decoding -------------------------------------------------------

function decode_strip(io::IO, offset::UInt64, size::UInt64, width::Int,
                     rows_in_strip::Int, predictor::Int)
    seek(io, offset)
    compressed = read(io, Int(size))
    raw = lzw_decode(compressed)
    expected = width * rows_in_strip * 4
    length(raw) == expected ||
        @warn "strip decoded to $(length(raw)) bytes, expected $expected"
    if predictor == 2
        undo_predictor2_u32!(raw, width, rows_in_strip)
    end
    reshape(reinterpret(Float32, raw), (width, rows_in_strip))
end

# --- Main loader ----------------------------------------------------------

function load_population_window(path::String, lat_min::Float64, lat_max::Float64,
                                lon_min::Float64, lon_max::Float64)
    io = open(path, "r")
    try
        entries = parse_bigtiff_ifd(io)
        width = Int(get_entry(entries, 256).value)
        height = Int(get_entry(entries, 257).value)
        bits_per_sample = Int(get_entry(entries, 258).value)
        compression = Int(get_entry(entries, 259).value)
        rows_per_strip = Int(get_entry(entries, 278).value)
        predictor_e = get_entry(entries, 317)
        predictor = predictor_e === nothing ? 1 : Int(predictor_e.value)

        bits_per_sample == 32 || error("expected 32-bit samples, got $bits_per_sample")
        compression == 5 || error("expected LZW (5), got compression=$compression")

        strip_offsets = read_entry_array(io, get_entry(entries, 273), UInt64)
        strip_sizes = read_entry_array(io, get_entry(entries, 279), UInt64)

        pixscale = read_entry_array(io, get_entry(entries, 33550), Float64)
        tiepoint = read_entry_array(io, get_entry(entries, 33922), Float64)
        origin_lon = tiepoint[4]
        origin_lat = tiepoint[5]
        dx = pixscale[1]
        dy = pixscale[2]

        nodata_e = get_entry(entries, 42113)
        nodata_val = Float32(-3.4e38)
        if nodata_e !== nothing
            bytes = read_entry_array(io, nodata_e, UInt8)
            s = rstrip(String(bytes), ['\0', ' '])
            try
                nodata_val = parse(Float32, s)
            catch
            end
        end

        # Convert lat/lon window to pixel window (col, row)
        col_min = max(0, floor(Int, (lon_min - origin_lon) / dx) - 1)
        col_max = min(width - 1, ceil(Int, (lon_max - origin_lon) / dx) + 1)
        row_min = max(0, floor(Int, (origin_lat - lat_max) / dy) - 1)
        row_max = min(height - 1, ceil(Int, (origin_lat - lat_min) / dy) + 1)

        # Which strips overlap [row_min, row_max]?
        first_strip = div(row_min, rows_per_strip)
        last_strip = div(row_max, rows_per_strip)

        values = Dict{Tuple{Int,Int},Float32}()
        for s in first_strip:last_strip
            strip_row_start = s * rows_per_strip
            strip_row_end = min(strip_row_start + rows_per_strip - 1, height - 1)
            rows_in_strip = strip_row_end - strip_row_start + 1
            arr = decode_strip(io, strip_offsets[s+1], strip_sizes[s+1],
                              width, rows_in_strip, predictor)
            for r in max(row_min, strip_row_start):min(row_max, strip_row_end)
                for c in col_min:col_max
                    v = arr[c + 1, r - strip_row_start + 1]
                    values[(r, c)] = v
                end
            end
        end

        PopRaster(origin_lon, origin_lat, dx, dy, width, height, nodata_val, values)
    finally
        close(io)
    end
end

function sample_population(raster::PopRaster, lat::Float64, lon::Float64)
    col = round(Int, (lon - raster.origin_lon) / raster.dx)
    row = round(Int, (raster.origin_lat - lat) / raster.dy)
    v = get(raster.values, (row, col), raster.nodata)
    (v == raster.nodata || v < 0) ? 0.0f0 : v
end

# Given a coverage grid, compute per-cell population weights with pro-rating:
# each pop pixel's population is split evenly across the grid cells that fall
# inside it, so summing weights over any set of cells gives the correct total.
function compute_pop_weights(grid, raster::PopRaster)
    ng = length(grid)
    pop_idx = Vector{Tuple{Int,Int}}(undef, ng)
    counts = Dict{Tuple{Int,Int},Int}()
    for (i, g) in enumerate(grid)
        col = round(Int, (g.lon - raster.origin_lon) / raster.dx)
        row = round(Int, (raster.origin_lat - g.lat) / raster.dy)
        key = (row, col)
        pop_idx[i] = key
        counts[key] = get(counts, key, 0) + 1
    end

    weights = Vector{Float64}(undef, ng)
    for i in 1:ng
        key = pop_idx[i]
        pop = Float64(sample_population(raster, grid[i].lat, grid[i].lon))
        weights[i] = pop / counts[key]
    end
    weights
end
