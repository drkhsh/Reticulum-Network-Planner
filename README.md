# Reticulum Radio Map


When planning a mesh radio network you need to know where to put your nodes. This tool has two modes:

**Radio mapping** - Drive around with a radio and a GPS tracker, then feed the data in. The tool correlates your signal readings with GPS positions and generates an interactive map showing where your signal is strong, weak, one-way, or absent. Useful for understanding real-world coverage from an existing base station.

**Node placement** - Given a geographic area and your constraints (mesh link range, number of nodes, existing base stations), the tool uses SRTM terrain elevation data to compute line-of-sight across the region and find optimal positions for new nodes. Each node placement is verified to have a line-of-sight mesh route back to your base. Placements can be optimized for either total land area covered or total population reached, using WorldPop 1 km population rasters that are auto-downloaded on first run.

You can use either mode independently or both together.

## Setup

Requires Julia 1.10+.

```
julia -e 'using Pkg; Pkg.add(["EzXML", "JSON3"])'
```

## Collecting Data

Each team needs:
- An RNode radio connected via USB running `collector/main.py`
- A phone recording a GPX track (Open GPX Tracker, OsmAnd, etc.)

See `collector/readme.txt` for hardware setup. The collector script saves a `mesh_data_node_<name>.json` when you exit.

Put your `.gpx` files in `data/gpx/` and `.json` files in `data/mesh/`.

## Running

Edit `config.toml` with your base station coordinates, team files, and settings. Then:

```
julia -t auto run.jl
```

This downloads elevation data, computes line-of-sight, optimizes station placement, and generates `output/radio_map.html`.

You can also run individual steps:

```
julia run.jl --map              # just the map
julia run.jl --los              # just line-of-sight
julia -t auto run.jl --optimize 7   # optimize for 7 stations
```

## Config

Everything is in `config.toml` - base station coords, coverage radius, mesh range, team definitions, etc. The included config has comments explaining each field.
