local obs = obslua
local ffi = require("ffi")

ffi.cdef[[
    typedef void* HWND;
    typedef void* HANDLE;
    typedef int BOOL;
    typedef unsigned long DWORD;
    typedef void* LPARAM;
    typedef unsigned int UINT;
    typedef unsigned char uint8_t;
    typedef unsigned int uint32_t;
    typedef long long intptr_t;
    typedef unsigned short WORD;
    typedef unsigned char BYTE;
    typedef unsigned short wchar_t;
    int DwmSetWindowAttribute(HWND hwnd, DWORD dwAttribute, void* pvAttribute, DWORD cbAttribute);
    BOOL EnumWindows(void* lpEnumFunc, LPARAM lParam);
    BOOL IsWindowVisible(HWND hWnd);
    BOOL IsIconic(HWND hWnd);
    BOOL ShowWindow(HWND hWnd, int nCmdShow);
    BOOL SetFocus(HWND hWnd);
    BOOL PostMessageA(HWND hWnd, UINT Msg, intptr_t wParam, intptr_t lParam);
    int GetWindowTextW(HWND hWnd, wchar_t* lpString, int nMaxCount);
    int GetClassNameW(HWND hWnd, wchar_t* lpClassName, int nMaxCount);
    DWORD GetWindowThreadProcessId(HWND hWnd, DWORD* lpdwProcessId);
    DWORD GetCurrentProcessId(void);
    void* GetForegroundWindow(void);
    void keybd_event(uint8_t bVk, uint8_t bScan, uint32_t dwFlags, intptr_t dwExtraInfo);
    int WideCharToMultiByte(UINT CodePage, DWORD dwFlags, const wchar_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, BOOL* lpUsedDefaultChar);
]]

local dwmapi = ffi.load("dwmapi")
local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")

local MY_PID = tonumber(kernel32.GetCurrentProcessId())
local SW_MINIMIZE = 6
local SW_RESTORE = 9
local VK_MENU = 0x12
local VK_T = 0x54
local VK_DOWN = 0x28
local VK_RETURN = 0x0D
local KEYEVENTF_KEYUP = 0x0002
local WM_CLOSE = 0x0010
local CP_UTF8 = 65001
local SCRIPTS_RU = "Скрипты"
local SCRIPTS_EN = "Scripts"
local NULL_HWND = ffi.cast("HWND", 0)
local LOCALE_BASENAME = "Toggle OBS UI"
local default_loc = nil
local current_loc = nil
local script_window_enabled = false
local script_ui_hotkey_id = obs.OBS_INVALID_HOTKEY_ID

local function is_valid_hwnd(h)
    return h ~= nil and h ~= NULL_HWND
end

local function get_window_title_utf8(hwnd)
    local buf = ffi.new("wchar_t[512]")
    local len = user32.GetWindowTextW(hwnd, buf, 512)
    if len == 0 then return nil end
    local utf8_buf = ffi.new("char[2048]")
    local out_len = kernel32.WideCharToMultiByte(CP_UTF8, 0, buf, len, utf8_buf, 2048, nil, nil)
    if out_len == 0 then return nil end
    return ffi.string(utf8_buf, out_len)
end

local function get_window_class_utf8(hwnd)
    local buf = ffi.new("wchar_t[256]")
    local len = user32.GetClassNameW(hwnd, buf, 256)
    if len == 0 then return nil end
    local utf8_buf = ffi.new("char[1024]")
    local out_len = kernel32.WideCharToMultiByte(CP_UTF8, 0, buf, len, utf8_buf, 1024, nil, nil)
    if out_len == 0 then return nil end
    return ffi.string(utf8_buf, out_len)
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

local function is_valid_hotkey(id)
    return id ~= nil and id ~= obs.OBS_INVALID_HOTKEY_ID
end

local function is_obs_main_window(hwnd)
    local class = get_window_class_utf8(hwnd)
    if not class or not class:find("QWindowIcon") then
        return false
    end
    local title = get_window_title_utf8(hwnd)
    if not title or not title:find("OBS") then
        return false
    end
    local pid = ffi.new("DWORD[1]")
    user32.GetWindowThreadProcessId(hwnd, pid)
    return pid[0] == MY_PID
end

local function find_obs_window()
    local found = ffi.new("HWND[1]", nil)
    local callback = ffi.cast("BOOL(__stdcall*)(HWND, LPARAM)", function(hwnd, lparam)
        if is_obs_main_window(hwnd) then
            found[0] = hwnd
            return false
        end
        return true
    end)
    user32.EnumWindows(callback, nil)
    pcall(function() callback:free() end)
    local hwnd = found[0]
    if not is_valid_hwnd(hwnd) then return nil end
    return hwnd
end

local function restore_obs_window(hwnd)
    local cloak = ffi.new("BOOL[1]", 1)
    dwmapi.DwmSetWindowAttribute(hwnd, 13, cloak, ffi.sizeof("BOOL"))
    user32.ShowWindow(hwnd, SW_RESTORE)
    user32.ShowWindow(hwnd, SW_MINIMIZE)
    cloak[0] = 0
    dwmapi.DwmSetWindowAttribute(hwnd, 13, cloak, ffi.sizeof("BOOL"))
end

local function find_scripts_window(obs_hwnd)
    if not is_valid_hwnd(obs_hwnd) then return nil end
    local pid = ffi.new("DWORD[1]")
    user32.GetWindowThreadProcessId(obs_hwnd, pid)
    if pid[0] == 0 then return nil end
    local found = ffi.new("HWND[1]", nil)
    local callback = ffi.cast("BOOL(__stdcall*)(HWND, LPARAM)", function(hwnd, lparam)
        local wnd_pid = ffi.new("DWORD[1]")
        user32.GetWindowThreadProcessId(hwnd, wnd_pid)
        if wnd_pid[0] ~= pid[0] then return true end
        local title = get_window_title_utf8(hwnd)
        if not title then return true end
        if title:find(SCRIPTS_RU, 1, true) or title:find(SCRIPTS_EN, 1, true) then
            found[0] = hwnd
            return false
        end
        return true
    end)
    user32.EnumWindows(callback, nil)
    pcall(function() callback:free() end)
    local hwnd = found[0]
    if not is_valid_hwnd(hwnd) then return nil end
    return hwnd
end

local function press_key(vk)
    user32.keybd_event(vk, 0, 0, 0)
    user32.keybd_event(vk, 0, KEYEVENTF_KEYUP, 0)
end

local function open_scripts_menu()
    local down_presses = 5
    user32.keybd_event(VK_MENU, 0, 0, 0)
    user32.keybd_event(VK_T, 0, 0, 0)
    user32.keybd_event(VK_T, 0, KEYEVENTF_KEYUP, 0)
    user32.keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0)
    for i = 1, down_presses do
        press_key(VK_DOWN)
    end
    press_key(VK_RETURN)
end

local function toggle_obs_ui(pressed)
    if not pressed then return end
    local obs_hwnd = find_obs_window()
    if not is_valid_hwnd(obs_hwnd) then return end
    local scripts_hwnd = nil
    if script_window_enabled then
        scripts_hwnd = find_scripts_window(obs_hwnd)
    end
    local obs_visible = (user32.IsWindowVisible(obs_hwnd) == 1) and (user32.IsIconic(obs_hwnd) == 0)
    if obs_visible then
        if is_valid_hwnd(scripts_hwnd) then
            user32.PostMessageA(scripts_hwnd, WM_CLOSE, 0, 0)
        end
        user32.ShowWindow(obs_hwnd, SW_MINIMIZE)
    else
        if is_valid_hwnd(scripts_hwnd) then
            user32.PostMessageA(scripts_hwnd, WM_CLOSE, 0, 0)
        end
        restore_obs_window(obs_hwnd)
        user32.SetFocus(obs_hwnd)
        if script_window_enabled then
            open_scripts_menu()
        end
    end
end

function script_load(settings)
    init_locale()
    if settings then
        script_window_enabled = obs.obs_data_get_bool(settings, "script_window_enabled")
    end
    script_ui_hotkey_id = obs.obs_hotkey_register_frontend("toggle_obs_ui", getString("HotkeyToggleOBSUI"), toggle_obs_ui)
    if settings and is_valid_hotkey(script_ui_hotkey_id) then
        local arr = obs.obs_data_get_array(settings, "toggle_obs_ui")
        if arr then
            obs.obs_hotkey_load(script_ui_hotkey_id, arr)
            obs.obs_data_array_release(arr)
        end
    end
end

function script_save(settings)
    obs.obs_data_set_bool(settings, "script_window_enabled", script_window_enabled)
    if is_valid_hotkey(script_ui_hotkey_id) then
        local arr = obs.obs_hotkey_save(script_ui_hotkey_id)
        obs.obs_data_set_array(settings, "toggle_obs_ui", arr)
        obs.obs_data_array_release(arr)
    end
end

function script_update(settings)
    if not settings then return end
    script_window_enabled = obs.obs_data_get_bool(settings, "script_window_enabled")
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "script_window_enabled", false)
end

function script_unload()
    if default_loc then pcall(obs.obs_data_release, default_loc); default_loc = nil end
    if current_loc then pcall(obs.obs_data_release, current_loc); current_loc = nil end
end

function script_properties()
    init_locale()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "script_description_text", getString("ScriptDescription"), obs.OBS_TEXT_INFO)
    local g_hotkeys = obs.obs_properties_create()
    obs.obs_properties_add_bool(g_hotkeys, "script_window_enabled", getString("ScriptWindowEnabled"))
    obs.obs_properties_add_group(props, "group_hotkeys", getString("GroupHotkeys"), obs.OBS_GROUP_NORMAL, g_hotkeys)
    return props
end