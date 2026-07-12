-- 基于OC的太空钻机模块流体缓存 - GTNH中文维基 - https://gtnh.huijiwiki.com/p/79342

local component=require("component")
local computer=require("computer")
local event=require("event")
local okU,unicode=pcall(require,"unicode")
if not okU then unicode=nil end
 
local CFG="pump-config-v3.lua"
local defs={
{"liquidair","液态空气",8,2,"9m","target",1},{"helium","氦",5,4,"2g","target",1},{"fluorine","氟",7,2,"30g","target",1},{"unknowwater","不明液体",8,4,"100m","target",1},{"hydrofluoricacid_gt5u","氢氟酸",7,1,"10m","target",1},
{"sulfuricacid","硫酸",4,1,"2g","target",1},{"oil","石油",4,3,"100m","target",1},{"ic2distilledwater","蒸馏水",8,5,"10g","target",1},{"chlorobenzene","氯苯",2,1,"100m","target",1},{"helium-3","氦-3",5,2,"10g","target",1},
{"deuterium","氘",6,1,"1g","target",1},{"tritium","氚",6,2,"1g","target",1},{"lava","岩浆",3,3,"30m","target",1},{"methane","甲烷",5,9,"10g","target",1},{"ethylene","乙烯",6,5,"100m","target",1},
{"molten.iron","熔融铁",4,2,"10g","target",1},{"molten.copper","熔融铜",8,3,"10g","target",1},{"molten.tin","熔融锡",8,7,"100m","target",1},{"molten.lead","熔融铅",4,5,"100m","target",1},{"argon","氩",5,7,"100m","target",1},
{"radon","氡",8,6,"10m","target",1},{"krypton","氪",5,8,"100m","target",1},{"xenon","氙",6,4,"0","always",1},{"endergoo","末影黏浆",3,1,"0","off",1},{"liquid_extra_heavy_oil","极重油",3,2,"0","off",1},
{"gas_natural_gas","天然气",3,4,"0","off",1},{"liquid_heavy_oil","重油",4,4,"0","off",1},{"liquid_medium_oil","原油",4,6,"0","off",1},{"liquid_light_oil","轻油",4,7,"0","off",1},{"carbondioxide","二氧化碳",4,8,"0","off",1},
{"carbonmonoxide","一氧化碳",5,1,"0","off",1},{"saltwater","盐水",5,3,"0","off",1},{"liquidoxygen","液氧",5,5,"0","off",1},{"neon","氖",5,6,"0","off",1},{"liquid_hydricsulfur","硫化氢",5,10,"0","off",1},
{"ethane","乙烷",5,11,"10m","target",1},{"ammonia","氨",6,3,"0","off",1},{"nitrogen","氮",7,3,"0","off",1},{"oxygen","氧",7,4,"0","off",1},{"hydrogen","氢",8,1,"0","off",1}}
 
local function q(v) return type(v)=="number" and tostring(v) or string.format("%q",v) end
local function save(cfg,fs)
  local h=io.open(CFG,"w"); if not h then return end
  cfg=cfg or {title="Space Pump v3",interval=30,rescan=300,w=160,h=50}
  h:write(string.format("return {\n cfg={title=%q,interval=%s,rescan=%s,w=%s,h=%s},\n fluids={\n",cfg.title,cfg.interval,cfg.rescan,cfg.w,cfg.h))
  for _,f in ipairs(fs or defs) do h:write(string.format("  {%s,%s,%d,%d,%s,%s,%d},\n",q(f[1]),q(f[2]),f[3],f[4],q(f[5]),q(f[6]),f[7] or 1)) end
  h:write(" }\n}\n"); h:close()
end
local fh=io.open(CFG,"r"); if fh then fh:close() else save(nil,defs) end
local d=assert(loadfile(CFG))()
local cfg=d.cfg or {title="Space Pump v3",interval=30,rescan=300,w=160,h=50}
local fluids=d.fluids or defs
local gpu=component.isAvailable("gpu") and component.gpu or nil
local me=component.isAvailable("me_interface") and component.me_interface or nil
local W,H,run,nextAt,lastScan,lastCost,selected,editing,editText,editErr=80,25,true,0,0,0,1,false,"",""
local pumps,cache,dirty,action={}, {}, false, "init"
local stepOpts={{1e7,"10M"},{5e7,"50M"},{1e8,"100M"},{5e8,"500M"},{1e9,"1G"},{5e9,"5G"},{1e10,"10G"},{5e10,"50G"},{1e11,"100G"},{5e11,"500G"},{1e12,"1T"},{5e12,"5T"},{1e13,"10T"},{5e13,"50T"},{1e14,"100T"},{5e14,"500T"}}
local modeBtns={{"OFF","off"},{"TARGET","target"},{"ALWAYS","always"},{"CUR","CUR"},{"EDIT","EDIT"}}
local priorityBtns={{"TOP","TOP"},{"UP","UP"},{"DOWN","DOWN"},{"BOTTOM","BOTTOM"}}
local setBtns,addBtns,subBtns={},{},{}
local weightBtns={{"-10",-10},{"-5",-5},{"-1",-1},{"+1",1},{"+5",5},{"+10",10}}
local refresh
 
local function call(f,...) if not f then return nil end local ok,r=pcall(f,...); if ok then return r end end
local function ulen(s) s=tostring(s or ""); return unicode and unicode.len(s) or #s end
local function usub(s,a,b) s=tostring(s or ""); return unicode and unicode.sub(s,a,b) or string.sub(s,a,b) end
local function fit(s,w) s=tostring(s or ""); if w<=0 then return "" elseif ulen(s)<=w then return s else return w==1 and usub(s,1,1) or usub(s,1,w-1).."~" end end
local function num(v) local n,u=tostring(v):match("^([%d%.]+)([kKmMgGtT]?)$"); n=tonumber(n) or 0; u=(u or ""):lower(); return n*(u=="k" and 1e3 or u=="m" and 1e6 or u=="g" and 1e9 or u=="t" and 1e12 or 1) end
local function valid(v) return tostring(v):match("^%d+%.?%d*[kKmMgGtT]?$")~=nil end
local function fmt(n) local a=math.abs(tonumber(n) or 0); if a>=1e12 then return string.format("%.1fT",n/1e12) elseif a>=1e9 then return string.format("%.1fG",n/1e9) elseif a>=1e6 then return string.format("%.1fM",n/1e6) elseif a>=1e3 then return string.format("%.1fK",n/1e3) end return tostring(math.floor(n or 0)) end
local function compact(n) local function trim(s) return (s:gsub("%.?0+$","")) end; local a=math.abs(n or 0); if a>=1e12 then return trim(string.format("%.3f",n/1e12)).."t" elseif a>=1e9 then return trim(string.format("%.3f",n/1e9)).."g" elseif a>=1e6 then return trim(string.format("%.3f",n/1e6)).."m" elseif a>=1e3 then return trim(string.format("%.3f",n/1e3)).."k" end return tostring(math.floor((n or 0)+0.5)) end
local function mshort(m) return m=="target" and "T" or m=="always" and "A" or "O" end
for _,f in ipairs(fluids) do f.t=num(f[5]); f.cur=0; f.run=0; f.st="OFF" end
local fByKey={} for _,f in ipairs(fluids) do fByKey[f[1]]=f end
 
local function put(x,y,s,fg,bg) if not gpu or y<1 or y>H or x>W then return end if fg then gpu.setForeground(fg) end if bg then gpu.setBackground(bg) end gpu.set(x,y,fit(s,W-x+1)) end
local function fill(x,y,w,h,c,bg) if not gpu or w<1 or h<1 then return end gpu.setBackground(bg or 0); gpu.fill(x,y,w,h,c or " ") end
local function bar(x,y,w,p,c) p=math.max(0,math.min(1,p or 0)); fill(x,y,w,1," ",0x303846); fill(x,y,math.floor(w*p+.5),1," ",c) end
local function setup()
  if not gpu then return end
  local ok,mw,mh=pcall(gpu.maxResolution); if not ok then mw,mh=80,25 end
  pcall(gpu.setDepth,8); pcall(gpu.setResolution,math.min(mw,cfg.w or 160),math.min(mh,cfg.h or 50)); W,H=gpu.getResolution(); fill(1,1,W,H," ",0x0b1020)
end
local function scan()
  local found,sig={},{}
  for a in component.list("gt_machine",true) do local ok,p=pcall(component.proxy,a); local n=ok and (call(p.getName) or ""):lower() or ""; local lv=tonumber(n:match("projectmodulepumpt([123])")); if lv then found[#found+1]={a=a,p=p,lv=lv,s=lv==1 and 1 or 4} end end
  table.sort(found,function(a,b) return a.a<b.a end)
  for i,m in ipairs(found) do sig[i]=m.a..":"..m.lv end
  if table.concat(sig,";")~=table.concat((function() local t={} for i,m in ipairs(pumps) do t[i]=m.a..":"..m.lv end return t end)(),";") then cache={} end
  pumps={}
  for _,m in ipairs(found) do local c=cache[m.a] or {c={}}; m.c,m.on=c.c,c.on; pumps[#pumps+1]=m; cache[m.a]=m end
  lastScan=computer.uptime(); dirty=false
  for _,m in ipairs(pumps) do local par=m.lv==1 and 1 or m.lv==2 and 4 or 64; for i=0,m.s-1 do pcall(m.p.setParameter,"recipe"..i..".parallel",par) end end
end
local function readME()
  local t,map=computer.uptime(),{}
  for _,s in ipairs(call(me.getFluidsInNetwork) or {}) do map[(s.name or s.label or ""):gsub("^fluid%.","")]=tonumber(s.size or s.amount) or 0 end
  for _,f in ipairs(fluids) do f.cur=map[f[1]] or 0; f.run=0 end
  lastCost=computer.uptime()-t
end
local function split(n,list,wf)
  local cnt,sum,rest={},0,{}
  for i,f in ipairs(list) do local w=math.max(0,wf(f) or 0); cnt[f[1]]=0; sum=sum+w; rest[i]={f=f,r=0,i=i,w=w} end
  if sum<=0 then return cnt end
  local used=0
  for i,r in ipairs(rest) do local raw=n*r.w/sum; local base=math.floor(raw); cnt[r.f[1]]=base; used=used+base; rest[i].r=raw-base end
  table.sort(rest,function(a,b) return a.r==b.r and a.i<b.i or a.r>b.r end)
  for i=1,n-used do cnt[rest[i].f[1]]=cnt[rest[i].f[1]]+1 end
  return cnt
end
local function moveSelected(to)
  if not fluids[selected] then return end
  local from=selected; to=math.max(1,math.min(#fluids,to)); if from==to then return end
  local f=table.remove(fluids,from); table.insert(fluids,to,f); selected=to; save(cfg,fluids); refresh(false)
end
local function makePlan(cnt)
  local slots,need,want,fill={},{},{},{}
  for k,v in pairs(cnt) do need[k]=v end
  for _,m in ipairs(pumps) do for i=0,m.s-1 do slots[#slots+1]={m,i} end end
  for i,s in ipairs(slots) do local k=s[1].c[s[2]]; if k and (need[k] or 0)>0 then want[i]=k; need[k]=need[k]-1 end end
  for _,f in ipairs(fluids) do for _=1,(need[f[1]] or 0) do fill[#fill+1]=f[1] end end
  local j=1; for i=1,#slots do if not want[i] then want[i]=fill[j]; j=j+1 end end
  return slots,want
end
local function schedule()
  local lows,alls,total={}, {}, 0
  for _,m in ipairs(pumps) do total=total+m.s end
  for _,f in ipairs(fluids) do if f[6]=="target" and f.cur<f.t then lows[#lows+1]=f elseif f[6]=="always" then alls[#alls+1]=f end end
  local cnt,phase={}, "idle"
  if #lows>0 then cnt,phase=split(total,lows,function() return 1 end),"target" elseif #alls>0 then cnt,phase=split(total,alls,function(f) return f[7] end),"always" end
  for _,f in ipairs(fluids) do f.run=cnt[f[1]] or 0; f.st=f[6]=="off" and "OFF" or f[6]=="target" and (f.cur<f.t and "LOW" or "OK") or phase=="always" and (f.run>0 and "RUN" or "IDLE") or "WAIT" end
  action=phase=="target" and ("target "..#lows) or phase=="always" and ("always "..#alls) or "idle"
  return makePlan(cnt)
end
local function apply(slots,want)
  local any=false
  for i,s in ipairs(slots) do
    local m,idx,key=s[1],s[2],want[i]; any=any or key~=nil
    if key and m.c[idx]~=key then local f=fByKey[key]; local ok=pcall(m.p.setParameter,"recipe"..idx..".planetType",f[3]) and pcall(m.p.setParameter,"recipe"..idx..".gasType",f[4]); if ok then m.c[idx]=key else dirty=true end end
  end
  for _,m in ipairs(pumps) do local on=any; if m.on~=on then if pcall(m.p.setWorkAllowed,on) then m.on=on else dirty=true end end end
end
local function btnW(bs) local w=0 for i,b in ipairs(bs) do w=w+ulen(b[1])+2+(i<#bs and 1 or 0) end return w end
local function drawBtns(bs,y,bg,fg,x) x=x or 3; for _,b in ipairs(bs) do put(x,y,"["..b[1].."]",fg,bg); b.x,b.y,b.w=x,y,ulen(b[1])+2; x=x+b.w+1 end end
local function summary(f)
  return string.format("selected: %02d %s  mode: %s  target: %s  weight: %d",selected,f[2],f[6],fmt(f.t),f[7]),
    string.format("current: %s  running slots: %d  state: %s  key: %s",fmt(f.cur),f.run,f.st,f[1])
end
local function drawHeader(left)
  fill(1,1,W,3," ",0x151d33); put(3,1,cfg.title,0x8bd5ff,0x151d33); put(W-12,1,"[Refresh]",0xfacc15,0x151d33)
  put(3,2,string.format("pumps:%d next:%ds scan:%.0fs ME:%.2fs",#pumps,left or 0,computer.uptime()-lastScan,lastCost),0xd7e1f0,0x151d33); put(3,3,"action: "..action,0x7f8da3,0x151d33)
end
local function drawRows()
  local cols,rows,top,cw=3,14,5,math.floor((W-4)/3)
  for i,f in ipairs(fluids) do
    local x,y=2+math.floor((i-1)/rows)*cw,top+((i-1)%rows)*2
    local sel=i==selected; local bg=sel and 0x223a5f or 0x101827; local c=f.st=="LOW" and 0xfb7185 or f.st=="RUN" and 0xfacc15 or f.st=="OFF" and 0x64748b or 0x4ade80
    fill(x,y,cw-1,2," ",bg); put(x,y,fit(string.format("%02d %-8s %s %s/%s w%d",i,fit(f[2],8),mshort(f[6]),fmt(f.cur),fmt(f.t),f[7]),cw-2),0xd7e1f0,bg); put(x+cw-6,y,fit(f.st,5),c,bg); bar(x,y+1,cw-3,f.t>0 and f.cur/f.t or (f.run>0 and 1 or 0),c)
  end
end
local function drawPriority(y)
  fill(3,y,W-4,1," ",0x35264d); put(5,y,"PRIORITY",0xf5d0fe,0x35264d)
  drawBtns(priorityBtns,y,0x35264d,0xffffff,15); drawBtns(modeBtns,y,0x243047,0xd7e1f0,math.max(3,W-btnW(modeBtns)-2))
end
local function drawWeight(y)
  fill(3,y,W-4,1," ",0x243a4d); put(5,y,"WEIGHT",0xbfe7ff,0x243a4d); drawBtns(weightBtns,y,0x243a4d,0xffffff,13)
end
local function drawCtl()
  local f=fluids[selected]; local s1,s2=summary(f); fill(1,H-7,W,7," ",0x151d33); put(3,H-7,s1,0x8bd5ff,0x151d33); put(3,H-6,s2,0xd7e1f0,0x151d33); drawPriority(H-5); drawWeight(H-4)
  if editing then
    put(3,H-3,"target value",0x8bd5ff,0x151d33); fill(17,H-3,26,1," ",0x05070d); put(19,H-3,fit(editText..(math.floor(computer.uptime())%2==0 and "_" or " "),22),editErr~="" and 0xfb7185 or 0xffffff,0x05070d)
    put(3,H-2,editErr~="" and editErr or "Enter=save  Backspace=delete  examples: 250m 2.5g 1t 0",editErr~="" and 0xfb7185 or 0x7f8da3,0x151d33)
  else
    drawBtns(setBtns,H-3,0x243047,0xd7e1f0,3); drawBtns(addBtns,H-2,0x16351f,0xd7fbe3,3); drawBtns(subBtns,H-1,0x3a1f24,0xffd7de,3)
  end
end
local function drawAll(left) drawHeader(left); drawRows(); drawCtl() end
local function saveAndRefresh() save(cfg,fluids); refresh(false) end
refresh=function(forceScan)
  if forceScan or dirty or computer.uptime()-lastScan>=(cfg.rescan or 300) then scan() end
  readME(); local slots,want=schedule(); apply(slots,want); nextAt=computer.uptime()+(cfg.interval or 30); drawAll(math.ceil(nextAt-computer.uptime()))
end
local function setTarget(v) local f=fluids[selected]; if not f then return end; if v=="EDIT" then editing=true; editText=tostring(f[5]); editErr=""; drawCtl(); return end; if v=="CUR" then v=tostring(math.floor(f.cur or 0)) end; f[5]=v; f.t=num(v); editing=false; editErr=""; saveAndRefresh() end
local function setMode(v) local f=fluids[selected]; if not f then return end; f[6]=v; saveAndRefresh() end
local function bumpTarget(d) local f=fluids[selected]; if not f then return end; local base=math.max(0,tonumber(f.t) or 0); setTarget(compact(math.max(0,base+d))) end
local function bumpW(d) local f=fluids[selected]; if not f then return end; f[7]=math.max(0,(f[7] or 0)+d); saveAndRefresh() end
local function onKey(ch,code)
  if not editing then return end
  if code==28 then if valid(editText) then setTarget(editText) else editErr="invalid target: use number or k/m/g/t suffix" end; return elseif code==14 then editText=usub(editText,1,ulen(editText)-1); editErr="" elseif ch and ch>=32 and ch<127 then editText=editText..string.char(ch); editErr="" end
  drawCtl()
end
local function hit(bs,x,y,fn) for _,b in ipairs(bs) do if b.x and y==b.y and x>=b.x and x<b.x+b.w then fn(b[2]); return true end end end
local function onTouch(x,y)
  if y<=2 and x>=W-12 then editing=false; refresh(true); return end
  local cols,rows,top,cw=3,14,5,math.floor((W-4)/3)
  if y>=top and y<top+rows*2 then local i=math.floor((x-2)/cw)*rows+math.floor((y-top)/2)+1; if fluids[i] then editing=false; selected=i; drawAll(math.ceil(nextAt-computer.uptime())); return end end
  if hit(modeBtns,x,y,function(v) if v=="CUR" or v=="EDIT" then setTarget(v) else setMode(v) end end) then return end
  if hit(priorityBtns,x,y,function(v) if v=="TOP" then moveSelected(1) elseif v=="UP" then moveSelected(selected-1) elseif v=="DOWN" then moveSelected(selected+1) else moveSelected(#fluids) end end) then return end
  if hit(weightBtns,x,y,bumpW) then return end
  if not editing then if hit(setBtns,x,y,function(v) setTarget(compact(v)) end) then return end; if hit(addBtns,x,y,bumpTarget) then return end; hit(subBtns,x,y,function(v) bumpTarget(-v) end) end
end
local function stop() run=false end
local function main()
  if not me then print("no me_interface"); return end
  for _,s in ipairs(stepOpts) do setBtns[#setBtns+1]={"="..s[2],s[1]}; addBtns[#addBtns+1]={"+"..s[2],s[1]}; subBtns[#subBtns+1]={"-"..s[2],s[1]} end
  setup(); scan(); event.listen("interrupted",stop); refresh(false)
  while run do
    if computer.uptime()>=nextAt then refresh(false) end
    drawHeader(math.max(0,math.ceil(nextAt-computer.uptime()))); if editing then drawCtl() end
    local e,_,x,y=event.pull(1); if e=="touch" then onTouch(x,y) elseif e=="key_down" then onKey(x,y) end
  end
  event.ignore("interrupted",stop); if gpu then fill(1,1,W,H," ",0); put(1,1,"pumpd stopped",0xffffff,0) end
end
local ok,err=xpcall(main,debug.traceback)
if not ok then if gpu then fill(1,1,W,H," ",0); put(1,1,tostring(err),0xffffff,0) else print(err) end end