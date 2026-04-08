using EzXML

function load_gpx(path::String)::Vector{GpsPoint}
    doc = readxml(path)
    ns = namespace(root(doc))
    points = GpsPoint[]
    for trkpt in findall("//ns:trkpt", root(doc), ["ns" => ns])
        lat = parse(Float64, trkpt["lat"])
        lon = parse(Float64, trkpt["lon"])
        time_el = findfirst("ns:time", trkpt, ["ns" => ns])
        isnothing(time_el) && continue
        tstr = nodecontent(time_el)
        ele_el = findfirst("ns:ele", trkpt, ["ns" => ns])
        ele = isnothing(ele_el) ? 0.0 : parse(Float64, nodecontent(ele_el))
        tstr = replace(tstr, "Z" => "")
        dt = DateTime(tstr[1:min(23, length(tstr))], dateformat"yyyy-mm-ddTHH:MM:SS.sss")
        push!(points, GpsPoint(datetime2unix(dt), lat, lon, ele))
    end
    sort!(points, by=p -> p.timestamp)
end
