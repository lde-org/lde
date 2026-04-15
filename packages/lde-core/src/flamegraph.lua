local fs = require("fs")

local M = {}

--- Build a tree from { "outerFrame;...;innerFrame" = count } folded stacks.
function M.buildTree(stacks, rootName)
	local root = { n = rootName or "root", v = 0, c = {} }

	for stackStr, count in pairs(stacks) do
		root.v = root.v + count
		local node = root
		for frame in stackStr:gmatch("([^;]+)") do
			local child
			for _, c in ipairs(node.c) do
				if c.n == frame then child = c; break end
			end
			if not child then
				child = { n = frame, v = 0, c = {} }
				node.c[#node.c + 1] = child
			end
			child.v = child.v + count
			node = child
		end
	end

	return root
end

--- Minimal JSON encoder for the tree (only needs string keys n, integer v, array c).
local function jsonStr(s)
	return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
end

local function jsonNode(node)
	local s = '{"n":' .. jsonStr(node.n) .. ',"v":' .. node.v
	if #node.c > 0 then
		local parts = {}
		for i, child in ipairs(node.c) do parts[i] = jsonNode(child) end
		s = s .. ',"c":[' .. table.concat(parts, ',') .. ']'
	end
	return s .. '}'
end

local TEMPLATE = [==[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Flamegraph · __TITLE__</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#111;color:#ccc;font:13px/1.4 monospace;overflow:hidden}
#bar{display:flex;align-items:center;gap:14px;padding:8px 14px;
     background:#1c1c1c;border-bottom:1px solid #2a2a2a;user-select:none}
#bar h1{font-size:13px;font-weight:bold;color:#eee}
#info{color:#666;font-size:12px}
#back{display:none;color:#888;font-size:12px;cursor:pointer;border:none;
      background:none;padding:2px 6px;border:1px solid #444;border-radius:3px;color:#aaa}
#back:hover{background:#2a2a2a}
#tt{position:fixed;background:#222;border:1px solid #444;padding:6px 10px;
    font-size:12px;pointer-events:none;display:none;white-space:nowrap;color:#eee;
    border-radius:3px;box-shadow:0 2px 8px #0008}
canvas{display:block;cursor:crosshair}
</style>
</head>
<body>
<div id="bar">
  <h1>__TITLE__</h1>
  <span id="info"></span>
  <button id="back">&#8592; back</button>
</div>
<div id="tt"></div>
<canvas id="cv"></canvas>
<script>
var D=__DATA__,MS=__MS__;
var ROOT=D,FOC=D,PATH=[],HOV=null;
var cv=document.getElementById('cv');
var ct=cv.getContext('2d');
var tt=document.getElementById('tt');
var RH=22;

function clr(name){
  if(name===FOC.n)return'#3a3a3a';
  var h=0;for(var i=0;i<name.length;i++)h=(h*31+name.charCodeAt(i))|0;
  return'hsl('+((h>>>0)%50+12)+',70%,42%)';
}
function fmt(v){var ms=v*MS;return ms<1000?'~'+ms+'ms':'~'+(ms/1000).toFixed(1)+'s';}
function bySize(a,b){return b.v-a.v;}
function kids(n){return(n.c||[]).slice().sort(bySize);}

function resize(){
  cv.width=window.innerWidth;
  cv.height=window.innerHeight-document.getElementById('bar').offsetHeight;
  draw();
}

function draw(){
  ct.clearRect(0,0,cv.width,cv.height);
  paint(FOC,0,cv.height-RH,cv.width);
}

function paint(node,x,y,w){
  if(w<0.5||y+RH<0)return;
  ct.fillStyle=node===HOV?'#ddd':clr(node.n);
  ct.fillRect(x,y,Math.max(0,w-1),RH-1);
  if(w>24){
    ct.fillStyle=node===HOV?'#111':(node===FOC?'#bbb':'#fff');
    ct.font='11px monospace';
    var max=Math.floor((w-6)/6.4);
    var lbl=node.n.length>max?node.n.slice(0,Math.max(1,max-1))+'\u2026':node.n;
    ct.fillText(lbl,x+3,y+RH-6);
  }
  var kx=x,ks=kids(node);
  for(var i=0;i<ks.length;i++){
    var kw=w*ks[i].v/node.v;
    paint(ks[i],kx,y-RH,kw);
    kx+=kw;
  }
}

function hit(node,x,y,w,mx,my){
  if(w<0.5||mx<x||mx>=x+w)return null;
  var kx=x,ks=kids(node);
  for(var i=0;i<ks.length;i++){
    var kw=w*ks[i].v/node.v;
    var r=hit(ks[i],kx,y-RH,kw,mx,my);
    if(r)return r;
    kx+=kw;
  }
  return(my>=y&&my<y+RH)?node:null;
}

function gpos(e){var r=cv.getBoundingClientRect();return[e.clientX-r.left,e.clientY-r.top];}

cv.addEventListener('mousemove',function(e){
  var p=gpos(e),n=hit(FOC,0,cv.height-RH,cv.width,p[0],p[1]);
  HOV=n;
  if(n){
    var pct=(n.v/ROOT.v*100).toFixed(1);
    tt.innerHTML='<b>'+n.n+'</b>  '+pct+'%  '+fmt(n.v)
      +'  <span style="color:#666">'+n.v+' samples</span>';
    var tx=Math.min(e.clientX+14,window.innerWidth-280);
    tt.style.cssText='display:block;left:'+tx+'px;top:'+(e.clientY-40)+'px';
  }else{tt.style.display='none';}
  draw();
});

cv.addEventListener('mouseleave',function(){HOV=null;tt.style.display='none';draw();});

cv.addEventListener('click',function(e){
  var p=gpos(e),n=hit(FOC,0,cv.height-RH,cv.width,p[0],p[1]);
  if(!n)return;
  if(n===FOC){if(PATH.length)FOC=PATH.pop();}
  else{PATH.push(FOC);FOC=n;}
  HOV=null;tt.style.display='none';
  document.getElementById('back').style.display=PATH.length?'inline':'none';
  resize();
});

document.getElementById('back').addEventListener('click',function(){
  if(PATH.length)FOC=PATH.pop();
  this.style.display=PATH.length?'inline':'none';
  resize();
});

document.addEventListener('keydown',function(e){
  if(e.key==='Escape'){PATH=[];FOC=ROOT;
    document.getElementById('back').style.display='none';resize();}
});

window.addEventListener('resize',resize);
document.getElementById('info').textContent=ROOT.v+' samples · '+fmt(ROOT.v);
resize();
</script>
</body>
</html>]==]

--- Write a self-contained flamegraph HTML file.
---@param stacks table<string, number> folded stack strings → sample count
---@param total number total sample count
---@param intervalMs number sampling interval in ms
---@param path string output file path
---@param title string? display title
---@return boolean? ok
---@return string? err
function M.write(stacks, total, intervalMs, path, title)
	if not next(stacks) then return nil, "no stack data collected" end

	local root = M.buildTree(stacks, title or "root")
	local json = jsonNode(root):gsub("</%f[a-z]", "<\\/")  -- escape </tag> sequences

	local safeTitle = (title or "profile"):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
	local html = TEMPLATE
		:gsub("__TITLE__", safeTitle)
		:gsub("__DATA__", (json:gsub("%%", "%%%%")))
		:gsub("__MS__", tostring(intervalMs))

	if not fs.write(path, html) then
		return nil, "failed to write " .. path
	end
	return true
end

return M
