local tui = require("tui")
local utils = require("utils")
local timer = require("timer")
local proc = require("proc")
local enc = string.char
local dec = string.byte
local sub = string.sub
local unpack = table.unpack
-- local insert = table.insert
local remove = table.remove
local concat = table.concat
local random = math.random
local floor = math.floor
local bxor = bit32.bxor

------- Clock ----------------------------------

local gtime = os.time
local clock = os.clock
local epoch0 = os.epoch
local EPOCH = 1617078887611
local function epoch() return epoch0("utc") - EPOCH end

------- Crypto ------------------------------

local CRC = {}
for i = 0, 255 do
  local x = i
  for _ = 1, 8 do
    if x % 2 == 0 then
      x = x / 2
    else
      x = bxor(x / 2, 0xEDB88320)
    end
  end
  CRC[i + 1] = x
end

local function crc(sum, b) --
  return bxor(sum / 256, CRC[bxor(sum % 256, b) + 1])
end

local function crc32n_str(sum, str)
  for p = 1, #str do sum = crc(sum, dec(str, p)) end
  return sum
end

local function crc32n_buf(sum, buf)
  for i = 1, #buf do sum = crc(sum, buf[i]) end
  return sum
end

local function crc32n0_cww(a, b, c)
  return crc(crc(crc(crc(CRC[a + 1], b / 256), b % 256), c / 256), c % 256)
end

local function rc4_new(key)
  local ks = {0, 0, 0, 1, 2, 3, 4, 5, 6}
  for i = 7, 255 do ks[i + 3] = i end
  local j, len = 0, #key
  for i = 0, 255 do
    j = (j + ks[i + 3] + dec(key, i % len + 1)) % 256
    ks[i + 3], ks[j + 3] = ks[j + 3], ks[i + 3]
  end
  return ks
end

local function rc4_load(str) return {dec(str, 1, 258)} end

local function rc4_save(ks) return enc(unpack(ks)) end

local function rc4_crypt(ks, buf)
  local x, y = ks[1], ks[2]
  local a, b
  for i = 1, #buf do
    x = (x + 1) % 256
    a = ks[x + 3]
    y = (y + a) % 256
    b = ks[y + 3]
    ks[y + 3], ks[x + 3] = a, b
    buf[i] = bxor(ks[(a + b) % 256 + 3], buf[i])
  end
  ks[1], ks[2] = x, y
  return buf
end

local function rc4_crypt_str(ks, str)
  return enc(unpack(rc4_crypt(ks, {dec(str, 1, #str)})))
end

local function rc4_crypt_substr(ks, str, i, j)
  local num = 0
  local x, y = ks[1], ks[2]
  local a, b
  for p = i, j do
    x = (x + 1) % 256
    a = ks[x + 3]
    y = (y + a) % 256
    b = ks[y + 3]
    ks[y + 3], ks[x + 3] = a, b
    num = num * 256 + bxor(ks[(a + b) % 256 + 3], dec(str, p))
  end
  ks[1], ks[2] = x, y
  return num
end

local function rc4_crypt_byte(ks, byte)
  local x = (ks[1] + 1) % 256
  local a = ks[x + 3]
  local y = (ks[2] + a) % 256
  local b = ks[y + 3]
  ks[1], ks[2], ks[y + 3], ks[x + 3] = x, y, a, b
  return bxor(ks[(a + b) % 256 + 3], byte)
end

------- Convert ---------------------------------

local function besu32(s)
  local a, b, c, d = dec(s, 1, 4)
  return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

local function u32bes(x)
  local d = x % 256
  x = (x - d) / 256
  local c = x % 256
  x = (x - c) / 256
  local b = x % 256
  x = (x - b) / 256
  return enc(x % 256, b, c, d)
end

local function besu16(s)
  local a, b = dec(s, 1, 2)
  return a * 0x100 + b
end

local function u16bes(x)
  local b = x % 256
  x = (x - b) / 256
  return enc(x % 256, b)
end

------- Random ----------------------------------

local function nonce32() return floor(random() * 0xFFFFFFFF) end

local function randstr3()
  local x = random(0, 0xFFFFFF)
  local c = x % 256
  x = (x - c) / 256
  local b = x % 256
  x = (x - b) / 256
  return enc(x % 256, b, c)
end

------- Identity --------------------------------

local function token32(id) return id % 256 * 0x1000000 + random(0, 0xFFFFFF) end

------- Constants -----------------------------

local WEP_DTG = 0x10

local WEP_LNK = 0x20

------- Base ------------------------------------

local managed = setmetatable({}, {__mode = "v"})

local function wep_pkg(mode, name, ks, cls, ch, rch, body)
  local a, d, c, b
  a = crc32n0_cww(cls, ch, rch)
  if body then a = crc32n_str(a, body) end
  d = a % 256
  a = (a - d) / 256
  c = a % 256
  a = (a - c) / 256
  b = a % 256
  a = (a - b) / 256
  local cmac = enc(unpack(rc4_crypt(ks, {a, b, c, d, cls})))
  body = body and rc4_crypt_str(ks, body) or ""
  return enc(mode + #name) .. name .. cmac .. body
end

------- Prototype ----------------------------------

local Link = { --
  onConnected = {},
  chid = utils.id,
  idch = utils.id,
  msg = {}
}

function Link.reg(self, Msg)
  local i = #self.msg + 1
  self.msg[Msg.name] = i
  self.msg[i] = Msg
  return i
end

function Link.post(self, ch, cls, body)
  local rch = self.idch(self.id)
  local ks = rc4_new(self.key)
  local pkg = wep_pkg(WEP_DTG, self.name, ks, cls, ch, rch, body)
  self.hws(ch, rch, pkg)
end

function Link.send(self, id, cls, body)
  local tch = self.idch(id)
  local mch = self.idch(self.id)
  local kss = self.kstx[id]
  if not kss then return end
  local ks = rc4_load(kss)
  local pkg = wep_pkg(WEP_LNK, self.name, ks, cls, tch, mch, body)
  self.kstx[id] = rc4_save(ks)
  self.hws(tch, mch, pkg)
end

function Link.sendAll(self, cls, body)
  local mch = self.idch(self.id)
  local kstx = self.kstx
  local hws = self.hws
  for id, kss in pairs(kstx) do
    local tch = self.idch(id)
    local ks = rc4_load(kss)
    local pkg = wep_pkg(WEP_LNK, self.name, ks, cls, tch, mch, body)
    kstx[id] = rc4_save(ks)
    hws(tch, mch, pkg)
  end
end

function Link.sendEach(self, cls, Body)
  local mch = self.idch(self.id)
  local kstx = self.kstx
  local hws = self.hws
  for id, kss in pairs(kstx) do
    local body = Body(id)
    local tch = self.idch(id)
    local ks = rc4_load(kss)
    local pkg = wep_pkg(WEP_LNK, self.name, ks, cls, tch, mch, body)
    kstx[id] = rc4_save(ks)
    hws(tch, mch, pkg)
  end
end

------- ConnReq Sender -------------------------------------

local function lnrq_tmo(self)
  local tbl = self.link.lnrq
  local key = self.tkpubl
  if tbl[key] == self then
    tbl[key] = nil
    self.link:log("Conn " .. self.time .. " Finish") -- After", self.interval * 1000)
  end
end

-- @param tmo_ms default 9000, max 65535
function Link.connect(self, ch, tmo_ms)
  ch = ch or 65535
  tmo_ms = tmo_ms or 9000

  local tkpubl = token32(self.id)
  while self.lnrq[tkpubl] do tkpubl = tkpubl + 1 end

  local _time = floor(gtime() * 1000)
  self.lnrq[tkpubl] = timer.start({
    ontimer = lnrq_tmo,
    interval = tmo_ms / 1000,
    link = self,
    ch = ch,
    tkpubl = tkpubl,
    clock = clock(),
    time = _time
  })

  self:post(ch, self.msg.ConnReq, u32bes(tkpubl) .. u32bes(epoch()) .. u16bes(tmo_ms))
  self:log("Conn " .. _time .. " Start")
  return tkpubl
end

------- ConnReq Handler -------------------------------------

local function lnrs_tmo(self)
  local tbl = self.link.lnrs
  local key = self.id
  if tbl[key] == self then
    tbl[key] = nil
    self.link:log("Conn Of #" .. self.id .. " Expr")
  end
end

Link:reg({
  name = "ConnReq",
  mode = WEP_DTG,
  min = 10,
  max = 10,
  handle = function(self, id, body)
    local peer = self.peer[id]
    if peer == false then return end

    local time = besu32(sub(body, 5, 8))
    local duration = epoch() - time
    if duration < 0 then return end

    local tmo_ms = besu16(sub(body, 9, 10))
    local rem_ms = tmo_ms - duration
    if rem_ms < 0 then return end

    local old = self.lnrs[id]
    if old then
      if old.accepted ~= nil or old.time >= time then return end
      old:stop()
    end

    local rem_s = rem_ms / 1000
    self.lnrs[id] = timer.start({
      ontimer = lnrs_tmo,
      interval = rem_s,
      link = self,
      id = id,
      time = time,
      expire = clock() + rem_s,
      tkpubl = besu32(sub(body, 1, 4))
    })

    self:log("Conn Of #" .. id .. " " .. rem_ms)

    if peer then return self:accept(id) end
  end
})

------- ConnAcpt Sender --------------------------------------

function Link.accept(self, id)
  local res = self.lnrs[id]
  if not res then return end

  if not res.accepted then
    res:stop()
    local now = clock()
    local rtt = (res.expire - now) * 2
    res.interval = rtt
    res.expire = now + rtt
    res.tkpriv = token32(self.id)
    res.accepted = true
    res:start()
  end

  self:post(self.idch(id), self.msg.ConnAcpt, u32bes(res.tkpubl) .. u32bes(res.tkpriv))
end

------- ConnAcpt Handler -------------------------------------

Link:reg({
  name = "ConnAcpt",
  mode = WEP_DTG,
  min = 8,
  max = 8,
  handle = function(self, id, body, dist)
    if self.seen[id] then return end

    local tkpubl = besu32(sub(body, 1, 4))
    local lnrq = self.lnrq[tkpubl]
    if not lnrq then return end

    local tch = self.idch(id)
    local mch = self.idch(self.id)
    local res = u32bes(nonce32()) .. sub(body, 5, 8)
    local ks0 = rc4_new(self.key)
    local pkg = wep_pkg(WEP_DTG, self.name, ks0, self.msg.ConnEstb, tch, mch, res)
    local kss = rc4_save(ks0)
    self.ksrx[id] = kss
    self.kstx[id] = kss

    self:saw(id, dist)

    self.hws(tch, mch, pkg)

    self:log("Conn Acpt By #" .. id) -- , "After", floor((clock() - lnrq.clock) * 1000))

    return self:onConnected(id)
  end
})

------- ConnEstb Handler ----------------------------------

Link:reg({
  name = "ConnEstb",
  mode = WEP_DTG,
  min = 8,
  max = 262,
  handle = function(self, id, body, dist, ksrx)
    local res = self.lnrs[id]
    if not res or not res.accepted then return end

    local tkpriv = besu32(sub(body, 5, 8))
    if tkpriv ~= res.tkpriv then return end

    res:stop()
    self.lnrs[id] = nil

    local kss = rc4_save(ksrx)
    self.ksrx[id] = kss
    self.kstx[id] = kss

    self:saw(id, dist)

    self:log("Conn Estb #" .. id)

    return self:onConnected(id)
  end
})

------- ConnClose Sender -------------------------------------

function Link.kill(self, id)
  self.kstx[id] = nil
  self.ksrx[id] = nil
  self.seen[id] = nil
  self.dist[id] = nil
  self.watcher[id] = nil
  self.watching[id] = nil
end

function Link.close(self, id)
  local kss = self.kstx[id]
  self:kill(id)
  if not kss then return end
  local ks = rc4_load(kss)
  local tch = self.idch(id)
  local mch = self.idch(self.id)
  local pkg = wep_pkg(WEP_LNK, self.name, ks, self.msg.ConnClose, tch, mch)
  self.hws(tch, mch, pkg)
end

------- ConnClose Handler ------------------------------------

Link:reg({
  name = "ConnClose",
  mode = WEP_LNK,
  min = 0,
  max = 0,
  handle = function(self, id)
    self:log("Conn Close #" .. id)
    return self:kill(id)
  end
})

------- ConnAlive Sender -----------------------------------

function Link.hint(self, id) self:send(id, self.msg.ConnAlive, randstr3()) end

function Link.claim(self) self:sendEach(self.msg.ConnAlive, randstr3) end

------- ConnAlive Handler ----------------------------------

function Link.saw(self, id, dist)
  self.seen[id] = clock()
  self.dist[id] = dist
end

function Link.heard(self, id, dist, ks)
  self.seen[id] = clock()
  self.dist[id] = dist
  self.ksrx[id] = rc4_save(ks)
end

Link:reg({
  name = "ConnAlive",
  mode = WEP_LNK,
  min = 0,
  max = 4,
  handle = function(self, id, _, dist, ksrx) return self:heard(id, dist, ksrx) end
})

------- ConnCheck Sender -----------------------------------

function Link.check(self, id)
  if self.seen[id] then
    self.seen[id] = clock() - self.checker.checkTime
    self:send(id, self.msg.ConnCheck)
  end
end

------- ConnCheck Handler ----------------------------------

Link:reg({
  name = "ConnCheck",
  mode = WEP_LNK,
  min = 0,
  max = 0,
  handle = function(self, id, _, dist, ksrx)
    self:heard(id, dist, ksrx)
    return self:hint(id)
  end
})

------- Command Sender ------------------------------------

local function _sendCmd(self, code, ids, idss)
  local cnt = self.cmdcnt + 1
  local body = u16bes(cnt) .. code
  for _, id in ipairs(ids) do --
    self:send(id, self.msg.CmdReq, body)
  end
  self.cmdcnt = cnt
  self.cmdhist[cnt] = code
  -- self:log("req:" .. cnt .. " #" .. idss)
  return cnt
end

function Link.cmd(self, code, ids)
  if ids == nil then
    ids = utils.keys(self.seen)
  elseif type(ids) == "number" then
    ids = {ids}
  elseif type(ids) ~= "table" then
    return nil, "bad ids type"
  end
  return _sendCmd(self, code, ids, concat(ids, ","))
end

-- Remote Term
function Link.tel(self, ids)
  if ids == nil then
    ids = utils.keys(self.seen)
  elseif type(ids) == "number" then
    ids = {ids}
  elseif type(ids) ~= "table" then
    return nil, "bad ids type"
  end
  local idss = concat(ids, ",")

  local prefix = "#" .. idss .. ">"
  while true do
    local code = tui.read(prefix, nil, self.cmdhist, tui.lua_complete)
    if code == "" then break end
    _sendCmd(self, code, ids, idss)
  end
end

-- ssh toy
function Link.ssh(self, ids)
  if ids == nil then
    ids = utils.keys(self.seen)
  elseif type(ids) == "number" then
    ids = {ids}
  elseif type(ids) ~= "table" then
    return nil, "bad ids type"
  end

  for _, id in ipairs(ids) do self:watch(id) end
  self:tel(ids)
  for _, id in ipairs(ids) do self:unwatch(id) end
end

------- Command Handler -----------------------------------

local function createCmdTask(self, id, cid, code)
  return proc.create(function()
    local fn, rex = loadstring(code)
    if fn then
      ez.l = self
      local res = {pcall(setfenv(fn, ez))}
      ez.l = nil
      local ok = remove(res, 1)
      if ok then
        self:send(id, self.msg.CmdRes, u16bes(cid) .. utils.ser(res))
      else
        self:send(id, self.msg.CmdErr, u16bes(cid) .. res[1])
      end
    else
      self:send(id, self.msg.CmdBad, u16bes(cid) .. rex)
    end
  end)
end

Link:reg({
  name = "CmdReq",
  mode = WEP_LNK,
  min = 2,
  max = 0x100002,
  handle = function(self, id, body, dist, ksrx)
    local cid = besu16(sub(body, 1, 2))
    local code = sub(body, 3)
    createCmdTask(self, id, cid, code)
    -- os.queueEvent()
    self:heard(id, dist, ksrx)
    return self:send(id, self.msg.CmdAck, u16bes(cid))
  end
})

Link:reg({
  name = "CmdAck",
  mode = WEP_LNK,
  min = 2,
  max = 2,
  handle = function(self, id, body, dist, ksrx)
    local cid = besu16(body)
    self.cmdack[id] = cid
    -- os.queueEvent("link.CmdAck", self.name, id)
    self:heard(id, dist, ksrx)
    -- self:log("ack:" .. cid .. " #" .. id)
  end
})

Link:reg({
  name = "CmdRes",
  mode = WEP_LNK,
  min = 2,
  max = 0x100002,
  handle = function(self, id, body, dist, ksrx)
    local cid = besu16(sub(body, 1, 2))
    local result = sub(body, 3)
    -- os.queueEvent("link.CmdRes", self.name, cid)
    self:heard(id, dist, ksrx)
    self:log("Res:" .. cid .. " #" .. id .. " " .. result)
  end
})

Link:reg({
  name = "CmdErr",
  mode = WEP_LNK,
  min = 2,
  max = 0x100002,
  handle = function(self, id, body, dist, ksrx)
    local cid = besu16(sub(body, 1, 2))
    local result = sub(body, 3)
    os.queueEvent("link.CmdErr", self.name, cid)
    self:heard(id, dist, ksrx)
    self:log("Err:" .. cid .. " #" .. id .. " " .. result)
  end
})

Link:reg({
  name = "CmdBad",
  mode = WEP_LNK,
  min = 2,
  max = 0x100002,
  handle = function(self, id, body, dist, ksrx)
    local cid = besu16(sub(body, 1, 2))
    local result = sub(body, 3)
    os.queueEvent("link.CmdBad", self.name, cid)
    self:heard(id, dist, ksrx)
    self:log("Bad:" .. cid .. " #" .. id .. " " .. result)
  end
})

------- Log Sender ------------------------------------

function Link.log(self, ...)
  local s = concat({self.id, floor(gtime() * 10), ...}, " ")
  self.logs:write(s)
  for id in pairs(self.watcher) do self:send(id, self.msg.LogData, s) end
  if self.showlog then return tui.print(s) end
end

function Link.clearLog(self, ...)
  for _, id in ipairs({...}) do self:send(id, self.msg.LogClear) end
end

function Link.watch(self, ...)
  for _, id in ipairs({...}) do
    self.watching[id] = true
    self:send(id, self.msg.LogWatch)
  end
end

function Link.unwatch(self, ...)
  for _, id in ipairs({...}) do
    self.watching[id] = nil
    self:send(id, self.msg.LogUnwatch)
  end
end

function Link.unwatchAll(self)
  local watching = self.watching
  for id in pairs(watching) do
    watching[id] = nil
    self:send(id, self.msg.LogUnwatch)
  end
end

------- Log Handler -----------------------------------

Link:reg({
  name = "LogData",
  mode = WEP_LNK,
  min = 0,
  max = 0x10000,
  handle = function(self, id, body, dist, ksrx)
    if self.watching[id] then
      self:heard(id, dist, ksrx)
      return tui.print(body)
    end
  end
})

Link:reg({
  name = "LogClear",
  mode = WEP_LNK,
  min = 0,
  max = 0,
  handle = function(self, id, body, dist, ksrx)
    self:heard(id, dist, ksrx)
    local logs = self.logs
    for i = 1, #logs do logs[i] = "" end
  end
})

Link:reg({
  name = "LogWatch",
  mode = WEP_LNK,
  min = 0,
  max = 0,
  handle = function(self, id, _, dist, ksrx)
    self:heard(id, dist, ksrx)
    if self.watcher[id] == nil then
      self.watcher[id] = true
      return self:send(id, self.msg.LogData, concat(self.logs:sort(), "\n"))
    end
  end
})

Link:reg({
  name = "LogUnwatch",
  mode = WEP_LNK,
  min = 0,
  max = 0,
  handle = function(self, id, _, dist, ksrx)
    self:heard(id, dist, ksrx)
    self.watcher[id] = nil
  end
})

----------------- Exports ----------------------------------

local mt_Msg = {
  __tostring = function(self)
    local list = {}
    for i, v in ipairs(self) do list[i] = v.name end
    return "{" .. concat(list, ",") .. "}"
  end
}

local mt_Link = {
  __index = Link,
  __tostring = function(self) return "Link{" .. self.name .. "}" end
}

local function checker_timer(t)
  local now = clock()
  local self = t.link
  for id, time in pairs(self.seen) do
    time = now - time
    if time > t.closeTime then
      self:log("Conn Lost #" .. id)
      self:close(id)
    elseif time > t.checkTime then
      self:send(id, self.msg.ConnCheck)
    end
  end
  t:start()
end

local function finder_timer(t)
  local self = t.link
  for i, id in ipairs(t.ids) do
    if not self.seen[id] and id ~= self.id then self:connect(id) end
  end
  t:start()
end

local function fake_transmit(name) --
  return function(...) tui.print("hwS", name, ...) end
end

local function newLink(name, key, hw)
  if managed[name] then return nil, "link existed" end
  if hw == nil then
    hw = peripheral.find("modem", peripheral.wrap)
  elseif type(hw) == "string" then
    hw = peripheral.wrap(hw)
  end
  local hws
  if type(hw) == "table" then
    hws = hw.transmit
    if type(hws) ~= "function" then --
      hws = fake_transmit(name)
    end
  else
    hws = fake_transmit(name)
    hw = {fake = true}
  end
  -- create the link object
  local self = {
    -- core:hardware
    hw = hw,
    hws = hws,
    -- core:crypt
    kstx = {},
    ksrx = {},
    -- core:link
    lnrq = {},
    lnrs = {},
    -- config
    name = name,
    key = key,
    id = ID,
    onConnected = utils.asEvent({unpack(Link.onConnected)}),
    -- message
    msg = setmetatable(utils.assign({}, Link.msg), mt_Msg),
    -- peers
    peer = {}, -- `nil`:manul, `false`:block, `*`:auto accept
    seen = {},
    dist = {},
    checker = timer.start({
      ontimer = checker_timer,
      interval = 6,
      checkTime = 12,
      closeTime = 18
    }),
    finder = timer.start({ontimer = finder_timer, interval = 10, ids = {}}),
    -- logs
    logs = utils.newRing(24, ""),
    showlog = false,
    watcher = utils.asSet({}),
    watching = utils.asSet({}),
    -- command
    cmdcnt = 0,
    cmdack = {},
    cmdhist = {}
  }
  self.checker.link = self
  self.finder.link = self
  setmetatable(self, mt_Link)
  managed[name] = self
  return self
end

-- [(m*16+n):1][name:n][crypt([sum(cls,lch,rch,body):4][cls:1][body])]
local function receive()
  local lch, rch, pkg, dist, self, m, n
  while true do
    _, _, lch, rch, pkg, dist = os.pullEvent("modem_message")
    if type(pkg) == "string" then
      m = dec(pkg, 1)
      n = m % 16
      self = managed[sub(pkg, 2, n + 1)]
      if self then
        m = m - n
        n = n + 2
        break
      end
    end
    pkg = nil
  end
  local id = self.chid(rch)
  local ks
  if m == WEP_LNK then
    ks = self.ksrx[id] -- kss
    if not ks then return end
    ks = rc4_load(ks)
  elseif m == WEP_DTG then
    ks = rc4_new(self.key)
  else
    return
  end
  local ci = n + 4
  local len = #pkg - ci
  if len < 0 then return end
  local sum = rc4_crypt_substr(ks, pkg, n, n + 3)
  local cls = rc4_crypt_byte(ks, dec(pkg, ci))
  local msg = self.msg[cls]
  if not msg or m ~= msg.mode or len < msg.min or len > msg.max then return end
  local body = rc4_crypt(ks, {dec(pkg, ci + 1, #pkg)})
  if crc32n_buf(crc32n0_cww(cls, lch, rch), body) ~= sum then return end
  return msg.handle(self, id, enc(unpack(body)), dist, ks)
end

local M = {WEP_DTG = WEP_DTG, WEP_LNK = WEP_LNK, Link = Link, new = newLink, of = managed}

function M.main() while true do receive() end end

return M
