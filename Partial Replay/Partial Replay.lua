local obs = obslua
local MAX_AUDIO_MIXES = 6
local UI_MAX_SECONDS = 3600
local DEFAULT_DURATIONS = { 30, 60, 120 }
local BUFFER_IDS = { 1, 2, 3 }
local default_loc = nil
local current_loc = nil
local enabled = false
local reset_enabled = false
local durations = { DEFAULT_DURATIONS[1], DEFAULT_DURATIONS[2], DEFAULT_DURATIONS[3] }
local main_limit = nil
local outputs = {}
local output_signals = {}
local pending_saves = {}
local pending_restarts = {}
local main_reset_pending = false
local main_stopped_by_reset = false
local pending_main_restart = false
local last_main_restart_try = 0
local event_callback = nil
local exit_in_progress = false
local signals_available = false
local start_output_by_id = nil
local handle_saved = nil
local begin_main_reset = nil
local reset_buffer_ids = nil
local hotkey_ids = {}
local LOCALE_NAME = "Partial Replay"
local shared_memory_queue = {}
local shared_memory_queue_max = 1000
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

ffi.cdef[[
    typedef void* HANDLE;
    typedef unsigned long DWORD;
    typedef int BOOL;
    typedef const unsigned short* LPCWSTR;
    typedef size_t SIZE_T;
    HANDLE CreateFileMappingW(HANDLE, void*, DWORD, DWORD, DWORD, LPCWSTR);
    void* MapViewOfFile(HANDLE, DWORD, DWORD, DWORD, SIZE_T);
    BOOL UnmapViewOfFile(void*);
    BOOL CloseHandle(HANDLE);
]]

local kernel32 = ffi.load("kernel32")
local bridge_handle = nil
local bridge_view = nil
local bridge_hdr = nil
local notify_handle = nil
local notify_view = nil
local notify_hdr = nil

local function bridge_wide(s)
    local b = ffi.new("unsigned short[?]", #s + 1)
    for i = 1, #s do
        b[i-1] = s:byte(i)
    end
    b[#s] = 0
    return b
end

local function bridge_open()
    if bridge_view then return true end
    bridge_handle = kernel32.CreateFileMappingW(ffi.cast("HANDLE", -1), nil, 0x04, 0, BRIDGE_TOTAL, bridge_wide(BRIDGE_NAME))
    if bridge_handle == nil or bridge_handle == ffi.cast("HANDLE", 0) then return false end
    bridge_view = kernel32.MapViewOfFile(bridge_handle, 0x000F001F, 0, 0, BRIDGE_TOTAL)
    if bridge_view == nil then
        kernel32.CloseHandle(bridge_handle)
        bridge_handle = nil
        return false
    end
    bridge_hdr = ffi.cast("unsigned int*", bridge_view)
    return true
end

local function bridge_close()
    if bridge_view then
        kernel32.UnmapViewOfFile(bridge_view)
        bridge_view = nil
    end
    if bridge_handle then
        kernel32.CloseHandle(bridge_handle)
        bridge_handle = nil
    end
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
        notify_handle = nil
        return false
    end
    notify_view = kernel32.MapViewOfFile(notify_handle, 0x000F001F, 0, 0, NOTIFY_TOTAL)
    if notify_view == nil then
        kernel32.CloseHandle(notify_handle)
        notify_handle = nil
        return false
    end
    notify_hdr = ffi.cast("unsigned int*", notify_view)
    return true
end

local function notify_close()
    if notify_view then
        kernel32.UnmapViewOfFile(notify_view)
        notify_view = nil
    end
    if notify_handle then
        kernel32.CloseHandle(notify_handle)
        notify_handle = nil
    end
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

local function now_ms()
    if obs.os_gettime_ns then
        local value = tonumber(obs.os_gettime_ns())
        if value then
            return value / 1000000
        end
    end
    return os.time() * 1000
end

local function init_locale()
    if default_loc then return end
    local dir = script_path():match("(.*[/\\])") or ""
    local loc_dir = dir .. "locale/"
    local lang = "en-US"
    if obs.obs_get_locale then
        lang = obs.obs_get_locale() or lang
    end
    default_loc = obs.obs_data_create_from_json_file(loc_dir .. "en-US " .. LOCALE_NAME .. ".json")
    current_loc = obs.obs_data_create_from_json_file(loc_dir .. lang .. " " .. LOCALE_NAME .. ".json")
        or obs.obs_data_create_from_json_file(loc_dir .. tostring(lang):sub(1, 2) .. " " .. LOCALE_NAME .. ".json")
end

local function getString(key)
    local value = current_loc and obs.obs_data_get_string(current_loc, key) or ""
    if value == "" and default_loc then
        value = obs.obs_data_get_string(default_loc, key)
    end
    return value ~= "" and value or key
end

local function tr(key, ...)
    init_locale()
    local value = getString(key)
    if select("#", ...) > 0 then
        return string.format(value, ...)
    end
    return value
end

local function report_child_save(id)
    local output = outputs[id]
    if not output then return end
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
    if ok and path and path ~= "" then
        shared_memory_queue[#shared_memory_queue + 1] = {path = path, duration = durations[id] or 0}
        if #shared_memory_queue > shared_memory_queue_max then
            table.remove(shared_memory_queue, 1)
        end
    end
end

local function get_main_output()
    return obs.obs_frontend_get_replay_buffer_output()
end

local function get_main_limit()
    local active = false
    if obs.obs_frontend_replay_buffer_active then
        active = obs.obs_frontend_replay_buffer_active()
    end
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
            if tostring(mode):lower() == "advanced" then
                table.insert(sections, "AdvOut")
            end
            table.insert(sections, "SimpleOutput")
            table.insert(sections, "AdvOut")
            for _, section in ipairs(sections) do
                local seconds = obs.config_get_int(config, section, "RecRBTime")
                if seconds and seconds > 0 then return seconds end
            end
        end
    end
    return output_limit
end

local function get_duration(id)
    return durations[id] or 0
end

local function buffer_label(id)
    return tr("AutoGroupName")
end

local function hotkey_label(id)
    local duration = get_duration(id)
    local status = ""
    if duration <= 0 or (main_limit and main_limit > 0 and duration >= main_limit) then
        status = tr("Disabled")
    else
        status = tr("SecondsFormat", duration)
    end
    return tr("HotkeySave", id, status)
end

local function get_output(id)
    return outputs[id]
end

local function frontend_active()
    return obs.obs_frontend_replay_buffer_active and obs.obs_frontend_replay_buffer_active() or false
end

local function normalize_duration(value)
    value = tonumber(value) or 0
    value = math.floor(value + 0.5)
    if value < 0 then value = 0 end
    return value
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

local function should_start(id, limit)
    if not enabled then return false end
    local duration = durations[id] or 0
    if duration <= 0 then return false end
    if limit and limit > 0 and duration >= limit then return false end
    return true
end

local function on_output_saved(id)
    pending_saves[id] = nil
    report_child_save(id)
    handle_saved(id)
end

local function connect_output_signals(id, output)
    if not signals_available or output_signals[id] then return end
    local handler = obs.obs_output_get_signal_handler(output)
    if not handler then return end
    local saved_cb = function()
        on_output_saved(id)
    end
    obs.signal_handler_connect(handler, "saved", saved_cb)
    output_signals[id] = { handler = handler, saved = saved_cb }
end

local function disconnect_output_signals(id)
    local info = output_signals[id]
    if not info then return end
    if obs.signal_handler_disconnect then
        obs.signal_handler_disconnect(info.handler, "saved", info.saved)
    end
    output_signals[id] = nil
end

local function apply_main_limit(limit)
    main_limit = limit
    for slot = 1, 3 do
        if hotkey_ids[slot] then
            obs.obs_hotkey_set_description(hotkey_ids[slot], hotkey_label(slot))
        end
    end
end

local function start_single_output(id, ctx, force_restart)
    local output = get_output(id)
    if not should_start(id, ctx.limit) then
        pending_saves[id] = nil
        pending_restarts[id] = nil
        if output and obs.obs_output_active(output) then
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
        return true
    end
    if obs.obs_output_active(output) and not force_restart then
        local active_settings = obs.obs_output_get_settings(output)
        local active_duration = active_settings and obs.obs_data_get_int(active_settings, "max_time_sec") or 0
        if active_settings then
            obs.obs_data_release(active_settings)
        end
        if active_duration ~= get_duration(id) then
            pending_saves[id] = nil
            pending_restarts[id] = true
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
        return true
    end
    pending_restarts[id] = true
    return false
end

local function start_outputs()
    if not enabled or not frontend_active() then return false end
    local main = get_main_output()
    if not main then return false end
    local main_settings = obs.obs_output_get_settings(main)
    if not main_settings then
        obs.obs_output_release(main)
        return false
    end
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
    local ctx = { main_settings = main_settings, main_video = main_video, main_audio = main_audio, limit = limit }
    for _, id in ipairs(BUFFER_IDS) do
        start_single_output(id, ctx)
    end
    obs.obs_data_release(main_settings)
    obs.obs_output_release(main)
    return true
end

start_output_by_id = function(id, force_restart)
    if not enabled or not frontend_active() then return false end
    local main = get_main_output()
    if not main then return false end
    local main_settings = obs.obs_output_get_settings(main)
    if not main_settings then
        obs.obs_output_release(main)
        return false
    end
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
    local ctx = { main_settings = main_settings, main_video = main_video, main_audio = main_audio, limit = limit }
    local result = start_single_output(id, ctx, force_restart)
    obs.obs_data_release(main_settings)
    obs.obs_output_release(main)
    return result
end

reset_buffer_ids = function(ids)
    for _, id in ipairs(ids) do
        local output = get_output(id)
        if output and obs.obs_output_active(output) and not pending_saves[id] then
            pending_restarts[id] = true
            obs.obs_output_force_stop(output)
        end
    end
end

begin_main_reset = function()
    if not enabled or not reset_enabled or main_reset_pending then return end
    main_reset_pending = true
    main_stopped_by_reset = true
    pending_saves = {}
    pending_restarts = {}
    obs.obs_frontend_replay_buffer_stop()
end

handle_saved = function(id)
    if not reset_enabled then return end
    if id == "main" then
        begin_main_reset()
        return
    end
    local saved_duration = get_duration(id)
    local ids = {}
    for slot = 1, 3 do
        local duration = durations[slot] or 0
        if duration > 0 and duration <= saved_duration then
            table.insert(ids, slot)
        end
    end
    reset_buffer_ids(ids)
end

local function force_stop_outputs(ids)
    ids = ids or BUFFER_IDS
    pending_saves = {}
    pending_restarts = {}
    pending_main_restart = false
    for _, id in ipairs(ids) do
        local output = get_output(id)
        if output and obs.obs_output_active(output) then
            obs.obs_output_force_stop(output)
        end
    end
end

local function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        if enabled and frontend_active() then start_outputs() end
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then
        main_reset_pending = false
        main_stopped_by_reset = false
        pending_main_restart = false
        last_main_restart_try = 0
        if enabled then start_outputs() end
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED then
        force_stop_outputs()
        if main_reset_pending then
            pending_main_restart = true
            last_main_restart_try = 0
        end
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        if not enabled then return end
        handle_saved("main")
    elseif event == obs.OBS_FRONTEND_EVENT_EXIT then
        exit_in_progress = true
        force_stop_outputs()
    end
end

local function add_length_properties(group)
    obs.obs_properties_add_int(group, "clip1_seconds", tr("Clip1"), 0, UI_MAX_SECONDS, 1)
    obs.obs_properties_add_int(group, "clip2_seconds", tr("Clip2"), 0, UI_MAX_SECONDS, 1)
    obs.obs_properties_add_int(group, "clip3_seconds", tr("Clip3"), 0, UI_MAX_SECONDS, 1)
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
    add_length_properties(lengths)
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
    event_callback = on_frontend_event
    obs.obs_frontend_add_event_callback(event_callback)
    for slot = 1, 3 do
        local hotkey_key = "partial_replay_hotkey_" .. slot
        local callback = function(pressed)
            if pressed and enabled then
                local output = outputs[slot]
                if output and obs.obs_output_active(output) then
                    local ph = obs.obs_output_get_proc_handler(output)
                    if ph then
                        local cd = obs.calldata_create()
                        obs.proc_handler_call(ph, "save", cd)
                        obs.calldata_destroy(cd)
                    end
                end
            end
        end
        hotkey_ids[slot] = obs.obs_hotkey_register_frontend(hotkey_key, hotkey_label(slot), callback)
        local saved_array = obs.obs_data_get_array(settings, hotkey_key)
        obs.obs_hotkey_load(hotkey_ids[slot], saved_array)
        obs.obs_data_array_release(saved_array)
    end
    if enabled and frontend_active() then start_outputs() end
end

function script_update(settings)
    if not settings then return end
    read_settings(settings)
    for slot = 1, 3 do
        if hotkey_ids[slot] then
            obs.obs_hotkey_set_description(hotkey_ids[slot], hotkey_label(slot))
        end
    end
    if not enabled then
        pending_main_restart = false
        last_main_restart_try = 0
        if main_reset_pending and not frontend_active() and not exit_in_progress then
            obs.obs_frontend_replay_buffer_start()
        end
        main_reset_pending = false
        main_stopped_by_reset = false
        force_stop_outputs()
        return
    end
    if not frontend_active() then
        force_stop_outputs()
        if main_reset_pending then
            pending_main_restart = true
            last_main_restart_try = 0
        end
        return
    end
    if main_reset_pending then return end
    start_outputs()
end

function script_save(settings)
    if not settings then return end
    obs.obs_data_set_bool(settings, "enabled", enabled)
    obs.obs_data_set_bool(settings, "reset_after_save", reset_enabled)
    for slot = 1, 3 do
        obs.obs_data_set_int(settings, "clip" .. slot .. "_seconds", durations[slot])
        local hotkey_key = "partial_replay_hotkey_" .. slot
        local hotkey_array = obs.obs_hotkey_save(hotkey_ids[slot])
        obs.obs_data_set_array(settings, hotkey_key, hotkey_array)
        obs.obs_data_array_release(hotkey_array)
    end
end

function script_tick(seconds)
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
    if pending_main_restart then
        if exit_in_progress then
            pending_main_restart = false
        elseif frontend_active() then
            pending_main_restart = false
            last_main_restart_try = 0
        else
            local now_t = now_ms()
            if now_t - last_main_restart_try >= 500 then
                last_main_restart_try = now_t
                obs.obs_frontend_replay_buffer_start()
            end
        end
    end
    if not next(pending_restarts) then return end
    if not enabled or not frontend_active() then
        pending_restarts = {}
        return
    end
    local to_check = {}
    for id in pairs(pending_restarts) do
        to_check[#to_check + 1] = id
    end
    for _, id in ipairs(to_check) do
        local output = get_output(id)
        if not output then
            pending_restarts[id] = nil
        elseif not obs.obs_output_active(output) then
            pending_restarts[id] = nil
            if not start_output_by_id(id, true) then
                pending_restarts[id] = true
            end
        end
    end
end

function script_unload()
    if event_callback then
        obs.obs_frontend_remove_event_callback(event_callback)
        event_callback = nil
    end
    if not exit_in_progress and main_stopped_by_reset and not frontend_active() then
        obs.obs_frontend_replay_buffer_start()
    end
    force_stop_outputs()
    for _, id in ipairs(BUFFER_IDS) do
        disconnect_output_signals(id)
        local output = outputs[id]
        if output then
            obs.obs_output_release(output)
            outputs[id] = nil
        end
    end
    shared_memory_queue = {}
    pending_saves = {}
    pending_restarts = {}
    output_signals = {}
    main_reset_pending = false
    main_stopped_by_reset = false
    pending_main_restart = false
    last_main_restart_try = 0
    exit_in_progress = false
    bridge_close()
    notify_close()
end