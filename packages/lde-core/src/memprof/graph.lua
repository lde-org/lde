-- HTML memory graph for `lde run --memgraph`: heap size and allocations over time, with an allocation flamegraph for the whole run or a selected time range.

const fs = require("fs")
const json = require("json")
const report = require("lde-core.memprof.report")

const graph = {}

const TEMPLATE = [==[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Memory · __TITLE__</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#111;color:#ccc;font:13px/1.4 monospace;display:flex;flex-direction:column;height:100vh;overflow:hidden}
#bar{display:flex;gap:18px;align-items:baseline;padding:8px 14px;background:#1c1c1c;border-bottom:1px solid #2a2a2a;user-select:none}
#bar h1{font-size:13px;color:#eee}
#bar b{color:#eee;font-weight:normal}
#sel{color:#6a9fd8}
.label{padding:8px 14px 2px;color:#999;font-size:12px;user-select:none}
.label span{color:#555}
canvas{display:block;width:100%}
#heap,#alloc{cursor:crosshair}
#legend{display:flex;flex-wrap:wrap;gap:2px 16px;padding:4px 14px;font-size:12px;color:#aaa}
#legend i{display:inline-block;width:10px;height:10px;margin-right:6px;vertical-align:-1px}
#fg{flex:1;min-height:100px;cursor:pointer}
#tt{position:fixed;background:#222;border:1px solid #444;padding:6px 10px;font-size:12px;pointer-events:none;
    display:none;white-space:nowrap;color:#eee;border-radius:3px;box-shadow:0 2px 8px #0008}
</style>
</head>
<body>
<div id="bar">
  <h1>__TITLE__</h1>
  <span>peak <b id="peak"></b></span>
  <span>retained after exit <b id="ret"></b></span>
  <span>sampled growth <b id="grow"></b></span>
  <span id="sel"></span>
</div>
<div class="label">Heap size <span>· guest bytes over profiled CPU time · green dots: reachable bytes at heap snapshots · drag to select a range, double-click to clear</span></div>
<canvas id="heap" style="height:170px"></canvas>
<div class="label">Allocations <span>· memory that grew between samples, by allocation site</span></div>
<canvas id="alloc" style="height:110px"></canvas>
<div id="legend"></div>
<div class="label">Allocation flamegraph <span id="fgl"></span></div>
<canvas id="fg"></canvas>
<div id="tt"></div>
<script>
var D=__DATA__;
function arr(x){return x&&x.length?x:[];}
var B=arr(D.buckets),S=arr(D.sites),SN=arr(D.snapshots);
var COLORS=['#e4572e','#f3a712','#4f9d69','#669bbc','#c06c84','#a8c686','#8d6a9f','#d9a066'];
var tMax=B.length?B[B.length-1].t+D.bucketMs:1;
var SEL=null,DRAG=null,FOC=null,ROOT=null,PATH=[],HOV=null;
var tt=document.getElementById('tt');

function fmtB(n){var a=Math.abs(n);if(a<1024)return Math.round(n)+' B';if(a<1048576)return(n/1024).toFixed(1)+' KiB';
  if(a<1073741824)return(n/1048576).toFixed(1)+' MiB';return(n/1073741824).toFixed(2)+' GiB';}
function fmtT(ms){return ms<1000?Math.round(ms)+'ms':(ms/1000).toFixed(2)+'s';}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;');}

var totals={},TOP=[];
B.forEach(function(b){arr(b.s).forEach(function(p){totals[p[0]]=(totals[p[0]]||0)+p[1];});});
TOP=Object.keys(totals).map(Number).sort(function(a,b){return totals[b]-totals[a];}).slice(0,COLORS.length);
function colorOf(id){var i=TOP.indexOf(id);return i<0?'#555':COLORS[i];}

function fit(cv){cv.width=cv.clientWidth;cv.height=cv.clientHeight;return cv.getContext('2d');}
function xOf(t,w){return t/tMax*w;}
function tOf(x,w){return Math.max(0,Math.min(tMax,x/w*tMax));}
function inSel(b){return !SEL||(b.t+D.bucketMs>SEL[0]&&b.t<SEL[1]);}

function drawSel(c,w,h){
  if(!SEL)return;
  var x0=xOf(SEL[0],w),x1=xOf(SEL[1],w);
  c.fillStyle='rgba(106,159,216,0.15)';c.fillRect(x0,0,x1-x0,h);
  c.strokeStyle='#6a9fd8';c.strokeRect(x0+0.5,0.5,x1-x0,h-1);
}
function axis(c,w,h,max){
  c.fillStyle='#666';c.font='11px monospace';
  c.fillText(fmtB(max),4,12);
  for(var i=1;i<=4;i++){var t=tMax*i/5;c.fillText(fmtT(t),xOf(t,w)-14,h-4);}
}

function drawHeap(){
  var cv=document.getElementById('heap'),c=fit(cv),w=cv.width,h=cv.height-16,max=1;
  B.forEach(function(b){max=Math.max(max,b.p);});
  SN.forEach(function(s){max=Math.max(max,s.bytes);});
  max*=1.08;
  var bw=Math.max(1,xOf(D.bucketMs,w));
  c.fillStyle='#2b3a4a';
  B.forEach(function(b){var y=h-b.p/max*h;c.fillRect(xOf(b.t,w),y,bw,h-y);});
  c.strokeStyle='#6a9fd8';c.lineWidth=1.5;c.beginPath();
  B.forEach(function(b,i){var x=xOf(b.t,w)+bw/2,y=h-b.b/max*h;if(i)c.lineTo(x,y);else c.moveTo(x,y);});
  c.stroke();
  c.fillStyle='#4f9d69';
  SN.forEach(function(s){c.beginPath();c.arc(xOf(s.t,w),h-s.bytes/max*h,3.5,0,7);c.fill();});
  axis(c,w,cv.height,max);drawSel(c,w,cv.height);
}

function drawAlloc(){
  var cv=document.getElementById('alloc'),c=fit(cv),w=cv.width,h=cv.height-16,max=1;
  B.forEach(function(b){max=Math.max(max,b.a);});
  var bw=Math.max(1,xOf(D.bucketMs,w)-(xOf(D.bucketMs,w)>3?1:0));
  B.forEach(function(b){
    var x=xOf(b.t,w),y=h,other=b.a;
    TOP.forEach(function(id){
      arr(b.s).forEach(function(p){if(p[0]===id){var hh=p[1]/max*h;y-=hh;other-=p[1];c.fillStyle=colorOf(id);c.fillRect(x,y,bw,hh);}});
    });
    if(other>0){var hh=other/max*h;c.fillStyle='#555';c.fillRect(x,y-hh,bw,hh);}
  });
  axis(c,w,cv.height,max);drawSel(c,w,cv.height);
}

function legend(){
  var el=document.getElementById('legend'),html='';
  TOP.forEach(function(id){html+='<span><i style="background:'+colorOf(id)+'"></i>'+esc(S[id].label)
    +' <span style="color:#666">'+fmtB(totals[id])+'</span></span>';});
  if(Object.keys(totals).length>TOP.length)html+='<span><i style="background:#555"></i>other sites</span>';
  el.innerHTML=html;
}

function buildTree(){
  var root={n:'all allocations',v:0,c:[],m:{}};
  B.forEach(function(b){
    if(!inSel(b))return;
    arr(b.s).forEach(function(p){
      var node=root;root.v+=p[1];
      arr(S[p[0]].frames).forEach(function(f){
        var k=node.m[f];
        if(!k){k={n:f,v:0,c:[],m:{}};node.m[f]=k;node.c.push(k);}
        k.v+=p[1];node=k;
      });
    });
  });
  ROOT=FOC=root;PATH=[];
  document.getElementById('fgl').textContent=(SEL?'· '+fmtT(SEL[0])+' → '+fmtT(SEL[1]):'· whole run')
    +' · '+fmtB(root.v)+' · outermost caller at the top · click to zoom, Esc to reset';
  document.getElementById('sel').textContent=SEL?'selected '+fmtT(SEL[0])+' → '+fmtT(SEL[1]):'';
}

var RH=20;
function hue(n){var h=0;for(var i=0;i<n.length;i++)h=(h*31+n.charCodeAt(i))|0;return'hsl('+((h>>>0)%40+15)+',65%,40%)';}
function kids(n){return n.c.slice().sort(function(a,b){return b.v-a.v;});}
function paint(c,n,x,y,w){
  if(w<0.5||y>c.canvas.height)return;
  c.fillStyle=n===HOV?'#ddd':(n===FOC?'#3a3a3a':hue(n.n));
  c.fillRect(x,y,Math.max(0,w-1),RH-1);
  if(w>30){c.fillStyle=n===HOV?'#111':'#fff';c.font='11px monospace';
    var max=Math.floor((w-6)/6.6),l=n.n.length>max?n.n.slice(0,Math.max(1,max-1))+'\u2026':n.n;c.fillText(l,x+3,y+RH-6);}
  var kx=x;kids(n).forEach(function(k){var kw=FOC.v?w*k.v/n.v:0;paint(c,k,kx,y+RH,kw);kx+=kw;});
}
function hit(n,x,y,w,mx,my){
  if(w<0.5||mx<x||mx>=x+w)return null;
  if(my>=y&&my<y+RH)return n;
  var kx=x,ks=kids(n);
  for(var i=0;i<ks.length;i++){var kw=w*ks[i].v/n.v,r=hit(ks[i],kx,y+RH,kw,mx,my);if(r)return r;kx+=kw;}
  return null;
}
function drawFg(){var cv=document.getElementById('fg'),c=fit(cv);if(FOC&&FOC.v)paint(c,FOC,0,0,cv.width);}

function drawAll(){drawHeap();drawAlloc();drawFg();}

function bucketAt(x,w){var t=tOf(x,w);for(var i=0;i<B.length;i++)if(t>=B[i].t&&t<B[i].t+D.bucketMs)return B[i];return null;}
function showTip(e,html){tt.innerHTML=html;tt.style.cssText='display:block;left:'+Math.min(e.clientX+14,window.innerWidth-360)+'px;top:'+(e.clientY+14)+'px';}

['heap','alloc'].forEach(function(id){
  var cv=document.getElementById(id);
  cv.addEventListener('mousedown',function(e){DRAG=tOf(e.offsetX,cv.width);});
  cv.addEventListener('mousemove',function(e){
    if(DRAG!==null){var t=tOf(e.offsetX,cv.width);SEL=[Math.min(DRAG,t),Math.max(DRAG,t)];drawHeap();drawAlloc();return;}
    var b=bucketAt(e.offsetX,cv.width);if(!b){tt.style.display='none';return;}
    var top=arr(b.s).slice().sort(function(p,q){return q[1]-p[1];}).slice(0,3).map(function(p){
      return '<br><span style="color:'+colorOf(p[0])+'">\u25A0</span> '+esc(S[p[0]].label)+'  '+fmtB(p[1]);}).join('');
    showTip(e,'<b>'+fmtT(b.t)+' \u2013 '+fmtT(b.t+D.bucketMs)+'</b><br>heap '+fmtB(b.b)+' \u00b7 peak '+fmtB(b.p)
      +'<br>grew '+fmtB(b.a)+top);
  });
  cv.addEventListener('mouseleave',function(){tt.style.display='none';});
  cv.addEventListener('dblclick',function(){SEL=null;buildTree();drawAll();});
});
window.addEventListener('mouseup',function(){
  if(DRAG===null)return;DRAG=null;
  if(SEL&&SEL[1]-SEL[0]<D.bucketMs/2)SEL=null;
  buildTree();drawAll();
});

var fg=document.getElementById('fg');
fg.addEventListener('mousemove',function(e){
  var n=FOC?hit(FOC,0,0,fg.width,e.offsetX,e.offsetY):null;HOV=n;drawFg();
  if(n)showTip(e,'<b>'+esc(n.n)+'</b><br>'+fmtB(n.v)+' \u00b7 '+(ROOT.v?(n.v/ROOT.v*100).toFixed(1):0)+'%');
  else tt.style.display='none';
});
fg.addEventListener('mouseleave',function(){HOV=null;tt.style.display='none';drawFg();});
fg.addEventListener('click',function(e){
  var n=FOC?hit(FOC,0,0,fg.width,e.offsetX,e.offsetY):null;if(!n)return;
  if(n===FOC){if(PATH.length)FOC=PATH.pop();}else{PATH.push(FOC);FOC=n;}
  HOV=null;drawFg();
});
document.addEventListener('keydown',function(e){if(e.key==='Escape'){FOC=ROOT;PATH=[];drawFg();}});
window.addEventListener('resize',drawAll);

document.getElementById('peak').textContent=fmtB(D.peak);
document.getElementById('ret').textContent=fmtB(D.retained);
document.getElementById('grow').textContent=fmtB(D.allocated);
legend();buildTree();drawAll();
</script>
</body>
</html>]==]

--- Write the memory graph. Site frames are listed outermost first, so the flamegraph reads from the entry point down to the allocating line.
---@param mem lde.MemoryProfile
---@param filePath string
---@param title string?
---@param cwd string?
---@return boolean? ok
---@return string? err
function graph.write(mem, filePath, title, cwd)
	---@type table<string, integer>
	const siteIds = {}
	const sites = {}
	---@param stack string
	local function siteId(stack)
		const known = siteIds[stack]
		if known then return known end
		const frames = report.frames(stack, cwd)
		const labels = {}
		for i = #frames, 1, -1 do labels[#labels + 1] = report.frameLabel(frames[i]) end
		const id = #sites
		sites[id + 1] = { label = frames[1] and report.frameLabel(frames[1]) or stack, frames = labels }
		siteIds[stack] = id
		return id
	end

	const buckets = {}
	for i, bucket in ipairs(mem.timeline) do
		const entries = {}
		for stack, bytes in pairs(bucket.sites) do entries[#entries + 1] = { siteId(stack), bytes } end
		buckets[i] = { t = bucket.atMs, b = bucket.bytes, p = bucket.peak, a = bucket.allocated, s = entries }
	end

	const snapshots = {}
	for i, snapshot in ipairs(mem.snapshots or {}) do
		snapshots[i] = { t = snapshot.atMs, bytes = snapshot.attributed, label = snapshot.label }
	end

	const data = json.encode({
		bucketMs = mem.bucketMs,
		peak = mem.peak,
		retained = mem.retained or 0,
		allocated = mem.allocated,
		buckets = buckets,
		sites = sites,
		snapshots = snapshots,
	})
	if not data then return nil, "failed to encode memory data" end

	-- Escape "</" so a site label cannot close the script tag; % is special in gsub replacements.
	const safeData = data:gsub("</", "<\\/"):gsub("%%", "%%%%")
	const safeTitle = (title or "memory"):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub("%%", "%%%%")
	const html = TEMPLATE:gsub("__TITLE__", safeTitle):gsub("__DATA__", safeData)
	if not fs.write(filePath, html) then
		return nil, "failed to write " .. filePath
	end
	return true
end

return graph
