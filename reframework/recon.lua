--[[
  recon.lua -- recording triggers + metadata for SF6 Replay Bot

  Install into:  <SF6 folder>\reframework\autorun\

  What it does:
    - hooks app.battle.BattleReplayController Start/End, so recording starts
      and stops on the first and last frame of the match;
    - extracts the two players' names from app.BattleReplayDataManager
      (hook on AddReplayData), later used to rename the recorded file;
    - writes three JSON files in reframework/data/ that the watcher
      (replayobs.py) reads to drive OBS:
        obs_trigger.json    start/stop command + current replay metadata
        obs_heartbeat.json  periodic beat: if it stops, the watcher closes
                            the recording as a safety net

  Nothing to configure: all JSON paths are relative to reframework/data.
--]]

local BRDM = "app.BattleReplayDataManager"
local BRC  = "app.battle.BattleReplayController"

local function method_by_name(tn, mn)
  local td = sdk.find_type_definition(tn); if not td then return nil end
  for _, m in ipairs(td:get_methods()) do if m:get_name() == mn then return m end end
  return nil
end

local function get_str(obj, field)
  if not obj then return nil end
  local v = nil; pcall(function() v = obj:get_field(field) end)
  if v == nil then return nil end
  if type(v) == "string" then return v end
  local s = nil; pcall(function() s = v:call("ToString") end)
  if type(s) == "string" then return s end
  pcall(function() s = tostring(v) end); return s
end

local seq = 0
local meta = { id = "", p1 = "", p2 = "", c1 = 0, c2 = 0 }
local replay_active = false

local function reset_meta()
  meta = { id = "", p1 = "", p2 = "", c1 = 0, c2 = 0 }
end

local function beat()
  json.dump_file("obs_heartbeat.json", { t = os.time() })
end

local function trigger(cmd)
  seq = seq + 1
  json.dump_file("obs_trigger.json", {
    cmd = cmd, seq = seq, t = os.time(),
    id = meta.id, p1 = meta.p1, p2 = meta.p2, c1 = meta.c1, c2 = meta.c2
  })
  log.info("[rec] trigger "..cmd.." seq="..seq.." | "..meta.p1.." vs "..meta.p2.." "..meta.id)
end

local function hook(tn, mn, pre)
  local m = method_by_name(tn, mn)
  if not m then log.info("[rec] hook MISSING "..tn.."."..mn); return end
  sdk.hook(m, pre, nil); log.info("[rec] hook active "..tn.."."..mn)
end

hook(BRDM, "AddReplayData", function(args)
  pcall(function()
    local info = sdk.to_managed_object(args[5]); if not info then return end
    meta.id = get_str(info, "replay_id") or meta.id
    local p1 = info:get_field("player1_info")
    local p2 = info:get_field("player2_info")
    if p1 then meta.p1 = get_str(p1:get_field("player"), "fighter_id") or "P1"; meta.c1 = p1:get_field("playing_character_id") or 0 end
    if p2 then meta.p2 = get_str(p2:get_field("player"), "fighter_id") or "P2"; meta.c2 = p2:get_field("playing_character_id") or 0 end
    log.info("[rec] metadata: "..meta.p1.." ("..meta.c1..") vs "..meta.p2.." ("..meta.c2..") | "..meta.id)
  end)
end)

hook(BRC, "Start", function()
  replay_active = true
  beat()            -- beat immediately, before the trigger
  trigger("start")
end)

hook(BRC, "End", function()
  trigger("stop")
  replay_active = false
  reset_meta()
end)

local hb_frame = 0
re.on_frame(function()
  if not replay_active then return end
  hb_frame = hb_frame + 1
  if hb_frame % 60 == 0 then beat() end
end)

log.info("[rec] naming + heartbeat active.")
