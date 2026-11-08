local obs = obslua
local ffi = require("ffi")

ffi.cdef[[
    typedef void* HWND;
    typedef void* HANDLE;
    typedef int BOOL;
    typedef unsigned long DWORD;
    DWORD GetWindowThreadProcessId(HWND hWnd, DWORD* lpdwProcessId);
    void* OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
    BOOL QueryFullProcessImageNameA(void* hProcess, DWORD dwFlags, char* lpExeName, DWORD* lpdwSize);
    BOOL CloseHandle(HANDLE hObject);
    void* GetForegroundWindow(void);
    unsigned long long GetTickCount64(void);
]]

local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")

local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
local NULL_HANDLE = ffi.cast("HANDLE", 0)
local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)
local NULL_HWND = ffi.cast("HWND", 0)
local RESET_DELAY_MS = 3000
local DISPLAY_CHECK_DELAY_MS = 500
local LOCALE_BASENAME = "Source Switcher"
local default_loc = nil
local current_loc = nil
local game_source_name = ""
local display_source_name = ""
local window_sources_str = ""
local switcher_enabled = false
local stretch_enabled = false
local display_check_enabled = false
local active = false
local game_item, display_item = nil, nil
local window_items = {}
local hooked_ok, unhooked_ok = false, false
local resetting = false
local reset_start_time = 0
local last_foreground_hwnd = nil
local pending_visibility_check = false
local is_captured = false
local blacklist = {}
local blacklist_str_val = ""
local blacklist_active = false
local scene_blacklist = {}
local scene_blacklist_str_val = ""
local game_item_hidden_by_script = false
local obs_fully_loaded = false
local initialized = false
local display_check_pending = nil
local scene_change_callback = nil
local scene_change_connected = false
local window_sources_data = {}
local scene_sources_signals = {}
local needs_refresh = false
local current_scene_handler = nil
local scene_item_modified_cb = nil

local function now_ms()
    return tonumber(kernel32.GetTickCount64())
end

local function is_valid_handle(h)
    return h ~= nil and h ~= NULL_HANDLE and h ~= INVALID_HANDLE_VALUE
end

local function is_valid_hwnd(h)
    return h ~= nil and h ~= NULL_HWND
end

local function getString(key)
    local str = current_loc and obs.obs_data_get_string(current_loc, key) or ""
    if str == "" and default_loc then
        str = obs.obs_data_get_string(default_loc, key)
    end
    return (str ~= "") and str or key
end

local function init_locale()
    if default_loc then return end
    local dir = script_path():match("(.*[/\\])") or ""
    local loc_dir = dir .. "locale/"
    local lang = obs.obs_get_locale()
    default_loc = obs.obs_data_create_from_json_file(loc_dir .. "en-US " .. LOCALE_BASENAME .. ".json")
    current_loc = obs.obs_data_create_from_json_file(loc_dir .. lang .. " " .. LOCALE_BASENAME .. ".json")
        or obs.obs_data_create_from_json_file(loc_dir .. lang:sub(1, 2) .. " " .. LOCALE_BASENAME .. ".json")
end

function script_description()
    init_locale()
    return getString("ScriptDescription")
end

local function get_canvas_size()
    local vi = obs.obs_video_info()
    if not obs.obs_get_video_info(vi) then
        return 1920, 1080
    end
    return vi.base_width, vi.base_height
end

local function get_current_scene()
    local src = obs.obs_frontend_get_current_scene()
    if src == nil then return nil end
    local scene = obs.obs_scene_from_source(src)
    obs.obs_source_release(src)
    return scene
end

local function get_current_scene_name()
    local src = obs.obs_frontend_get_current_scene()
    if src == nil then return nil end
    local name = obs.obs_source_get_name(src)
    obs.obs_source_release(src)
    return name
end

local function apply_stretch_to_item(item)
    if item == nil then return end
    local canvas_w, canvas_h = get_canvas_size()
    obs.obs_sceneitem_set_bounds_type(item, obs.OBS_BOUNDS_STRETCH)
    local bounds = obs.vec2()
    bounds.x = canvas_w
    bounds.y = canvas_h
    obs.obs_sceneitem_set_bounds(item, bounds)
    obs.obs_sceneitem_set_bounds_alignment(item, 0)
    local pos = obs.vec2()
    pos.x = 0
    pos.y = 0
    obs.obs_sceneitem_set_pos(item, pos)
    local scale = obs.vec2()
    scale.x = 1
    scale.y = 1
    obs.obs_sceneitem_set_scale(item, scale)
    obs.obs_sceneitem_set_rot(item, 0)
end

local function set_visible(item, visible)
    if item == nil then return end
    obs.obs_sceneitem_set_visible(item, visible)
end

local function show_game()
    set_visible(game_item, true)
    set_visible(display_item, false)
    for _, item in pairs(window_items) do
        set_visible(item, false)
    end
end

local function show_display()
    set_visible(game_item, false)
    set_visible(display_item, true)
    for _, item in pairs(window_items) do
        set_visible(item, false)
    end
end

local function show_windows(active_items)
    set_visible(display_item, false)
    for name, item in pairs(window_items) do
        set_visible(item, active_items[name] == true)
    end
end

local function show_both_game_display()
    set_visible(game_item, true)
    set_visible(display_item, true)
    for _, item in pairs(window_items) do
        set_visible(item, false)
    end
end

local function get_process_name_from_hwnd(hwnd)
    if not is_valid_hwnd(hwnd) then return nil end
    local pid = ffi.new("DWORD[1]")
    user32.GetWindowThreadProcessId(hwnd, pid)
    if pid[0] == 0 then return nil end
    local hProcess = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid[0])
    if not is_valid_handle(hProcess) then return nil end
    local EXE_PATH_BUF = 32767
    local exePath = ffi.new("char[?]", EXE_PATH_BUF)
    local dwSize = ffi.new("DWORD[1]", EXE_PATH_BUF)
    local success = kernel32.QueryFullProcessImageNameA(hProcess, 0, exePath, dwSize)
    kernel32.CloseHandle(hProcess)
    if success == 0 then return nil end
    local path = ffi.string(exePath)
    local name = path:match("([^\\]+)$")
    return name and name:lower() or nil
end

local function get_window_source_process(source)
    if not source then return nil end
    local settings = obs.obs_source_get_settings(source)
    if not settings then return nil end
    local window_val = obs.obs_data_get_string(settings, "window")
    obs.obs_data_release(settings)
    if not window_val or window_val == "" then return nil end
    local process = window_val:match(":([^:]+)$")
    if process then
        return process:lower()
    else
        return window_val:lower()
    end
end

local function hide_game_if_visible()
    if not game_item then return end
    if obs.obs_sceneitem_visible(game_item) then
        set_visible(game_item, false)
        game_item_hidden_by_script = true
    end
end

local function show_game_if_hidden_by_script()
    if not game_item then return end
    if game_item_hidden_by_script then
        set_visible(game_item, true)
        game_item_hidden_by_script = false
    end
end

local function apply_visibility_state()
    if not game_item and not display_item and not next(window_items) then
        return
    end
    if resetting then
        if game_item then hide_game_if_visible() end
        if not active then return end
        local current_hwnd = user32.GetForegroundWindow()
        local current_proc = get_process_name_from_hwnd(current_hwnd)
        local matching_windows = {}
        for name, data in pairs(window_sources_data) do
            if data.process and data.process == current_proc then
                matching_windows[name] = true
            end
        end
        if next(matching_windows) then
            set_visible(display_item, false)
            for name, item in pairs(window_items) do
                set_visible(item, matching_windows[name] == true)
            end
            if stretch_enabled then
                for name in pairs(matching_windows) do
                    apply_stretch_to_item(window_items[name])
                end
            end
        else
            set_visible(display_item, display_item ~= nil)
            for _, item in pairs(window_items) do
                set_visible(item, false)
            end
            if stretch_enabled then
                apply_stretch_to_item(display_item)
            end
        end
        return
    end
    local current_hwnd = user32.GetForegroundWindow()
    local current_proc = get_process_name_from_hwnd(current_hwnd)
    local blacklist_hit = false
    if current_proc then
        blacklist_hit = blacklist[current_proc] == true
    end
    if not active then
        if not game_item then return end
        if blacklist_hit then
            if not is_captured then
                hide_game_if_visible()
            end
        else
            show_game_if_hidden_by_script()
        end
        return
    end
    local matching_windows = {}
    for name, data in pairs(window_sources_data) do
        if data.process and data.process == current_proc then
            matching_windows[name] = true
        end
    end
    if blacklist_hit then
        set_visible(game_item, false)
        if next(matching_windows) then
            show_windows(matching_windows)
            if stretch_enabled then
                for name in pairs(matching_windows) do
                    apply_stretch_to_item(window_items[name])
                end
            end
        else
            show_display()
            if stretch_enabled then
                apply_stretch_to_item(display_item)
            end
        end
        return
    end
    if next(matching_windows) then
        if game_item and is_captured then
            show_game()
            if stretch_enabled then
                apply_stretch_to_item(game_item)
            end
        else
            show_windows(matching_windows)
            if stretch_enabled then
                for name in pairs(matching_windows) do
                    apply_stretch_to_item(window_items[name])
                end
            end
        end
        return
    end
    if game_item and is_captured then
        show_game()
        if stretch_enabled then
            apply_stretch_to_item(game_item)
        end
        return
    end
    if game_item and display_item then
        show_both_game_display()
    elseif game_item then
        set_visible(game_item, true)
        set_visible(display_item, false)
        for _, item in pairs(window_items) do
            set_visible(item, false)
        end
        if stretch_enabled then
            apply_stretch_to_item(game_item)
        end
    elseif display_item then
        set_visible(game_item, false)
        set_visible(display_item, true)
        for _, item in pairs(window_items) do
            set_visible(item, false)
        end
        if stretch_enabled then
            apply_stretch_to_item(display_item)
        end
    else
        for _, item in pairs(window_items) do
            set_visible(item, false)
        end
    end
end

local function on_hooked()
    is_captured = true
    if active then
        resetting = false
    end
    if game_item then
        apply_visibility_state()
    end
end

local function on_unhooked()
    is_captured = false
    if active then
        resetting = false
    end
    if game_item then
        apply_visibility_state()
    end
end

local function connect_signals_switcher()
    if game_item == nil then return end
    local source = obs.obs_sceneitem_get_source(game_item)
    if source == nil then return end
    local handler = obs.obs_source_get_signal_handler(source)
    if not handler then return end
    if not hooked_ok then
        hooked_ok = obs.signal_handler_connect(handler, "hooked", on_hooked)
    end
    if not unhooked_ok then
        unhooked_ok = obs.signal_handler_connect(handler, "unhooked", on_unhooked)
    end
end

local function disconnect_signals_switcher()
    if game_item == nil then return end
    local source = obs.obs_sceneitem_get_source(game_item)
    if source == nil then return end
    local handler = obs.obs_source_get_signal_handler(source)
    if not handler then return end
    if hooked_ok then
        obs.signal_handler_disconnect(handler, "hooked", on_hooked)
        hooked_ok = false
    end
    if unhooked_ok then
        obs.signal_handler_disconnect(handler, "unhooked", on_unhooked)
        unhooked_ok = false
    end
end

local function start_reset(force)
    if not game_item then return end
    if not is_captured then return end
    if not force then
        if not active then return end
        if blacklist_active then return end
    end
    if not resetting then
        resetting = true
        reset_start_time = now_ms()
    else
        reset_start_time = now_ms()
    end
    hide_game_if_visible()
end

local function check_reset_timeout()
    if not resetting then return end
    if now_ms() - reset_start_time >= RESET_DELAY_MS then
        resetting = false
        if is_captured then
            is_captured = false
        end
        apply_visibility_state()
    end
end

local function clear_window_sources_data()
    for source, data in pairs(scene_sources_signals) do
        local handler = obs.obs_source_get_signal_handler(source)
        if handler then
            obs.signal_handler_disconnect(handler, "update", data.cb)
            obs.signal_handler_disconnect(handler, "rename", data.cb)
        end
    end
    scene_sources_signals = {}
    window_sources_data = {}
    window_items = {}
end

local function teardown_active_switcher()
    disconnect_signals_switcher()
    clear_window_sources_data()
    active = false
    resetting = false
    blacklist_active = false
    game_item = nil
    display_item = nil
    game_item_hidden_by_script = false
end

local function on_scene_item_modified(cd)
    if active then
        teardown_active_switcher()
    else
        disconnect_signals_switcher()
    end
    needs_refresh = true
end

local function disconnect_scene_signals()
    if current_scene_handler and scene_item_modified_cb then
        obs.signal_handler_disconnect(current_scene_handler, "item_add", scene_item_modified_cb)
        obs.signal_handler_disconnect(current_scene_handler, "item_remove", scene_item_modified_cb)
        obs.signal_handler_disconnect(current_scene_handler, "rename", scene_item_modified_cb)
    end
    current_scene_handler = nil
    scene_item_modified_cb = nil
end

local function connect_scene_signals(scene)
    disconnect_scene_signals()
    local source = obs.obs_scene_get_source(scene)
    if source then
        current_scene_handler = obs.obs_source_get_signal_handler(source)
        if current_scene_handler then
            scene_item_modified_cb = on_scene_item_modified
            obs.signal_handler_connect(current_scene_handler, "item_add", scene_item_modified_cb)
            obs.signal_handler_connect(current_scene_handler, "item_remove", scene_item_modified_cb)
            obs.signal_handler_connect(current_scene_handler, "rename", scene_item_modified_cb)
        end
    end
end

local function init_switcher_items()
    local scene = get_current_scene()
    if not scene then return false end
    connect_scene_signals(scene)
    if game_source_name ~= "" then
        game_item = obs.obs_scene_find_source(scene, game_source_name)
    else
        game_item = nil
    end
    if not active then
        return game_item ~= nil
    end
    if display_source_name ~= "" then
        display_item = obs.obs_scene_find_source(scene, display_source_name)
    else
        display_item = nil
    end
    clear_window_sources_data()
    local enum_items = obs.obs_scene_enum_items(scene)
    if enum_items then
        for _, item in ipairs(enum_items) do
            local source = obs.obs_sceneitem_get_source(item)
            if source then
                local handler = obs.obs_source_get_signal_handler(source)
                if handler then
                    local cb = function()
                        needs_refresh = true
                    end
                    obs.signal_handler_connect(handler, "update", cb)
                    obs.signal_handler_connect(handler, "rename", cb)
                    scene_sources_signals[source] = { cb = cb }
                end
            end
        end
        obs.sceneitem_list_release(enum_items)
    end
    for name in string.gmatch(window_sources_str, "[^,]+") do
        local trimmed = name:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            local item = obs.obs_scene_find_source(scene, trimmed)
            if item then
                local source = obs.obs_sceneitem_get_source(item)
                if source then
                    local proc = get_window_source_process(source)
                    if proc then
                        window_sources_data[trimmed] = { process = proc }
                        window_items[trimmed] = item
                    end
                end
            end
        end
    end
    local window_count = 0
    for _ in pairs(window_sources_data) do window_count = window_count + 1 end
    local valid = (window_count >= 1) or (game_item ~= nil and display_item ~= nil)
    if not valid then
        clear_window_sources_data()
        display_item = nil
        return false
    end
    return true
end

local function update_blacklist(blacklist_str)
    blacklist = {}
    blacklist_str_val = blacklist_str or ""
    if blacklist_str and blacklist_str ~= "" then
        for name in string.gmatch(blacklist_str, "[^,]+") do
            local trimmed = name:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                blacklist[trimmed:lower()] = true
            end
        end
    end
end

local function update_scene_blacklist(str)
    scene_blacklist = {}
    scene_blacklist_str_val = str or ""
    if str and str ~= "" then
        for name in string.gmatch(str, "[^,]+") do
            local trimmed = name:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                scene_blacklist[trimmed] = true
            end
        end
    end
end

local function is_current_scene_blacklisted()
    if next(scene_blacklist) == nil then return false end
    local name = get_current_scene_name()
    if not name then return false end
    return scene_blacklist[name] == true
end

local function refresh_switcher()
    if game_item and game_item_hidden_by_script then
        set_visible(game_item, true)
    end
    disconnect_signals_switcher()
    disconnect_scene_signals()
    clear_window_sources_data()
    active = false
    game_item = nil
    display_item = nil
    game_item_hidden_by_script = false
    is_captured = false
    local scene_blacklisted = is_current_scene_blacklisted()
    active = switcher_enabled and not scene_blacklisted
    local ok = init_switcher_items()
    if not ok then
        active = false
    end
    if game_item then
        connect_signals_switcher()
        local source = obs.obs_sceneitem_get_source(game_item)
        if source then
            local w = obs.obs_source_get_width(source)
            local h = obs.obs_source_get_height(source)
            if w > 0 and h > 0 then
                is_captured = true
                start_reset(true)
            else
                is_captured = false
            end
        end
    end
    last_foreground_hwnd = user32.GetForegroundWindow()
    pending_visibility_check = false
    blacklist_active = false
    if last_foreground_hwnd then
        local proc_name = get_process_name_from_hwnd(last_foreground_hwnd)
        if proc_name and blacklist[proc_name] then
            blacklist_active = true
        end
    end
    apply_visibility_state()
end

local function perform_display_check(item, hide_back)
    local source = obs.obs_sceneitem_get_source(item)
    if source == nil then
        if hide_back then obs.obs_sceneitem_set_visible(item, false) end
        return
    end
    local width = obs.obs_source_get_width(source)
    local height = obs.obs_source_get_height(source)
    if width == 0 or height == 0 then
        if obs.obs_frontend_open_source_properties ~= nil then
            obs.obs_frontend_open_source_properties(source)
        end
    end
    if hide_back then
        obs.obs_sceneitem_set_visible(item, false)
    end
end

local function check_display_source()
    if not display_check_enabled then return end
    if display_source_name == nil or display_source_name == "" then return end
    local scene = get_current_scene()
    if not scene then return end
    local item = obs.obs_scene_find_source(scene, display_source_name)
    if not item then return end
    local was_visible = obs.obs_sceneitem_visible(item)
    if not was_visible then
        obs.obs_sceneitem_set_visible(item, true)
    end
    display_check_pending = {
        item = item,
        start_time = now_ms(),
        restore_hidden = not was_visible,
    }
end

local function tick_display_check()
    if not display_check_pending then return end
    if now_ms() - display_check_pending.start_time < DISPLAY_CHECK_DELAY_MS then return end
    local item = display_check_pending.item
    local source = obs.obs_sceneitem_get_source(item)
    if source == nil then
        display_check_pending = nil
        return
    end
    local width = obs.obs_source_get_width(source)
    local height = obs.obs_source_get_height(source)
    local restore_hidden = display_check_pending.restore_hidden
    display_check_pending = nil
    if width == 0 or height == 0 then
        if obs.obs_frontend_open_source_properties ~= nil then
            obs.obs_frontend_open_source_properties(source)
        end
    end
    if restore_hidden then
        obs.obs_sceneitem_set_visible(item, false)
    end
end

local function on_scene_changed(event, data)
    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        obs_fully_loaded = true
        if not initialized then
            initialized = true
            refresh_switcher()
            check_display_source()
        end
    elseif event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        if initialized then
            refresh_switcher()
            check_display_source()
        end
    elseif event == obs.OBS_FRONTEND_EVENT_EXIT then
        if scene_change_connected and scene_change_callback then
            pcall(obs.obs_frontend_remove_event_callback, scene_change_callback)
            scene_change_connected = false
            scene_change_callback = nil
        end
    end
end
function script_tick(seconds)
    tick_display_check()
    if not obs_fully_loaded then
        return
    end
    if not initialized then
        initialized = true
        refresh_switcher()
        check_display_source()
        return
    end
    if needs_refresh then
        needs_refresh = false
        refresh_switcher()
    end
    if not active and not game_item then return end
    local current_hwnd = user32.GetForegroundWindow()
    if current_hwnd ~= last_foreground_hwnd then
        pending_visibility_check = true
    end
    if pending_visibility_check then
        local proc_name = nil
        local proc_unknown = false
        if is_valid_hwnd(current_hwnd) then
            proc_name = get_process_name_from_hwnd(current_hwnd)
            if proc_name == nil then
                proc_unknown = true
            end
        end
        if not proc_unknown then
            pending_visibility_check = false
            last_foreground_hwnd = current_hwnd
            local new_blacklist_active = (proc_name and blacklist[proc_name] == true) or false
            if new_blacklist_active ~= blacklist_active then
                blacklist_active = new_blacklist_active
            end
            if active and game_item and not blacklist_active and is_captured then
                start_reset()
            end
            apply_visibility_state()
        end
    end
    check_reset_timeout()
end

function script_load(settings)
    init_locale()
    if settings then
        game_source_name = obs.obs_data_get_string(settings, "game_source") or ""
        display_source_name = obs.obs_data_get_string(settings, "display_source") or ""
        window_sources_str = obs.obs_data_get_string(settings, "window_sources") or ""
        switcher_enabled = obs.obs_data_get_bool(settings, "switcher_enabled")
        stretch_enabled = obs.obs_data_get_bool(settings, "stretch_enabled")
        display_check_enabled = obs.obs_data_get_bool(settings, "display_check_enabled")
        update_blacklist(obs.obs_data_get_string(settings, "blacklist"))
        update_scene_blacklist(obs.obs_data_get_string(settings, "scene_blacklist"))
    end
    initialized = false
    local probe_scene = obs.obs_frontend_get_current_scene()
    if probe_scene then
        obs.obs_source_release(probe_scene)
        obs_fully_loaded = true
    else
        obs_fully_loaded = false
    end
    if not scene_change_connected then
        scene_change_callback = on_scene_changed
        obs.obs_frontend_add_event_callback(scene_change_callback)
        scene_change_connected = true
    end
end

function script_save(settings)
    obs.obs_data_set_string(settings, "game_source", game_source_name)
    obs.obs_data_set_string(settings, "display_source", display_source_name)
    obs.obs_data_set_string(settings, "window_sources", window_sources_str)
    obs.obs_data_set_bool(settings, "switcher_enabled", switcher_enabled)
    obs.obs_data_set_bool(settings, "stretch_enabled", stretch_enabled)
    obs.obs_data_set_bool(settings, "display_check_enabled", display_check_enabled)
    obs.obs_data_set_string(settings, "blacklist", blacklist_str_val)
    obs.obs_data_set_string(settings, "scene_blacklist", scene_blacklist_str_val)
end

function script_update(settings)
    if not settings then return end
    local new_game_name = obs.obs_data_get_string(settings, "game_source") or ""
    local new_display_name = obs.obs_data_get_string(settings, "display_source") or ""
    local new_window_sources = obs.obs_data_get_string(settings, "window_sources") or ""
    local new_blacklist_str = obs.obs_data_get_string(settings, "blacklist") or ""
    local new_scene_blacklist_str = obs.obs_data_get_string(settings, "scene_blacklist") or ""
    local new_switcher = obs.obs_data_get_bool(settings, "switcher_enabled")
    local new_stretch = obs.obs_data_get_bool(settings, "stretch_enabled")
    local new_display_check = obs.obs_data_get_bool(settings, "display_check_enabled")
    local needs_heavy_reinit = false
    if new_game_name ~= game_source_name then
        game_source_name = new_game_name
        needs_heavy_reinit = true
    end
    if new_display_name ~= display_source_name then
        display_source_name = new_display_name
        needs_heavy_reinit = true
    end
    if new_window_sources ~= window_sources_str then
        window_sources_str = new_window_sources
        needs_heavy_reinit = true
    end
    if new_blacklist_str ~= blacklist_str_val then
        update_blacklist(new_blacklist_str)
        needs_heavy_reinit = true
    end
    if new_scene_blacklist_str ~= scene_blacklist_str_val then
        update_scene_blacklist(new_scene_blacklist_str)
        needs_heavy_reinit = true
    end
    if new_switcher ~= switcher_enabled then
        switcher_enabled = new_switcher
        needs_heavy_reinit = true
    end
    if new_stretch ~= stretch_enabled then
        stretch_enabled = new_stretch
        needs_heavy_reinit = true
    end
    if new_display_check ~= display_check_enabled then
        display_check_enabled = new_display_check
    end
    if needs_heavy_reinit and initialized then
        refresh_switcher()
    end
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "switcher_enabled", false)
    obs.obs_data_set_default_bool(settings, "stretch_enabled", false)
    obs.obs_data_set_default_bool(settings, "display_check_enabled", false)
end

function script_unload()
    active = false
    game_item = nil
    display_item = nil
    if default_loc then pcall(obs.obs_data_release, default_loc); default_loc = nil end
    if current_loc then pcall(obs.obs_data_release, current_loc); current_loc = nil end
end

function script_properties()
    init_locale()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "script_description_text", getString("ScriptDescription"), obs.OBS_TEXT_INFO)
    local g_switcher_toggles = obs.obs_properties_create()
    obs.obs_properties_add_bool(g_switcher_toggles, "switcher_enabled", getString("SwitcherEnabled"))
    obs.obs_properties_add_bool(g_switcher_toggles, "stretch_enabled", getString("StretchEnabled"))
    obs.obs_properties_add_bool(g_switcher_toggles, "display_check_enabled", getString("DisplayCheckEnabled"))
    obs.obs_properties_add_group(props, "group_switcher_toggles", getString("GroupSwitcherManagement"), obs.OBS_GROUP_NORMAL, g_switcher_toggles)
    local g_switcher = obs.obs_properties_create()
    obs.obs_properties_add_text(g_switcher, "display_source", getString("DisplaySource"), obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(g_switcher, "game_source", getString("GameSource"), obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(g_switcher, "window_sources", getString("WindowSources"), obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(g_switcher, "blacklist", getString("Blacklist"), obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(g_switcher, "scene_blacklist", getString("SceneBlacklist"), obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_group(props, "group_switcher", getString("GroupSwitcherSettings"), obs.OBS_GROUP_NORMAL, g_switcher)
    return props
end