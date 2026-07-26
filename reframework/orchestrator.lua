--[[
  orchestrator.lua -- automatic SF6 menu navigation for SF6 Replay Bot

  Install into:  <SF6 folder>\reframework\autorun\

  What it does:
    A state machine that, starting from any screen, brings the game to the
    replay-by-ID search, enters the ID, starts playback, and at the end of the
    match moves on to the next replay in the queue.

    - the queue lives in reframework/data/replay_queue.json (written by the agent);
    - screen state is read from app.UIFlowManager (name of the active flow),
      more reliable than interpreting the UI;
    - a stability gate (STABLE_NEEDED) avoids acting while the flow stack is
      being rebuilt during transitions;
    - AUTO_START = true starts the loop by itself as soon as the queue is not
      empty. A REFramework panel (re.on_draw_ui) allows manual start/stop and
      queue management.

  Nothing to configure: the queue path is relative to reframework/data.
  The internal flow names can change with SF6 patches: if navigation gets stuck
  after an update, the F_* constants at the top of the file are what to review.
--]]

-- screen flows
local F_TITLE     = "app.menu.UIFlowTitle.Param"
local F_MODESEL   = "app.UIFlowModeSelectHit.Param"
local F_STARTMENU = "app.UIStartMenu.FlowParam"
local F_CFNTOP    = "app.UICFNTop.FlowParam"
local F_MAILBOX   = "app.UIFlowMailBox.UIFlowParam"
local F_REPLAYTOP = "app.UICFNReplayTop.FlowParam"
local F_SEARCHID  = "app.UICFNReplayTopTabSearchChildSearchId.FlowParam"
local F_DIALOG    = "app.UIWidget.BaseParam_CreateByContainer"
local F_RESULT    = "app.UICFNReplaySearchResult.FlowParam"
local F_INFO      = "app.UICFNReplayInfoOnline.FlowParam"
local F_ENDMENU   = "app.esports.UIReplayResultMenu.Param"
local F_ENJOY     = "app.UIEnjoy.FlowParam"

local REQ_REPLAYID = 9
local ROW_REPLAYID = 2

local objs, lists = {}, {}
local state, state_t, last_press = "idle", os.clock(), 0
local running, started, ended = false, false, false
local current_id, tries = "", 0
local locked, calib_snap = nil, nil
local end_step, end_t, end_cycles = 1, 0, 0
local pending, manual_id = nil, ""
local last_flow, flow_since = "", os.clock()
local nav_flow, nav_step, nav_step_t = "", 0, 0

-- keyboard injection
local KEY_NAME, KEY_FLAG = "Tab", 11
local inject_frames, updateFrameCount = 0, 0

local PRESS_GAP = 0.7
local HARD_WAIT = 2.0
local STABLE_NEEDED = 1.5

local function clean_id(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s", ""):gsub("%c", "")
  if s == "" then return nil end
  return s
end

local function generate_enum(typename)
  local t = sdk.find_type_definition(typename)
  local out = {}
  if not t then return out end
  for _, f in ipairs(t:get_fields()) do
    if f:is_static() then
      local ok, v = pcall(function() return f:get_data(nil) end)
      if ok then out[v] = f:get_name() end
    end
  end
  return out
end

local keyNames = generate_enum("via.hid.KeyboardKey")

local function write_key()
  pcall(function()
    local im = sdk.get_managed_singleton("app.InputManager")
    if not im then return end
    local st = im._State;    if not st then return end
    local kb = st._Keyboard; if not kb then return end
    local keys = kb._Keys;   if not keys then return end
    for _, key in pairs(keys) do
      if key and keyNames[key.Value] == KEY_NAME then
        key.Flags = KEY_FLAG
        key.TriggerFrame = updateFrameCount
      end
    end
  end)
end

local ist = sdk.find_type_definition("app.InputState")
if ist and ist:get_method("Update") then
  sdk.hook(ist:get_method("Update"),
    function(args) pcall(function() updateFrameCount = sdk.to_int64(args[4]) end) end,
    function(retval)
      if inject_frames > 0 then
        pcall(write_key)
        inject_frames = inject_frames - 1
      end
      return retval
    end)
  log.info("[orc] keyboard injection ready")
else
  log.info("[orc] InputState.Update NOT found")
end

local kbd = sdk.find_type_definition("app.InputDeviceStateKeyboard")
if kbd and kbd:get_method("GetDigital") then
  sdk.hook(kbd:get_method("GetDigital"), nil, function(retval)
    if inject_frames > 0 and retval then
      pcall(function()
        local k = sdk.to_managed_object(retval)
        if k and keyNames[k.Value] == KEY_NAME then
          k.Flags = KEY_FLAG
          k.TriggerFrame = updateFrameCount
        end
      end)
    end
    return retval
  end)
end

re.on_pre_gui_draw_element(function(element, context)
  pcall(function()
    local go = element:call("get_GameObject")
    if go then
      local n = go:call("get_Name")
      if type(n) == "string" then objs[n] = { go = go, t = os.clock() } end
    end
  end)
  return true
end)

local function agent(n)
  local r = objs[n]
  if not r or (os.clock() - r.t) > 1.0 then return nil end
  local a = nil
  pcall(function() a = r.go:call("getComponent(System.Type)", sdk.typeof("app.UIAgent")) end)
  return a
end

local function first_agent(names)
  for _, n in ipairs(names) do
    if agent(n) then return n end
  end
  return nil
end

local function flow_items()
  local mgr = sdk.get_managed_singleton("app.UIFlowManager")
  if not mgr then return nil end
  local h = mgr:get_field("_Handles")
  return h and h:get_field("_items") or nil
end

local function top_flow()
  local items = flow_items()
  if not items or not items[0] then return "?" end
  local p = items[0]:get_field("<Param>k__BackingField")
  if not p then return "?" end
  return p:get_type_definition():get_full_name()
end

local function get_flow(name)
  local items = flow_items()
  if not items then return nil end
  for i = 0, #items - 1 do
    local v = items[i]
    if v then
      local p = v:get_field("<Param>k__BackingField")
      if p and p:get_type_definition():get_full_name() == name then return p end
    end
  end
  return nil
end

local function widget()
  local f = get_flow(F_SEARCHID)
  if not f then return nil end
  return f:get_field("<TextInputDialogWidget>k__BackingField")
end

local function request_type()
  local w = widget()
  if not w then return nil end
  local rt = nil
  pcall(function() rt = w:get_field("CurrentRequestType") end)
  return rt
end

local std = sdk.find_type_definition("app.UIPartsScrollList")
if std then
  for _, m in ipairs(std:get_methods()) do
    if m:get_name() == "get_SelectedIndex" then
      pcall(function()
        sdk.hook(m, function(args)
          pcall(function()
            local o = sdk.to_managed_object(args[2])
            if o then lists[string.format("%X", o:get_address())] = { obj = o, t = os.clock() } end
          end)
        end, nil)
      end)
    end
  end
end

local function idx_of(o)
  local v = nil
  pcall(function() v = o:call("get_SelectedIndex") end)
  return v
end

local function candidates()
  local out = {}
  if top_flow() ~= F_SEARCHID then return out end
  local now = os.clock()
  for k, r in pairs(lists) do
    if now - r.t < 1.0 then
      local im = nil
      pcall(function() im = r.obj:call("get_ItemMax") end)
      if im == 3 then out[k] = r.obj end
    else
      lists[k] = nil
    end
  end
  return out
end

local function n_candidates()
  local n = 0; for _ in pairs(candidates()) do n = n + 1 end; return n
end

local function row_index()
  if not locked then return nil end
  return idx_of(locked)
end

local function load_queue()
  local q = nil
  pcall(function() q = json.load_file("replay_queue.json") end)
  local out = {}
  if type(q) == "table" and type(q.ids) == "table" then
    for _, v in ipairs(q.ids) do
      local c = clean_id(v)
      if c then out[#out+1] = c end
    end
  end
  return out
end

local function save_queue(ids)
  pcall(function() json.dump_file("replay_queue.json", { ids = ids }) end)
end

local function press(target, method)
  if not target then return false end
  if os.clock() - last_press < PRESS_GAP then return false end
  last_press = os.clock()
  pending = function()
    local a = agent(target)
    if not a then log.info("[orc] no agent on "..target); return end
    pcall(function() a:call(method, 2) end)
  end
  return true
end

local function press_key()
  if os.clock() - last_press < PRESS_GAP then return false end
  last_press = os.clock()
  inject_frames = 3
  log.info("[orc] injected "..KEY_NAME)
  return true
end

local function send_id(id)
  pending = function()
    local w = widget()
    if not w then log.info("[orc] widget missing"); return end
    local ok, err = pcall(function() w:call("InvokeResultEvent", id) end)
    log.info("[orc] InvokeResultEvent "..id..": "..(ok and "ok" or tostring(err)))
  end
end

re.on_pre_application_entry("UpdateBehavior", function()
  if not pending then return end
  local job = pending; pending = nil
  pcall(job)
end)

local function hook_ctrl(name, fn)
  local td = sdk.find_type_definition("app.battle.BattleReplayController")
  if not td then return end
  for _, m in ipairs(td:get_methods()) do
    if m:get_name() == name then
      pcall(function() sdk.hook(m, function() fn() end, nil) end)
      return
    end
  end
end
hook_ctrl("Start", function() started = true end)
hook_ctrl("End",   function() ended = true end)

local function goto_state(s)
  state, state_t = s, os.clock()
  log.info("[orc] -> "..s.."   flow="..top_flow())
end

local function is_browser(top)
  return top == F_SEARCHID or top == F_RESULT or top == F_REPLAYTOP or top == F_CFNTOP
end

-- fixed sequences: right N times, then confirm
local function nav_sequence(target, rights)
  if nav_step < rights then
    if press(target, "InputRight") then nav_step = nav_step + 1; nav_step_t = os.clock() end
  elseif nav_step == rights then
    if press(target, "InputDecide") then nav_step = nav_step + 1; nav_step_t = os.clock() end
  elseif os.clock() - nav_step_t > 4.0 then
    log.info("[orc] sequence had no effect, retrying")
    nav_step = 0
  end
end

local function tick()
  if not running then return end
  local top = top_flow()
  local elapsed = os.clock() - state_t

  if top ~= last_flow then last_flow = top; flow_since = os.clock() end
  local stable = os.clock() - flow_since

  if top ~= nav_flow then nav_flow = top; nav_step = 0; nav_step_t = os.clock() end

  local limit = 25.0
  if state == "nav" then limit = 180.0 end
  if state == "watch" then limit = 600.0 end
  if state == "waitend" then limit = 180.0 end
  if state == "endmenu" then limit = 90.0 end
  if state == "hardwait" then limit = 999.0 end
  if state == "waitresult" then limit = 40.0 end

  if state ~= "idle" and elapsed > limit then
    log.info("[orc] TIMEOUT in "..state)
    running = false; goto_state("idle"); return
  end

  if state == "idle" then
    if #load_queue() > 0 then
      tries = 0; locked, calib_snap = nil, nil
      nav_step = 0
      goto_state("nav")
    end

  -- bring the game to the search screen from anywhere
  elseif state == "nav" then
    if stable < STABLE_NEEDED then return end

    if top == F_SEARCHID then
      locked, calib_snap = nil, nil
      goto_state("calib")

    elseif top == F_TITLE then
      press_key()

    elseif top == F_MODESEL then
      press_key()

    elseif top == F_STARTMENU then
      nav_sequence("StartMenuUI", 1)

    elseif top == F_CFNTOP then
      nav_sequence("CFNTop", 2)

    elseif top == F_MAILBOX then
      press(first_agent({ "MailBox", "StartMenuUI" }), "InputCancel")

    elseif top == F_DIALOG then
      press("TextInputDialogBH", "InputCancel")

    elseif top == F_RESULT then
      press(first_agent({ "CFNReplayChildSearchResult", "CFNReplayChildSearch", "CFNReplayTop" }), "InputCancel")

    elseif top == F_INFO then
      press(first_agent({ "CFNReplayInfo", "CFNReplayChildSearchResult", "CFNReplayTop" }), "InputCancel")

    elseif agent("CFNReplayChildSearch") then
      press("CFNReplayChildSearch", "InputChildTabNext")

    elseif agent("CFNReplayTop") then
      press("CFNReplayTop", "InputTabNext")
    end

  elseif state == "calib" then
    if top ~= F_SEARCHID then goto_state("nav")
    elseif locked then goto_state("row")
    elseif n_candidates() == 0 then return
    elseif not calib_snap then
      calib_snap = {}
      for k, o in pairs(candidates()) do calib_snap[k] = idx_of(o) end
      press("CFNSearchItemList", "InputDown")
    else
      for k, o in pairs(candidates()) do
        local b, n2 = calib_snap[k], idx_of(o)
        if b ~= nil and n2 ~= nil and n2 ~= b and n2 == (b + 1) % 3 then
          locked = o; log.info("[orc] list locked: "..k); break
        end
      end
      if not locked and elapsed > 4.0 then calib_snap = nil end
    end

  elseif state == "row" then
    if top ~= F_SEARCHID then goto_state("nav")
    else
      local i = row_index()
      if i == ROW_REPLAYID then goto_state("open")
      elseif i ~= nil then press("CFNSearchItemList", "InputDown")
      else locked, calib_snap = nil, nil; goto_state("calib") end
    end

  elseif state == "open" then
    if top == F_DIALOG then goto_state("check")
    elseif top ~= F_SEARCHID then goto_state("nav")
    elseif row_index() ~= ROW_REPLAYID then goto_state("row")
    else press("CFNSearchItemList", "InputDecide") end

  elseif state == "check" then
    local rt = request_type()
    if rt == REQ_REPLAYID then
      local ids = load_queue()
      current_id = ids[1]
      if not current_id then running = false; goto_state("idle"); return end
      table.remove(ids, 1)
      save_queue(ids)
      log.info("[orc] sending "..current_id)
      send_id(current_id)
      goto_state("closedlg")
    elseif rt ~= nil then
      tries = tries + 1
      if tries > 4 then running = false; goto_state("idle"); return end
      log.info("[orc] wrong dialog (RequestType="..tostring(rt)..")")
      press("TextInputDialogBH", "InputCancel")
      locked, calib_snap = nil, nil
      goto_state("calib")
    end

  elseif state == "closedlg" then
    if elapsed > 1.0 then
      press("TextInputDialogBH", "InputCancel")
      goto_state("waitresult")
    end

  elseif state == "waitresult" then
    if top == F_RESULT then goto_state("detail")
    elseif top == F_DIALOG and elapsed > 4.0 then press("TextInputDialogBH", "InputCancel") end

  elseif state == "detail" then
    if started then started, ended = false, false; goto_state("watch")
    elseif top == F_INFO then goto_state("play")
    elseif stable < STABLE_NEEDED then return
    elseif top == F_RESULT then press("CFNReplayChildSearchResult", "InputDecide") end

  elseif state == "play" then
    if started then started, ended = false, false; goto_state("watch")
    elseif stable < STABLE_NEEDED then return
    elseif top == F_INFO then press("CFNReplayInfo", "InputDecide") end

  elseif state == "watch" then
    if ended then
      ended = false
      end_step, end_t, end_cycles = 1, 0, 0
      goto_state("waitend")
    end

  elseif state == "waitend" then
    if top == F_ENDMENU or top == F_ENJOY then
      end_step, end_t, end_cycles = 1, 0, 0
      goto_state("endmenu")
    end

  elseif state == "endmenu" then
    if is_browser(top) and stable > STABLE_NEEDED then goto_state("hardwait")
    elseif not is_browser(top) then
      if end_step == 1 then
        if press("ReplayResultMenu", "InputDown") then end_step = 2; end_t = os.clock() end
      elseif end_step == 2 and os.clock() - end_t > 1.2 then
        if press("ReplayResultMenu", "InputDecide") then end_step = 3; end_t = os.clock() end
      elseif end_step == 3 and os.clock() - end_t > 5.0 then
        end_cycles = end_cycles + 1
        if end_cycles >= 2 then press("ReplayResultMenu", "InputCancel"); end_t = os.clock() end
        end_step = 1
      end
    end

  elseif state == "hardwait" then
    if elapsed > HARD_WAIT and stable > STABLE_NEEDED then
      if #load_queue() > 0 then
        tries = 0; locked, calib_snap = nil, nil
        nav_step = 0
        goto_state("nav")
      else running = false; goto_state("idle") end
    end
  end
end

local AUTO_START = true
local f, last_check = 0, 0

re.on_frame(function()
  f = f + 1
  if f % 10 ~= 0 then return end

  -- auto-start when the queue is not empty
  if AUTO_START and not running and os.clock() - last_check > 2.0 then
    last_check = os.clock()
    if #load_queue() > 0 then
      running = true
      tries = 0; locked, calib_snap = nil, nil; nav_step = 0
      goto_state("idle")
      log.info("[orc] auto-start: queue not empty")
    end
  end

  pcall(tick)
end)

re.on_draw_ui(function()
  if imgui.tree_node("Orchestrator") then
    local ids = load_queue()
    imgui.text("state: "..state.."   queue: "..#ids)
    imgui.text("flow: "..top_flow())
    imgui.text(string.format("stable for: %.1fs   nav step: %d", os.clock() - flow_since, nav_step))
    imgui.text("lists: "..n_candidates().."   row: "..tostring(row_index()))
    imgui.text("RequestType: "..tostring(request_type()))
    for i, v in ipairs(ids) do imgui.text("  "..i..". "..v) end
    local c, v = imgui.input_text("Add ID", manual_id)
    if c then manual_id = v end
    if imgui.button("Add to queue") then
      local cid = clean_id(manual_id)
      if cid then ids[#ids+1] = cid; save_queue(ids); manual_id = "" end
    end
    if imgui.button("Clear queue") then save_queue({}) end
    if imgui.button(running and "STOP" or "START") then
      running = not running
      if running then tries = 0; locked, calib_snap = nil, nil; nav_step = 0; goto_state("idle") end
    end
    imgui.tree_pop()
  end
end)
