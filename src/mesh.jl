struct RssiReading
    timestamp::Float64
    time_str::String
    rssi::Int
    snr::Float64
end

function load_rssi(data::Dict, node_key::String, utc_offset::Int)::Vector{RssiReading}
    readings = RssiReading[]
    haskey(data, node_key) || return readings
    for entry in data[node_key]
        tstr = entry["time"]
        dt_local = DateTime(tstr[1:min(23, length(tstr))], dateformat"yyyy-mm-ddTHH:MM:SS.sss")
        dt_utc = dt_local - Hour(utc_offset)
        push!(readings, RssiReading(datetime2unix(dt_utc), tstr, Int(entry["rssi"]), Float64(entry["snr"])))
    end
    sort!(readings, by=r -> r.timestamp)
end

function load_reverse_timestamps(files_and_keys::Vector{Tuple{String,String}}, utc_offset::Int)::Vector{Float64}
    timestamps = Float64[]
    for (file, key) in files_and_keys
        isfile(file) || continue
        raw = open(f -> JSON3.read(f, Dict{String,Any}), file)
        for r in load_rssi(raw, key, utc_offset)
            push!(timestamps, r.timestamp)
        end
    end
    sort!(timestamps)
end

function has_reverse(reverse_ts::Vector{Float64}, ts::Float64; window::Float64=30.0)::Bool
    isempty(reverse_ts) && return false
    idx = searchsortedfirst(reverse_ts, ts)
    (idx > 0 && idx <= length(reverse_ts) && abs(reverse_ts[idx] - ts) <= window) && return true
    (idx > 1 && abs(reverse_ts[idx-1] - ts) <= window) && return true
    false
end
