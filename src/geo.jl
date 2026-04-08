struct GpsPoint
    timestamp::Float64
    lat::Float64
    lon::Float64
    ele::Float64
end

function haversine_km(lat1, lon1, lat2, lon2)
    R = 6371.0
    dlat = deg2rad(lat2 - lat1)
    dlon = deg2rad(lon2 - lon1)
    a = sin(dlat/2)^2 + cos(deg2rad(lat1)) * cos(deg2rad(lat2)) * sin(dlon/2)^2
    2R * asin(sqrt(a))
end

function interpolate_position(gps::Vector{GpsPoint}, target_ts::Float64; max_gap::Float64=60.0)
    isempty(gps) && return nothing
    idx = searchsortedfirst(gps, target_ts, by=p -> p isa GpsPoint ? p.timestamp : p)

    if idx == 1
        abs(gps[1].timestamp - target_ts) <= max_gap && return (gps[1].lat, gps[1].lon, gps[1].ele)
        return nothing
    end
    if idx > length(gps)
        abs(gps[end].timestamp - target_ts) <= max_gap && return (gps[end].lat, gps[end].lon, gps[end].ele)
        return nothing
    end

    p0, p1 = gps[idx-1], gps[idx]
    gap = p1.timestamp - p0.timestamp
    if gap > max_gap * 2
        abs(p0.timestamp - target_ts) <= max_gap && return (p0.lat, p0.lon, p0.ele)
        abs(p1.timestamp - target_ts) <= max_gap && return (p1.lat, p1.lon, p1.ele)
        return nothing
    end

    frac = gap > 0 ? (target_ts - p0.timestamp) / gap : 0.0
    (p0.lat + frac * (p1.lat - p0.lat),
     p0.lon + frac * (p1.lon - p0.lon),
     p0.ele + frac * (p1.ele - p0.ele))
end

function rssi_to_color(rssi::Int)::String
    clamped = clamp(rssi, -120, -50)
    ratio = (clamped + 120) / 70
    if ratio > 0.5
        r = round(Int, 255 * (1 - (ratio - 0.5) * 2)); g = 200
    else
        r = 255; g = round(Int, 200 * ratio * 2)
    end
    "#" * string(r, base=16, pad=2) * string(g, base=16, pad=2) * "00"
end
