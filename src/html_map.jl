function generate_html(cfg::Config, teams::Vector{TeamData};
                       peer_links::Vector{PeerLink}=PeerLink[],
                       station_networks::Vector{Tuple{String,String,String}}=Tuple{String,String,String}[])
    tracks_json = JSON3.write([
        Dict("name"=>t.name, "color"=>t.track_color,
             "coords"=>[[p.lat, p.lon] for p in t.track[1:max(1, length(t.track)÷2000):end]])
        for t in teams])

    nodes_json = JSON3.write(Dict(
        t.name => [Dict("lat"=>p.lat, "lon"=>p.lon, "rssi"=>p.rssi, "snr"=>p.snr,
                        "time"=>p.time, "ele"=>round(p.ele, digits=1),
                        "dist"=>round(p.dist_km, digits=3), "oneway"=>p.oneway) for p in t.points]
        for t in teams))

    peers_json = JSON3.write([
        Dict("from"=>p.from_name, "to"=>p.to_name,
             "from_lat"=>p.from_lat, "from_lon"=>p.from_lon,
             "to_lat"=>p.to_lat, "to_lon"=>p.to_lon,
             "dist"=>round(p.dist_km, digits=3),
             "rssi"=>p.rssi, "snr"=>p.snr, "time"=>p.time)
        for p in peer_links])

    outdir = cfg.output_dir
    los_json = isfile("$outdir/los_data.json") ? read("$outdir/los_data.json", String) : "[]"

    # Load station networks dynamically from output files
    networks_js = ""
    for (label, stations_file, los_file) in station_networks
        sj = isfile(stations_file) ? read(stations_file, String) : "[]"
        lj = isfile(los_file) ? read(los_file, String) : "[]"
        networks_js *= "addStationNetwork(($sj).filter(s=>!s.seed),\n$lj,\n'$label');\n"
    end

    base_markers_js = ""
    for s in cfg.seed_stations
        base_markers_js *= """
L.marker([$(s.lat), $(s.lon)], {
  icon: L.divIcon({className:'',
    html:'<div style="background:#222;color:#0f0;font-size:18px;width:30px;height:30px;border-radius:50%;border:2px solid #0f0;display:flex;align-items:center;justify-content:center;box-shadow:0 0 8px rgba(0,255,0,0.5);">&#9650;</div>',
    iconSize:[30,30], iconAnchor:[15,15]})
}).bindPopup('<b>$(s.name)</b><br>$(s.lat), $(s.lon)').addTo(map);
"""
    end

    base = cfg.seed_stations[1]
    team_colors_js = join(["'$(t.name)':'$(t.color)'" for t in cfg.teams], ",")

    all_track_pts = vcat([t.track for t in teams]...)
    center_lat = isempty(all_track_pts) ? base.lat : sum(p.lat for p in all_track_pts) / length(all_track_pts)
    center_lon = isempty(all_track_pts) ? base.lon : sum(p.lon for p in all_track_pts) / length(all_track_pts)

    """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>$(cfg.name)</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script src="https://unpkg.com/leaflet.heat@0.2.0/dist/leaflet-heat.js"></script>
<style>
  body { margin: 0; padding: 0; }
  #map { width: 100%; height: 100vh; transition: height 0.3s; }
  #map.with-chart { height: 60vh; }
  #chart-panel { display:none; height:40vh; background:#fff; border-top:2px solid #666; padding:10px; box-sizing:border-box; overflow:auto; }
  #chart-panel.visible { display:flex; gap:10px; }
  #chart-panel canvas { flex:1; min-width:0; }
  .chart-btn { position:fixed; bottom:10px; right:10px; z-index:1000; background:white; border:2px solid #666; border-radius:8px; padding:8px 14px; cursor:pointer; font-family:monospace; font-size:13px; box-shadow:0 2px 8px rgba(0,0,0,0.3); }
  .legend { position:fixed; bottom:30px; left:10px; z-index:1000; background:white; padding:12px 14px; border-radius:8px; border:2px solid #666; font-family:monospace; font-size:13px; line-height:1.6; box-shadow:0 2px 8px rgba(0,0,0,0.3); }
  .stats { position:fixed; top:10px; right:10px; z-index:1000; background:white; padding:10px 14px; border-radius:8px; border:2px solid #666; font-family:monospace; font-size:12px; box-shadow:0 2px 8px rgba(0,0,0,0.3); max-width:280px; }
  .layer-toggle { position:fixed; top:10px; left:10px; z-index:1000; background:white; padding:10px; border-radius:8px; border:2px solid #666; font-family:sans-serif; font-size:13px; box-shadow:0 2px 8px rgba(0,0,0,0.3); }
  .layer-toggle label { display:block; margin:3px 0; cursor:pointer; }
</style>
</head>
<body>
<div id="map"></div>
<div class="legend">
  <b>RSSI Signal Strength</b><br>
  <span style="color:#00c800">&#9632;</span> &gt; -70 dBm (Excellent)<br>
  <span style="color:#64c800">&#9632;</span> -70 to -85 dBm (Good)<br>
  <span style="color:#ffc800">&#9632;</span> -85 to -100 dBm (Fair)<br>
  <span style="color:#ff6400">&#9632;</span> -100 to -110 dBm (Weak)<br>
  <span style="color:#ff0000">&#9632;</span> &lt; -110 dBm (Very Weak)<br>
  <span style="color:#0f0">&#9650;</span> Base Station<br>
  <span style="color:#888">&#9679;</span> Two-way<br>
  <span style="color:#888">&#9675;</span> One-way<br>
  <span style="color:#ff0">- -</span> Farthest two-way<br>
  <span style="color:#0c0;background:#0c0;opacity:0.5">&#9632;</span> LoS<br>
  <span style="color:#c00;background:#c00;opacity:0.5">&#9632;</span> NLoS<br>
  <span id="track-legend"></span>
</div>
<div class="stats" id="stats"></div>
<div class="layer-toggle" id="layers"></div>
<button class="chart-btn" id="chartBtn" onclick="toggleChart()">Charts</button>
<div id="chart-panel"><canvas id="chart-dist"></canvas><canvas id="chart-ele"></canvas></div>
<script>
const tracksData = $(tracks_json);
const nodesData = $(nodes_json);
const peerLinks = $(peers_json);
const losData = $(los_json);
const baseLat = $(base.lat), baseLon = $(base.lon);
const teamColorMap = {$(team_colors_js)};

const map = L.map('map').setView([$(center_lat), $(center_lon)], 15);
L.tileLayer('https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png', {
  maxZoom:20, attribution:'&copy; OpenStreetMap &copy; CARTO', subdomains:'abcd'
}).addTo(map);

const allBounds = L.latLngBounds();
let trackLegendHtml = '';
tracksData.forEach(t => {
  const layer = L.polyline(t.coords, {color:t.color, weight:2, opacity:0.5}).addTo(map);
  allBounds.extend(layer.getBounds());
  trackLegendHtml += '<span style="color:'+t.color+'">━━</span> '+t.name+' track<br>';
});
document.getElementById('track-legend').innerHTML = trackLegendHtml;

$(base_markers_js)

const distRings = L.layerGroup();
[1,2,3,5,7].forEach(km => {
  L.circle([baseLat, baseLon], {radius:km*1000, color:'#555', weight:1, opacity:0.4, fill:false, dashArray:'6,4'}).addTo(distRings);
  L.marker([baseLat+(km/111.32), baseLon], {
    icon: L.divIcon({className:'', html:'<div style="background:rgba(255,255,255,0.85);padding:1px 4px;border-radius:3px;font:bold 11px monospace;color:#555">'+km+' km</div>', iconSize:[40,16], iconAnchor:[20,8]})
  }).addTo(distRings);
});
distRings.addTo(map);

function rssiColor(rssi) {
  const c=Math.max(-120,Math.min(-50,rssi)), ratio=(c+120)/70;
  let r,g;
  if(ratio>0.5){r=Math.round(255*(1-(ratio-0.5)*2));g=200}else{r=255;g=Math.round(200*ratio*2)}
  return '#'+r.toString(16).padStart(2,'0')+g.toString(16).padStart(2,'0')+'00';
}

const layerDiv = document.getElementById('layers');
function addToggle(label, layer, checked) {
  const el=document.createElement('label'), cb=document.createElement('input');
  cb.type='checkbox'; cb.checked=checked;
  cb.addEventListener('change', function(){if(this.checked)layer.addTo(map);else map.removeLayer(layer)});
  el.appendChild(cb); el.append(' '+label); layerDiv.appendChild(el);
}
addToggle('Distance rings', distRings, true);

if (losData.length > 0) {
  const step = 0.00045;
  function makeLosLayer(fn, color, opacity) {
    return L.GridLayer.extend({createTile:function(coords){
      const tile=document.createElement('canvas'), size=this.getTileSize();
      tile.width=size.x; tile.height=size.y;
      const ctx=tile.getContext('2d'), nwP=coords.scaleBy(size), nw=map.unproject(nwP,coords.z),
            se=map.unproject(nwP.add(size),coords.z);
      ctx.fillStyle=color; ctx.globalAlpha=opacity;
      losData.filter(d=>fn(d)&&d.lat>=se.lat-step&&d.lat<=nw.lat+step&&d.lon>=nw.lng-step&&d.lon<=se.lng+step)
        .forEach(d=>{const p1=map.project(L.latLng(d.lat+step/2,d.lon-step/2),coords.z).subtract(nwP),
          p2=map.project(L.latLng(d.lat-step/2,d.lon+step/2),coords.z).subtract(nwP);
          ctx.fillRect(p1.x,p1.y,p2.x-p1.x,p2.y-p1.y)});
      return tile}});
  }
  addToggle('LoS ('+losData.filter(d=>d.los).length+')', new(makeLosLayer(d=>d.los,'#00cc00',0.2))(), false);
  addToggle('NLoS ('+losData.filter(d=>!d.los).length+')', new(makeLosLayer(d=>!d.los,'#cc0000',0.15))(), false);

  const eles=losData.map(d=>d.ele), eMin=Math.min(...eles), eMax=Math.max(...eles);
  const TopoLayer = L.GridLayer.extend({createTile:function(coords){
    const tile=document.createElement('canvas'), size=this.getTileSize();
    tile.width=size.x; tile.height=size.y;
    const ctx=tile.getContext('2d'), nwP=coords.scaleBy(size), nw=map.unproject(nwP,coords.z),
          se=map.unproject(nwP.add(size),coords.z);
    losData.filter(d=>d.lat>=se.lat-step&&d.lat<=nw.lat+step&&d.lon>=nw.lng-step&&d.lon<=se.lng+step)
      .forEach(d=>{const ratio=(d.ele-eMin)/(eMax-eMin||1);let r,g,b;
        if(ratio<0.5){const t=ratio*2;r=Math.round(140+(50-140)*t);g=Math.round(100+(160-100)*t);b=Math.round(60+(50-60)*t)}
        else{const t=(ratio-0.5)*2;r=Math.round(50+(255-50)*t);g=Math.round(160+(255-160)*t);b=Math.round(50+(255-50)*t)}
        const p1=map.project(L.latLng(d.lat+step/2,d.lon-step/2),coords.z).subtract(nwP),
              p2=map.project(L.latLng(d.lat-step/2,d.lon+step/2),coords.z).subtract(nwP);
        ctx.fillStyle='rgba('+r+','+g+','+b+',0.45)';ctx.fillRect(p1.x,p1.y,p2.x-p1.x,p2.y-p1.y)});
    return tile}});
  addToggle('Topography', new TopoLayer(), false);
}

function addStationNetwork(stations, losGrid, label) {
  if(!stations.length) return;
  const g=L.layerGroup(), colors=['#ff4444','#ff8800','#ffcc00','#44cc44','#4488ff','#8844ff','#ff44aa','#44ffcc','#aa8800','#0088aa'];
  stations.forEach((s,i)=>{
    L.marker([s.lat,s.lon],{icon:L.divIcon({className:'',
      html:'<div style="background:'+colors[i%colors.length]+';color:#fff;font-weight:bold;font-size:13px;width:24px;height:24px;border-radius:50%;border:2px solid #fff;display:flex;align-items:center;justify-content:center;box-shadow:0 0 6px rgba(0,0,0,0.5)">'+(i+1)+'</div>',
      iconSize:[24,24],iconAnchor:[12,12]})
    }).bindPopup('<b>'+label+' #'+(i+1)+'</b><br>'+s.lat.toFixed(6)+', '+s.lon.toFixed(6)+'<br>Elev: '+s.ele.toFixed(0)+' m').addTo(g);
    L.circle([s.lat,s.lon],{radius:2000,color:colors[i%colors.length],weight:1,opacity:0.3,fill:false,dashArray:'4,4'}).addTo(g);
  });
  addToggle(label+' ('+stations.length+')', g, false);
  if(losGrid.length>0){
    const n=losGrid.filter(d=>d.los).length, total=losGrid.length;
    const covLayer=new(L.GridLayer.extend({createTile:function(coords){
      const tile=document.createElement('canvas'),size=this.getTileSize();tile.width=size.x;tile.height=size.y;
      const ctx=tile.getContext('2d'),nwP=coords.scaleBy(size),nw=map.unproject(nwP,coords.z),se=map.unproject(nwP.add(size),coords.z),step=0.00045;
      losGrid.filter(d=>d.lat>=se.lat-step&&d.lat<=nw.lat+step&&d.lon>=nw.lng-step&&d.lon<=se.lng+step).forEach(d=>{
        ctx.fillStyle=d.los?'rgba(0,150,255,0.2)':'rgba(100,0,0,0.08)';
        const p1=map.project(L.latLng(d.lat+step/2,d.lon-step/2),coords.z).subtract(nwP),p2=map.project(L.latLng(d.lat-step/2,d.lon+step/2),coords.z).subtract(nwP);
        ctx.fillRect(p1.x,p1.y,p2.x-p1.x,p2.y-p1.y)});return tile}}))();
    addToggle(label+' LoS ('+(n/total*100).toFixed(1)+'%)', covLayer, false);
  }
}
$(networks_js)

let statsHtml='';
const teamNames=Object.keys(nodesData).sort((a,b)=>nodesData[b].length-nodesData[a].length);
teamNames.forEach(name=>{
  const pts=nodesData[name]; if(!pts.length) return;
  const mg=L.layerGroup(), og=L.layerGroup();
  pts.forEach(pt=>{
    const color=rssiColor(pt.rssi), dir=pt.oneway?'ONE-WAY':'Two-way',
      popup='<b>'+name+'</b><br>RSSI:'+pt.rssi+' dBm<br>SNR:'+pt.snr+' dB<br>Elev:'+pt.ele+' m<br>Dist:'+(pt.dist*1000).toFixed(0)+' m<br>'+dir+'<br>Time:'+pt.time;
    if(pt.oneway) L.circleMarker([pt.lat,pt.lon],{radius:6,color,fillColor:'transparent',fillOpacity:0,weight:2.5,dashArray:'4,3'}).bindPopup(popup).addTo(og);
    else L.circleMarker([pt.lat,pt.lon],{radius:6,color,fillColor:color,fillOpacity:0.85,weight:1}).bindPopup(popup).addTo(mg);
  });
  mg.addTo(map); og.addTo(map);
  const hd=pts.map(pt=>[pt.lat,pt.lon,Math.max(0,pt.rssi+120)/70]);
  const hl=L.heatLayer(hd,{radius:25,blur:20,maxZoom:18,minOpacity:0.3,gradient:{0:'red',0.3:'orange',0.5:'yellow',0.8:'#80ff00',1:'#00c800'}});
  const nT=pts.filter(p=>!p.oneway).length, nO=pts.filter(p=>p.oneway).length;
  if(nT>0) addToggle(name+' two-way ('+nT+')',mg,true);
  if(nO>0) addToggle(name+' one-way ('+nO+')',og,true);
  if(pts.length>3) addToggle(name+' heatmap',hl,false);
  const rs=pts.map(p=>p.rssi),sn=pts.map(p=>p.snr);
  statsHtml+='<b>'+name+'</b> ('+pts.length+' pts)<br>RSSI:'+Math.min(...rs)+'/'+
    (rs.reduce((a,b)=>a+b,0)/rs.length).toFixed(1)+'/'+Math.max(...rs)+' dBm<br>SNR:'+
    Math.min(...sn).toFixed(1)+'/'+(sn.reduce((a,b)=>a+b,0)/sn.length).toFixed(1)+'/'+
    Math.max(...sn).toFixed(1)+' dB<br><small>(min/avg/max)</small><br><br>';
});
document.getElementById('stats').innerHTML=statsHtml;

if(peerLinks.length>0){const g=L.layerGroup();peerLinks.forEach(p=>{const c=rssiColor(p.rssi);
  L.polyline([[p.from_lat,p.from_lon],[p.to_lat,p.to_lon]],{color:c,weight:2,opacity:0.7})
    .bindPopup('<b>'+p.from+' &#8594; '+p.to+'</b><br>RSSI:'+p.rssi+' dBm<br>SNR:'+p.snr+' dB<br>Dist:'+(p.dist*1000).toFixed(0)+' m').addTo(g);
  L.circleMarker([p.from_lat,p.from_lon],{radius:3,color:c,fillColor:c,fillOpacity:0.7,weight:1}).addTo(g)});
  g.addTo(map); addToggle('Peer links ('+peerLinks.length+')',g,true)}

let farthest=null;
teamNames.forEach(n=>{nodesData[n].forEach(pt=>{if(!pt.oneway&&(!farthest||pt.dist>farthest.dist)){farthest=pt;farthest._team=n}})});
if(farthest) L.polyline([[baseLat,baseLon],[farthest.lat,farthest.lon]],{color:'#ff0',weight:3,opacity:0.9,dashArray:'10,6'})
  .bindPopup('<b>Farthest two-way</b><br>'+farthest._team+'<br>'+(farthest.dist*1000).toFixed(0)+' m<br>'+farthest.rssi+' dBm').addTo(map);

map.fitBounds(allBounds.pad(0.1));

function toggleChart(){const p=document.getElementById('chart-panel'),m=document.getElementById('map'),b=document.getElementById('chartBtn');
  const s=!p.classList.contains('visible');p.classList.toggle('visible',s);m.classList.toggle('with-chart',s);
  b.textContent=s?'Hide Charts':'Charts';map.invalidateSize();if(s)drawCharts()}

function drawScatter(id,data,xKey,xLbl,yLbl,title){
  const cv=document.getElementById(id),ctx=cv.getContext('2d'),dpr=window.devicePixelRatio||1,
    rect=cv.getBoundingClientRect();cv.width=rect.width*dpr;cv.height=rect.height*dpr;ctx.scale(dpr,dpr);
  const W=rect.width,H=rect.height,pad={top:30,right:20,bottom:40,left:55},pw=W-pad.left-pad.right,ph=H-pad.top-pad.bottom;
  let pts=[];const tc=teamColorMap;
  data.forEach(d=>{d.pts.forEach(pt=>pts.push({x:pt[xKey],y:pt.rssi,team:d.name}))});
  if(!pts.length)return;
  const xs=pts.map(p=>p.x),ys=pts.map(p=>p.y),xMin=Math.min(...xs),xMax=Math.max(...xs),
    yMin=Math.min(...ys)-2,yMax=Math.max(...ys)+2,xR=xMax-xMin||1,yR=yMax-yMin||1;
  ctx.fillStyle='#fafafa';ctx.fillRect(0,0,W,H);ctx.strokeStyle='#ddd';ctx.lineWidth=0.5;
  for(let i=0;i<=5;i++){const y=pad.top+(i/5)*ph;ctx.beginPath();ctx.moveTo(pad.left,y);ctx.lineTo(pad.left+pw,y);ctx.stroke();
    ctx.fillStyle='#666';ctx.font='11px monospace';ctx.textAlign='right';ctx.fillText((yMax-(i/5)*yR).toFixed(0),pad.left-5,y+4)}
  for(let i=0;i<=5;i++){const x=pad.left+(i/5)*pw;ctx.beginPath();ctx.moveTo(x,pad.top);ctx.lineTo(x,pad.top+ph);ctx.stroke();
    ctx.fillStyle='#666';ctx.textAlign='center';ctx.fillText((xMin+(i/5)*xR).toFixed(xKey==='dist'?2:0),x,H-pad.bottom+15)}
  pts.forEach(p=>{const sx=pad.left+((p.x-xMin)/xR)*pw,sy=pad.top+((yMax-p.y)/yR)*ph;
    ctx.beginPath();ctx.arc(sx,sy,3.5,0,Math.PI*2);ctx.fillStyle=tc[p.team]||'rgba(128,128,128,0.6)';ctx.fill()});
  ctx.fillStyle='#333';ctx.font='bold 13px monospace';ctx.textAlign='center';ctx.fillText(title,W/2,18);
  ctx.font='12px monospace';ctx.fillText(xLbl,pad.left+pw/2,H-5);
  ctx.save();ctx.translate(14,pad.top+ph/2);ctx.rotate(-Math.PI/2);ctx.fillText(yLbl,0,0);ctx.restore()}

function drawCharts(){const d=teamNames.map(n=>({name:n,pts:nodesData[n]})).filter(d=>d.pts.length>0);
  drawScatter('chart-dist',d,'dist','Distance (km)','RSSI (dBm)','RSSI vs Distance');
  drawScatter('chart-ele',d,'ele','Elevation (m)','RSSI (dBm)','RSSI vs Elevation')}
</script>
</body>
</html>"""
end
