local obs = obslua
local MAX_AUDIO_MIXES = 6
local UI_MAX_SECONDS = 3600
local DEFAULT_DURATIONS = { 30, 60, 120 }
local BUFFER_IDS = {1, 2, 3}
local LOCALE_NAME = "Partial Replay"
local SYNC_TOLERANCE_MS = 100
local SAFETY_TIMEOUT_MS = 30000
local START_RETRY_AFTER_MS = 3000
local START_MAX_ATTEMPTS = 2
local FILE_STABLE_TICKS = 5
local FINALIZE_TIMEOUT_MS = 15000
local default_loc = nil
local current_loc = nil
local enabled = false
local effective_enabled = false
local reset_enabled = false
local durations = {DEFAULT_DURATIONS[1], DEFAULT_DURATIONS[2], DEFAULT_DURATIONS[3]}
local main_limit = nil
local outputs = {}
local output_signals = {}
local pending_saves = {}
local pending_restarts = {}
local event_callback = nil
local signals_available = false
local start_output_by_id = nil
local handle_saved_finalized = nil
local begin_main_reset = nil
local reset_buffer_ids = nil
local get_main_limit = nil
local hotkey_ids = {}
local shared_memory_queue = {}
local shared_memory_queue_max = 1000
local finalize_queue = {}
local buffer_start_time = {}
local main_buffer_start_time = nil
local T_save_request = {}
local child_deactivated = {}
local child_saved_queue = {}
local main_output_ref = nil
local main_signals = nil
local main_stop_seen = false
local main_deactivate_seen = false
local main_start_seen = false
local main_activate_seen = false
local reset_state = "idle"
local state_entered_at = 0
local start_attempts = 0
local last_start_attempt_at = 0
local ffi = require("ffi")
local BRIDGE_NAME = "Local\\OBS_SFO_Bridge_v1"
local BRIDGE_HEADER = 8
local BRIDGE_SLOT = 1024
local BRIDGE_SLOTS = 128
local BRIDGE_TOTAL = BRIDGE_HEADER + BRIDGE_SLOT * BRIDGE_SLOTS
local NOTIFY_NAME = "Local\\OBS_PR_Notify_v1"
local NOTIFY_HEADER = 8
local NOTIFY_SLOT = 1024
local NOTIFY_SLOTS = 128
local NOTIFY_TOTAL = NOTIFY_HEADER + NOTIFY_SLOT * NOTIFY_SLOTS
local NOTIFY_PAYLOAD_MAX = NOTIFY_SLOT - 8
local PR_STATUS_NAME = "Local\\OBS_PR_Status_v1"
local PR_STATUS_SIZE = 16
local TR_STATUS_NAME = "Local\\OBS_TR_Status_v1"
local TR_STATUS_SIZE = 16

ffi.cdef[[
    typedef void* HANDLE;
    typedef unsigned long DWORD;
    typedef int BOOL;
    typedef const unsigned short* LPCWSTR;
    typedef size_t SIZE_T;
    HANDLE CreateFileMappingW(HANDLE, void*, DWORD, DWORD, DWORD, LPCWSTR);
    HANDLE OpenFileMappingW(DWORD, BOOL, LPCWSTR);
    void* MapViewOfFile(HANDLE, DWORD, DWORD, DWORD, SIZE_T);
    BOOL UnmapViewOfFile(void*);
    BOOL CloseHandle(HANDLE);
]]

local kernel32 = ffi.load("kernel32")
local bridge_handle, bridge_view, bridge_hdr = nil, nil, nil
local notify_handle, notify_view, notify_hdr = nil, nil, nil
local pr_status_handle, pr_status_view, pr_status_hdr = nil, nil, nil

local function bridge_wide(s)
    local b = ffi.new("unsigned short[?]", #s + 1)
    for i = 1, #s do b[i-1] = s:byte(i) end
    b[#s] = 0
    return b
end

local function bridge_open()
    if bridge_view then return true end
    bridge_handle = kernel32.CreateFileMappingW(ffi.cast("HANDLE", -1), nil, 0x04, 0, BRIDGE_TOTAL, bridge_wide(BRIDGE_NAME))
    if bridge_handle == nil or bridge_handle == ffi.cast("HANDLE", 0) then return false end
    bridge_view = kernel32.MapViewOfFile(bridge_handle, 0x000F001F, 0, 0, BRIDGE_TOTAL)
    if bridge_view == nil then
        kernel32.CloseHandle(bridge_handle); bridge_handle = nil; return false
    end
    bridge_hdr = ffi.cast("unsigned int*", bridge_view)
    return true
end

local function bridge_close()
    if bridge_view then kernel32.UnmapViewOfFile(bridge_view); bridge_view = nil end
    if bridge_handle then kernel32.CloseHandle(bridge_handle); bridge_handle = nil end
    bridge_hdr = nil
end

local function bridge_write(path)
    if not bridge_view or not bridge_hdr then return false end
    local len = #path
    if len == 0 or len > BRIDGE_SLOT - 4 then return false end
    local ws, rs = bridge_hdr[0], bridge_hdr[1]
    if ws - rs >= BRIDGE_SLOTS then return false end
    local idx = ws % BRIDGE_SLOTS
    local slot = ffi.cast("unsigned char*", bridge_view) + BRIDGE_HEADER + idx * BRIDGE_SLOT
    ffi.cast("unsigned int*", slot)[0] = len
    ffi.copy(slot + 4, path, len)
    bridge_hdr[0] = ws + 1
    return true
end

local function notify_open()
    if notify_view then return true end
    notify_handle = kernel32.CreateFileMappingW(ffi.cast("HANDLE", -1), nil, 0x04, 0, NOTIFY_TOTAL, bridge_wide(NOTIFY_NAME))
    if notify_handle == nil or notify_handle == ffi.cast("HANDLE", 0) then
        notify_handle = nil; return false
    end
    notify_view = kernel32.MapViewOfFile(notify_handle, 0x000F001F, 0, 0, NOTIFY_TOTAL)
    if notify_view == nil then
        kernel32.CloseHandle(notify_handle); notify_handle = nil; return false
    end
    notify_hdr = ffi.cast("unsigned int*", notify_view)
    return true
end

local function notify_close()
    if notify_view then kernel32.UnmapViewOfFile(notify_view); notify_view = nil end
    if notify_handle then kernel32.CloseHandle(notify_handle); notify_handle = nil end
    notify_hdr = nil
end

local function notify_write(path, duration_sec)
    if not notify_view or not notify_hdr then return end
    path = tostring(path or "")
    duration_sec = tonumber(duration_sec) or 0
    local plen = #path
    if plen == 0 or plen > NOTIFY_PAYLOAD_MAX then return end
    local ws = notify_hdr[0]
    local idx = ws % NOTIFY_SLOTS
    local slot = ffi.cast("unsigned char*", notify_view) + NOTIFY_HEADER + idx * NOTIFY_SLOT
    ffi.cast("unsigned int*", slot)[0] = math.floor(duration_sec)
    ffi.cast("unsigned int*", slot + 4)[0] = plen
    ffi.copy(slot + 8, path, plen)
    notify_hdr[0] = ws + 1
end

local function pr_status_open()
    if pr_status_view then return true end
    pr_status_handle = kernel32.CreateFileMappingW(ffi.cast("HANDLE", -1), nil, 0x04, 0, PR_STATUS_SIZE, bridge_wide(PR_STATUS_NAME))
    if pr_status_handle == nil or pr_status_handle == ffi.cast("HANDLE", 0) then
        pr_status_handle = nil; return false
    end
    pr_status_view = kernel32.MapViewOfFile(pr_status_handle, 0x000F001F, 0, 0, PR_STATUS_SIZE)
    if pr_status_view == nil then
        kernel32.CloseHandle(pr_status_handle); pr_status_handle = nil; return false
    end
    pr_status_hdr = ffi.cast("unsigned int*", pr_status_view)
    pr_status_hdr[0] = 1
    pr_status_hdr[1] = enabled and 1 or 0
    pr_status_hdr[2] = 0
    pr_status_hdr[3] = 0
    return true
end

local function pr_status_update()
    if not pr_status_hdr then return end
    pr_status_hdr[1] = enabled and 1 or 0
    pr_status_hdr[2] = effective_enabled and 1 or 0
    pr_status_hdr[3] = reset_enabled and 1 or 0
end

local function pr_status_close()
    if pr_status_view then kernel32.UnmapViewOfFile(pr_status_view); pr_status_view = nil end
    if pr_status_handle then kernel32.CloseHandle(pr_status_handle); pr_status_handle = nil end
    pr_status_hdr = nil
end

local function tr_status_read()
    local h = kernel32.OpenFileMappingW(0x0004, 0, bridge_wide(TR_STATUS_NAME))
    if h == nil or h == ffi.cast("HANDLE", 0) then
        return {live = false, enabled = false, effective = false, dangerous = false}
    end
    local v = kernel32.MapViewOfFile(h, 0x0004, 0, 0, TR_STATUS_SIZE)
    if v == nil then
        kernel32.CloseHandle(h)
        return {live = false, enabled = false, effective = false, dangerous = false}
    end
    local hdr = ffi.cast("unsigned int*", v)
    local version = tonumber(hdr[0])
    local en = tonumber(hdr[1])
    local eff = tonumber(hdr[2])
    local dangerous = tonumber(hdr[3])
    kernel32.UnmapViewOfFile(v)
    kernel32.CloseHandle(h)
    if version ~= 1 then
        return {live = false, enabled = false, effective = false, dangerous = false}
    end
    return {live = true, enabled = en == 1, effective = eff == 1, dangerous = dangerous == 1}
end

local function now_ms()
    if obs.os_gettime_ns then
        local v = tonumber(obs.os_gettime_ns())
        if v then return v / 1000000 end
    end
    return os.time() * 1000
end

local function get_file_size(path)
    if not path or path == "" then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

local function get_last_replay_path(output)
    if not output then return nil end
    local ok, path = pcall(function()
        local ph = obs.obs_output_get_proc_handler(output)
        if not ph then return nil end
        local cd = obs.calldata_create()
        if not cd then return nil end
        local call_ok = obs.proc_handler_call(ph, "get_last_replay", cd)
        local value = call_ok and obs.calldata_string(cd, "path") or nil
        obs.calldata_destroy(cd)
        return value
    end)
    return ok and path or nil
end

local function init_locale()
    if default_loc then return end
    local dir = script_path():match("(.*[/\\])") or ""
    local loc_dir = dir .. "locale/"
    local lang = "en-US"
    if obs.obs_get_locale then lang = obs.obs_get_locale() or lang end
    default_loc = obs.obs_data_create_from_json_file(loc_dir .. "en-US " .. LOCALE_NAME .. ".json")
    current_loc = obs.obs_data_create_from_json_file(loc_dir .. lang .. " " .. LOCALE_NAME .. ".json")
        or obs.obs_data_create_from_json_file(loc_dir .. tostring(lang):sub(1, 2) .. " " .. LOCALE_NAME .. ".json")
end

local function getString(key)
    local value = current_loc and obs.obs_data_get_string(current_loc, key) or ""
    if value == "" and default_loc then value = obs.obs_data_get_string(default_loc, key) end
    return value ~= "" and value or key
end

local function tr(key, ...)
    init_locale()
    local value = getString(key)
    if select("#", ...) > 0 then return string.format(value, ...) end
    return value
end

local function get_main_output() return obs.obs_frontend_get_replay_buffer_output() end
local function frontend_active()
    return obs.obs_frontend_replay_buffer_active and obs.obs_frontend_replay_buffer_active() or false
end
local function main_is_active() return frontend_active() end

local function child_is_active(id)
    local o = outputs[id]
    if not o then return false end
    local ok, a = pcall(obs.obs_output_active, o)
    return ok and a == true
end

local function all_children_deactivated()
    for _, id in ipairs(BUFFER_IDS) do
        if not child_deactivated[id] then return false end
    end
    return true
end

local function unsubscribe_main()
    if not main_signals then return end
    local h = main_signals.handler
    if obs.signal_handler_disconnect and h then
        pcall(obs.signal_handler_disconnect, h, "stop", main_signals.stop_cb)
        pcall(obs.signal_handler_disconnect, h, "start", main_signals.start_cb)
        pcall(obs.signal_handler_disconnect, h, "activate", main_signals.activate_cb)
        pcall(obs.signal_handler_disconnect, h, "deactivate", main_signals.deactivate_cb)
    end
    main_signals = nil
    if main_output_ref then obs.obs_output_release(main_output_ref); main_output_ref = nil end
end

local function subscribe_main()
    unsubscribe_main()
    local m = get_main_output()
    if not m then return false end
    local handler = obs.obs_output_get_signal_handler(m)
    if not handler then obs.obs_output_release(m); return false end
    local stop_cb = function() main_stop_seen = true end
    local start_cb = function() main_start_seen = true end
    local activate_cb = function() main_activate_seen = true end
    local deactivate_cb = function() main_deactivate_seen = true end
    obs.signal_handler_connect(handler, "stop", stop_cb)
    obs.signal_handler_connect(handler, "start", start_cb)
    obs.signal_handler_connect(handler, "activate", activate_cb)
    obs.signal_handler_connect(handler, "deactivate", deactivate_cb)
    main_output_ref = m
    main_signals = {handler=handler, stop_cb=stop_cb, start_cb=start_cb, activate_cb=activate_cb, deactivate_cb=deactivate_cb}
    return true
end

local function reset_flags_before_stop()
    main_stop_seen = false; main_deactivate_seen = false
    main_start_seen = false; main_activate_seen = false
end

local function reset_flags_before_start()
    main_start_seen = false; main_activate_seen = false
end

local function set_reset_state(s, reason)
    if reset_state == s then return end
    reset_state = s
    state_entered_at = now_ms()
end

local function try_call_start(now)
    reset_flags_before_start()
    start_attempts = start_attempts + 1
    last_start_attempt_at = now
    obs.obs_frontend_replay_buffer_start()
end

local function enqueue_finalize(id, path, duration, T_save)
    finalize_queue[#finalize_queue + 1] = {id = id, path = path, duration = duration or 0, T_save = T_save, last_size = -1, stable_ticks = 0, deadline = now_ms() + FINALIZE_TIMEOUT_MS}
end

local function push_shared_memory(path, duration)
    if path and path ~= "" then
        shared_memory_queue[#shared_memory_queue + 1] = {path = path, duration = duration or 0}
        if #shared_memory_queue > shared_memory_queue_max then
            table.remove(shared_memory_queue, 1)
        end
    end
end

local function finalize_and_handle(entry)
    if entry.id ~= "main" then
        pending_saves[entry.id] = nil
    end
    local notify_duration = (entry.id == "main") and 0 or (entry.duration or 0)
    push_shared_memory(entry.path, notify_duration)
    handle_saved_finalized(entry.id, entry.T_save, entry.duration, entry.path)
end

local function tick_finalize_queue()
    if #finalize_queue == 0 then return end
    local now = now_ms()
    local remaining = {}
    for _, entry in ipairs(finalize_queue) do
        local expired = entry.deadline and now >= entry.deadline
        local size = get_file_size(entry.path)
        if size == nil then
            if expired then
                if entry.id ~= "main" then pending_saves[entry.id] = nil end
                handle_saved_finalized(entry.id, entry.T_save, entry.duration, nil)
            else
                remaining[#remaining + 1] = entry
            end
        else
            if size == entry.last_size then
                entry.stable_ticks = entry.stable_ticks + 1
            else
                entry.last_size = size
                entry.stable_ticks = 0
            end
            if entry.stable_ticks >= FILE_STABLE_TICKS or expired then
                finalize_and_handle(entry)
            else
                remaining[#remaining + 1] = entry
            end
        end
    end
    finalize_queue = remaining
end

local function on_output_saved(id)
    child_saved_queue[#child_saved_queue + 1] = id
end

local function connect_output_signals(id, output)
    if not signals_available or output_signals[id] then return end
    local handler = obs.obs_output_get_signal_handler(output)
    if not handler then return end
    local saved_cb = function() on_output_saved(id) end
    local stop_cb = function() end
    local deactivate_cb = function()
        child_deactivated[id] = true
    end
    obs.signal_handler_connect(handler, "saved", saved_cb)
    obs.signal_handler_connect(handler, "stop", stop_cb)
    obs.signal_handler_connect(handler, "deactivate", deactivate_cb)
    output_signals[id] = {handler=handler, saved=saved_cb, stop=stop_cb, deactivate=deactivate_cb}
end

local function disconnect_output_signals(id)
    local info = output_signals[id]
    if not info then return end
    if obs.signal_handler_disconnect then
        obs.signal_handler_disconnect(info.handler, "saved", info.saved)
        if info.stop then obs.signal_handler_disconnect(info.handler, "stop", info.stop) end
        if info.deactivate then obs.signal_handler_disconnect(info.handler, "deactivate", info.deactivate) end
    end
    output_signals[id] = nil
end

local function get_duration(id) return durations[id] or 0 end
local function buffer_label(id) return tr("AutoGroupName") end
local function get_output(id) return outputs[id] end

local function should_start(id, limit)
    if not effective_enabled then return false end
    local d = durations[id] or 0
    if d <= 0 then return false end
    if limit and limit > 0 and d >= limit then return false end
    return true
end

local function normalize_duration(v)
    v = tonumber(v) or 0
    v = math.floor(v + 0.5)
    if v < 0 then v = 0 end
    return v
end

local function read_settings(settings)
    if not settings then return end
    enabled = obs.obs_data_get_bool(settings, "enabled")
    reset_enabled = obs.obs_data_get_bool(settings, "reset_after_save")
    for slot = 1, 3 do
        durations[slot] = normalize_duration(obs.obs_data_get_int(settings, "clip" .. slot .. "_seconds"))
    end
    main_limit = get_main_limit()
end

local function build_output_settings(main_settings, id)
    local duration = get_duration(id)
    if duration <= 0 then return nil end
    local settings = obs.obs_data_create()
    local format = obs.obs_data_get_string(main_settings, "format")
    if not format or format == "" then format = "%CCYY-%MM-%DD %hh-%mm-%ss" end
    format = format .. "_" .. tostring(duration) .. "s"
    local extension = obs.obs_data_get_string(main_settings, "extension")
    if not extension or extension == "" then extension = "mp4" end
    obs.obs_data_set_string(settings, "directory", obs.obs_data_get_string(main_settings, "directory") or "")
    obs.obs_data_set_string(settings, "format", format)
    obs.obs_data_set_string(settings, "extension", extension)
    obs.obs_data_set_bool(settings, "allow_spaces", obs.obs_data_get_bool(main_settings, "allow_spaces"))
    obs.obs_data_set_string(settings, "muxer_settings", obs.obs_data_get_string(main_settings, "muxer_settings") or "")
    obs.obs_data_set_int(settings, "max_time_sec", duration)
    obs.obs_data_set_int(settings, "max_size_mb", 0)
    return settings
end

local function apply_main_limit(limit)
    main_limit = limit
    for slot = 1, 3 do
        if hotkey_ids[slot] then
            obs.obs_hotkey_set_description(hotkey_ids[slot], tr("HotkeySave", slot, (durations[slot] > 0 and (not limit or durations[slot] < limit)) and tr("SecondsFormat", durations[slot]) or tr("Disabled")))
        end
    end
end

local function start_single_output(id, ctx, force_restart)
    local output = get_output(id)
    if not should_start(id, ctx.limit) then
        pending_saves[id] = nil
        pending_restarts[id] = nil
        if output and obs.obs_output_active(output) then
            buffer_start_time[id] = nil
            obs.obs_output_force_stop(output)
        end
        return true
    end
    if not output then
        output = obs.obs_output_create("replay_buffer", buffer_label(id), nil, nil)
        if output then
            outputs[id] = output
            connect_output_signals(id, output)
        else
            pending_restarts[id] = true
            return false
        end
    end
    connect_output_signals(id, output)
    if obs.obs_output_active(output) and force_restart then
        pending_restarts[id] = true
        buffer_start_time[id] = nil
        obs.obs_output_force_stop(output)
        return false
    end
    if obs.obs_output_active(output) and not force_restart then
        local active_settings = obs.obs_output_get_settings(output)
        local active_duration = active_settings and obs.obs_data_get_int(active_settings, "max_time_sec") or 0
        if active_settings then obs.obs_data_release(active_settings) end
        if active_duration ~= get_duration(id) then
            pending_saves[id] = nil
            pending_restarts[id] = true
            buffer_start_time[id] = nil
            obs.obs_output_force_stop(output)
            return true
        end
        pending_restarts[id] = nil
        return true
    end
    local output_settings = build_output_settings(ctx.main_settings, id)
    if not output_settings then return true end
    obs.obs_output_update(output, output_settings)
    obs.obs_data_release(output_settings)
    obs.obs_output_set_video_encoder(output, ctx.main_video)
    for index = 0, MAX_AUDIO_MIXES - 1 do
        if ctx.main_audio[index] then
            obs.obs_output_set_audio_encoder(output, ctx.main_audio[index], index)
        end
    end
    if obs.obs_output_start(output) then
        pending_restarts[id] = nil
        buffer_start_time[id] = now_ms()
        child_deactivated[id] = false
        return true
    end
    pending_restarts[id] = true
    buffer_start_time[id] = nil
    return false
end

local function start_outputs(force_restart)
    if force_restart == nil then force_restart = false end
    if not effective_enabled or not frontend_active() then return false end
    local main = get_main_output()
    if not main then return false end
    local main_settings = obs.obs_output_get_settings(main)
    if not main_settings then obs.obs_output_release(main); return false end
    local main_video = obs.obs_output_get_video_encoder(main)
    if not main_video then
        obs.obs_data_release(main_settings)
        obs.obs_output_release(main)
        return false
    end
    local main_audio = {}
    for index = 0, MAX_AUDIO_MIXES - 1 do
        main_audio[index] = obs.obs_output_get_audio_encoder(main, index)
    end
    local limit = obs.obs_data_get_int(main_settings, "max_time_sec") or 0
    if limit <= 0 then limit = nil end
    apply_main_limit(limit)
    local ctx = {main_settings=main_settings, main_video=main_video, main_audio=main_audio, limit=limit}
    for _, id in ipairs(BUFFER_IDS) do start_single_output(id, ctx, force_restart) end
    obs.obs_data_release(main_settings)
    obs.obs_output_release(main)
    return true
end

start_output_by_id = function(id, force_restart)
    if not effective_enabled or not frontend_active() then return false end
    local main = get_main_output()
    if not main then return false end
    local main_settings = obs.obs_output_get_settings(main)
    if not main_settings then obs.obs_output_release(main); return false end
    local main_video = obs.obs_output_get_video_encoder(main)
    if not main_video then
        obs.obs_data_release(main_settings)
        obs.obs_output_release(main)
        return false
    end
    local main_audio = {}
    for index = 0, MAX_AUDIO_MIXES - 1 do
        main_audio[index] = obs.obs_output_get_audio_encoder(main, index)
    end
    local limit = obs.obs_data_get_int(main_settings, "max_time_sec") or 0
    if limit <= 0 then limit = nil end
    apply_main_limit(limit)
    local ctx = {main_settings=main_settings, main_video=main_video, main_audio=main_audio, limit=limit}
    local result = start_single_output(id, ctx, force_restart)
    obs.obs_data_release(main_settings)
    obs.obs_output_release(main)
    return result
end

get_main_limit = function()
    local active = frontend_active()
    local output_limit, output_known = nil, false
    local main = get_main_output()
    if main then
        local settings = obs.obs_output_get_settings(main)
        if settings then
            output_known = true
            local limit = obs.obs_data_get_int(settings, "max_time_sec")
            if limit and limit > 0 then output_limit = limit end
            obs.obs_data_release(settings)
        end
        obs.obs_output_release(main)
    end
    if active and output_known then return output_limit end
    if obs.obs_frontend_get_profile_config and obs.config_get_int then
        local config = obs.obs_frontend_get_profile_config()
        if config then
            local mode = ""
            if obs.config_get_string then
                mode = obs.config_get_string(config, "Output", "Mode") or ""
            end
            local sections = {}
            if tostring(mode):lower() == "advanced" then table.insert(sections, "AdvOut") end
            table.insert(sections, "SimpleOutput")
            table.insert(sections, "AdvOut")
            for _, section in ipairs(sections) do
                local sec = obs.config_get_int(config, section, "RecRBTime")
                if sec and sec > 0 then return sec end
            end
        end
    end
    return output_limit
end

begin_main_reset = function()
    if not effective_enabled then return end
    if not reset_enabled then return end
    if reset_state ~= "idle" then return end
    subscribe_main()
    reset_flags_before_stop()
    start_attempts = 0
    child_deactivated = {}
    for _, id in ipairs(BUFFER_IDS) do
        local o = outputs[id]
        if o and obs.obs_output_active(o) then
            pending_restarts[id] = true
            buffer_start_time[id] = nil
            child_deactivated[id] = false
            obs.obs_output_force_stop(o)
        else
            child_deactivated[id] = true
            buffer_start_time[id] = nil
        end
    end
    set_reset_state("stopping_children", "begin_main_reset")
end

reset_buffer_ids = function(ids)
    if reset_state ~= "idle" then return end
    for _, id in ipairs(ids) do
        local output = get_output(id)
        if output and obs.obs_output_active(output) and not pending_saves[id] then
            pending_restarts[id] = true
            buffer_start_time[id] = nil
            obs.obs_output_force_stop(output)
        end
    end
end

handle_saved_finalized = function(id, T_save, saved_nominal, path)
    if not reset_enabled then return end
    if id == "main" then
        begin_main_reset()
        return
    end
    if not saved_nominal or saved_nominal <= 0 then
        local saved_duration = get_duration(id)
        local ids = {}
        for slot = 1, 3 do
            local dur = durations[slot] or 0
            if dur > 0 and dur <= saved_duration then table.insert(ids, slot) end
        end
        reset_buffer_ids(ids)
        return
    end
    local saved_buf_start = buffer_start_time[id] or (T_save - saved_nominal * 1000)
    local saved_actual_ms = math.min(saved_nominal * 1000, T_save - saved_buf_start)
    if saved_actual_ms < 0 then saved_actual_ms = 0 end
    local saved_start = T_save - saved_actual_ms
    local ids = {}
    for slot = 1, 3 do
        local dur = durations[slot] or 0
        if dur > 0 then
            local bs = buffer_start_time[slot] or (T_save - dur * 1000)
            local actual_start = math.max(bs, T_save - dur * 1000)
            local covered = actual_start >= (saved_start - SYNC_TOLERANCE_MS)
            if covered then table.insert(ids, slot) end
        end
    end
    local should_reset_main = false
    if main_buffer_start_time and main_limit and main_limit > 0 then
        local main_actual_start = math.max(main_buffer_start_time, T_save - main_limit * 1000)
        should_reset_main = main_actual_start >= (saved_start - SYNC_TOLERANCE_MS)
    end
    if should_reset_main then
        begin_main_reset()
    else
        reset_buffer_ids(ids)
    end
end

local function force_stop_outputs(ids)
    ids = ids or BUFFER_IDS
    pending_saves = {}
    pending_restarts = {}
    finalize_queue = {}
    for _, id in ipairs(ids) do
        local output = get_output(id)
        if output and obs.obs_output_active(output) then
            buffer_start_time[id] = nil
            obs.obs_output_force_stop(output)
        end
    end
end

local function shutdown_outputs()
    for _, id in ipairs(BUFFER_IDS) do
        local output = outputs[id]
        if output then
            disconnect_output_signals(id)
            pcall(obs.obs_output_release, output)
            outputs[id] = nil
            buffer_start_time[id] = nil
        end
    end
    output_signals = {}
end

local function tick_state_machine()
    local now = now_ms()
    if reset_state == "stopping_children" then
        if all_children_deactivated() then
            main_stop_seen = false
            main_deactivate_seen = false
            set_reset_state("waiting_main_stop", "children DEACTIVATE")
            obs.obs_frontend_replay_buffer_stop()
        elseif now - state_entered_at > SAFETY_TIMEOUT_MS then
            set_reset_state("idle", "children timeout")
        end
        return
    end
    if reset_state == "waiting_main_stop" then
        if main_deactivate_seen and not main_is_active() then
            set_reset_state("waiting_main_start", "main fully stopped")
            start_attempts = 0
            try_call_start(now)
        elseif now - state_entered_at > SAFETY_TIMEOUT_MS then
            set_reset_state("idle", "main stop timeout")
        end
        return
    end
    if reset_state == "waiting_main_start" then
        if main_start_seen or main_activate_seen or main_is_active() then
            set_reset_state("starting_children", "main started")
            main_buffer_start_time = now_ms()
            for _, id in ipairs(BUFFER_IDS) do
                if should_start(id, main_limit) and not child_is_active(id) then
                    pending_restarts[id] = true
                end
            end
        elseif now - last_start_attempt_at >= START_RETRY_AFTER_MS
               and start_attempts < START_MAX_ATTEMPTS then
            try_call_start(now)
        elseif now - state_entered_at > SAFETY_TIMEOUT_MS then
            set_reset_state("idle", "main start timeout")
        end
        return
    end
    if reset_state == "starting_children" then
        local all_ok = true
        for _, id in ipairs(BUFFER_IDS) do
            if should_start(id, main_limit) and not child_is_active(id) then
                all_ok = false
                break
            end
        end
        if all_ok then
            set_reset_state("idle", "reset complete")
        elseif now - state_entered_at > SAFETY_TIMEOUT_MS then
            set_reset_state("idle", "children timeout")
        end
        return
    end
end

local refresh_effective

local function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        refresh_effective()
        if effective_enabled and frontend_active() then
            for _, id in ipairs(BUFFER_IDS) do
                if should_start(id, main_limit) and not child_is_active(id) then
                    pending_restarts[id] = true
                end
            end
        end
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then
        main_buffer_start_time = now_ms()
        if effective_enabled then
            for _, id in ipairs(BUFFER_IDS) do
                if should_start(id, main_limit) and not child_is_active(id) then
                    pending_restarts[id] = true
                end
            end
        end
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED then
        T_save_request = {}
        if reset_state == "idle" then
            pending_restarts = {}
            pending_saves = {}
            for _, id in ipairs(BUFFER_IDS) do
                local output = outputs[id]
                if output and obs.obs_output_active(output) then
                    buffer_start_time[id] = nil
                    obs.obs_output_force_stop(output)
                end
            end
        end
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        if not effective_enabled then return end
        local tr = tr_status_read()
        if tr.live and tr.effective then
            return
        end
        local main_output = get_main_output()
        local path = nil
        if main_output then
            path = get_last_replay_path(main_output)
            obs.obs_output_release(main_output)
        end
        local duration = main_limit or get_main_limit() or 0
        local T_save = now_ms()
        if path and path ~= "" then
            enqueue_finalize("main", path, duration, T_save)
        else
            handle_saved_finalized("main", T_save, duration, nil)
        end
	elseif event == obs.OBS_FRONTEND_EVENT_EXIT then
		if event_callback then
			obs.obs_frontend_remove_event_callback(event_callback)
			event_callback = nil
		end
		set_reset_state("idle", "exit")
		unsubscribe_main()
		force_stop_outputs()
		T_save_request = {}
		main_buffer_start_time = nil
    end
end

refresh_effective = function()
    local other = tr_status_read()
    local mutual = other.live and other.enabled and other.dangerous
    local new_eff = enabled and not mutual
    local changed = (new_eff ~= effective_enabled)
    effective_enabled = new_eff
    pr_status_update()
    if not changed then return end
    if new_eff then
        if frontend_active() then
            start_outputs()
        end
    else
        force_stop_outputs()
        unsubscribe_main()
        set_reset_state("idle", "effective disabled")
        shared_memory_queue = {}
        child_saved_queue = {}
        pending_saves = {}
        pending_restarts = {}
        finalize_queue = {}
    end
end

function script_description()
    init_locale()
    return getString("ScriptDescription")
end

function script_defaults(settings)
    if not settings then return end
    obs.obs_data_set_default_bool(settings, "enabled", true)
    obs.obs_data_set_default_bool(settings, "reset_after_save", true)
    obs.obs_data_set_default_int(settings, "clip1_seconds", DEFAULT_DURATIONS[1])
    obs.obs_data_set_default_int(settings, "clip2_seconds", DEFAULT_DURATIONS[2])
    obs.obs_data_set_default_int(settings, "clip3_seconds", DEFAULT_DURATIONS[3])
end

function script_properties()
    init_locale()
    local props = obs.obs_properties_create()
    local control = obs.obs_properties_create()
    obs.obs_properties_add_bool(control, "enabled", tr("Enabled"))
    obs.obs_properties_add_bool(control, "reset_after_save", tr("ResetAfterSave"))
    obs.obs_properties_add_group(props, "group_control", tr("GroupControl"), obs.OBS_GROUP_NORMAL, control)
    local lengths = obs.obs_properties_create()
    obs.obs_properties_add_int(lengths, "clip1_seconds", tr("Clip1"), 0, UI_MAX_SECONDS, 1)
    obs.obs_properties_add_int(lengths, "clip2_seconds", tr("Clip2"), 0, UI_MAX_SECONDS, 1)
    obs.obs_properties_add_int(lengths, "clip3_seconds", tr("Clip3"), 0, UI_MAX_SECONDS, 1)
    obs.obs_properties_add_text(lengths, "lengths_info", tr("LengthsInfo"), obs.OBS_TEXT_INFO)
    obs.obs_properties_add_group(props, "group_lengths", tr("GroupLengths"), obs.OBS_GROUP_NORMAL, lengths)
    return props
end

function script_load(settings)
    init_locale()
    signals_available = obs.obs_output_get_signal_handler ~= nil and obs.signal_handler_connect ~= nil
    read_settings(settings)
    bridge_open()
    notify_open()
    pr_status_open()
    refresh_effective()
    event_callback = on_frontend_event
    obs.obs_frontend_add_event_callback(event_callback)
    for slot = 1, 3 do
        local key = "partial_replay_hotkey_" .. slot
        local cb = function(pressed)
            if pressed and effective_enabled then
                if reset_state ~= "idle" then return end
                local output = outputs[slot]
                if output and obs.obs_output_active(output) then
                    T_save_request[slot] = now_ms()
                    T_save_request["duration_" .. slot] = get_duration(slot)
                    pending_saves[slot] = true
                    local ph = obs.obs_output_get_proc_handler(output)
                    if ph then
                        local cd = obs.calldata_create()
                        obs.proc_handler_call(ph, "save", cd)
                        obs.calldata_destroy(cd)
                    end
                end
            end
        end
        hotkey_ids[slot] = obs.obs_hotkey_register_frontend(key, tr("HotkeySave", slot, tr("SecondsFormat", durations[slot])), cb)
        local saved_arr = settings and obs.obs_data_get_array(settings, key) or nil
        if saved_arr then
            obs.obs_hotkey_load(hotkey_ids[slot], saved_arr)
            obs.obs_data_array_release(saved_arr)
        end
    end

    if effective_enabled and frontend_active() then start_outputs() end
end

function script_update(settings)
    if not settings then return end
    read_settings(settings)
    refresh_effective()
    for slot = 1, 3 do
        if hotkey_ids[slot] then
            obs.obs_hotkey_set_description(hotkey_ids[slot], tr("HotkeySave", slot, (durations[slot] > 0 and (not main_limit or durations[slot] < main_limit)) and tr("SecondsFormat", durations[slot]) or tr("Disabled")))
        end
    end
    if not effective_enabled then
        force_stop_outputs()
        return
    end
    if not frontend_active() then
        force_stop_outputs()
        return
    end
    if reset_state ~= "idle" then return end
    start_outputs()
end

function script_save(settings)
    if not settings then return end
    obs.obs_data_set_bool(settings, "enabled", enabled)
    obs.obs_data_set_bool(settings, "reset_after_save", reset_enabled)
    for slot = 1, 3 do
        obs.obs_data_set_int(settings, "clip" .. slot .. "_seconds", durations[slot])
        local key = "partial_replay_hotkey_" .. slot
        local arr = obs.obs_hotkey_save(hotkey_ids[slot])
        obs.obs_data_set_array(settings, key, arr)
        obs.obs_data_array_release(arr)
    end
end

function script_tick(seconds)
    refresh_effective()
    if #shared_memory_queue > 0 then
        if not bridge_view then bridge_open() end
        if not notify_view then notify_open() end
        local batch = shared_memory_queue
        shared_memory_queue = {}
        for _, item in ipairs(batch) do
            if bridge_view then bridge_write(item.path) end
            if notify_view then notify_write(item.path, item.duration) end
        end
    end
    if #child_saved_queue > 0 then
        local batch = child_saved_queue
        child_saved_queue = {}
        for _, id in ipairs(batch) do
            local T_save = T_save_request[id] or now_ms()
            local duration = T_save_request["duration_" .. id] or get_duration(id)
            T_save_request[id] = nil
            T_save_request["duration_" .. id] = nil
            local output = outputs[id]
            if not output then
                pending_saves[id] = nil
            else
                local path = get_last_replay_path(output)
                if path and path ~= "" then
                    enqueue_finalize(id, path, duration, T_save)
                else
                    pending_saves[id] = nil
                    handle_saved_finalized(id, T_save, duration, nil)
                end
            end
        end
    end
    tick_finalize_queue()
    tick_state_machine()
    if reset_state ~= "idle" and reset_state ~= "starting_children" then return end
    if not effective_enabled then
        pending_restarts = {}
        return
    end
    if not frontend_active() then return end
    if not next(pending_restarts) then return end
    local to_check = {}
    for id in pairs(pending_restarts) do to_check[#to_check + 1] = id end
    for _, id in ipairs(to_check) do
        local output = get_output(id)
        if not output then
            pending_restarts[id] = nil
            if not start_output_by_id(id, true) then pending_restarts[id] = true end
        elseif not obs.obs_output_active(output) then
            pending_restarts[id] = nil
            if not start_output_by_id(id, true) then pending_restarts[id] = true end
        else
            pending_restarts[id] = nil
        end
    end
end

function script_unload()
    set_reset_state("idle", "unload")
    if default_loc then pcall(obs.obs_data_release, default_loc); default_loc = nil end
    if current_loc then pcall(obs.obs_data_release, current_loc); current_loc = nil end
    pcall(unsubscribe_main)
    pcall(force_stop_outputs)
    pcall(shutdown_outputs)
    shared_memory_queue = {}
    child_saved_queue = {}
    pending_saves = {}
    pending_restarts = {}
    finalize_queue = {}
    output_signals = {}
    child_deactivated = {}
    buffer_start_time = {}
    main_buffer_start_time = nil
    T_save_request = {}
    pcall(bridge_close)
    pcall(notify_close)
    pcall(pr_status_close)
end