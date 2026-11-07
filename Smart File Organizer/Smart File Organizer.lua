local obs = obslua
local LOCALE_BASENAME = "Smart File Organizer"
local MOVE_DEADLINE_MS = 30000
local MOVE_RETRY_DELAY_MS = 100
local MAX_QUEUE_PER_TICK = 10
local AUTO_STOP_TIMEOUT_MS = 10000
local AUTO_START_RETRY_MS = 1000
local AUTO_START_MAX_ATTEMPTS = 10
local AUTO_SPLIT_GRACE_MS = 3000
local CAPTURE_REFRESH_MS = 1000
local DESKTOP_FOLDER_NAME = "Desktop"
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
local CP_UTF8 = 65001
local MAX_PATH_CHARS = 32768
local FILE_READ_ATTRIBUTES = 0x80
local OPEN_EXISTING = 3
local FILE_ATTRIBUTE_NORMAL = 0x80
local BRIDGE_NAME = "Local\\OBS_SFO_Bridge_v1"
local BRIDGE_HEADER = 8
local BRIDGE_SLOT = 1024
local BRIDGE_SLOTS = 128
local BRIDGE_TOTAL = BRIDGE_HEADER + BRIDGE_SLOT * BRIDGE_SLOTS
local STATUS_NAME = "Local\\OBS_SFO_Status_v1"
local STATUS_SIZE = 16
local MOVED_NAME = "Local\\OBS_SFO_Moved_v1"
local MOVED_HEADER = 8
local MOVED_SLOT = 2048
local MOVED_SLOTS = 128
local MOVED_TOTAL = MOVED_HEADER + MOVED_SLOT * MOVED_SLOTS
local MOVED_PAYLOAD_MAX = MOVED_SLOT - 12
local PR_NOTIFY_NAME = "Local\\OBS_PR_Notify_v1"
local PENDING_REPLAY_MAX_ATTEMPTS = 10
local CONFIG = {enabled = true,auto_split = false}

local STATE = {
    queue = {},
    seen = {},
    focus_hwnd = nil,
    focus_context = nil,
    game_capture_exes = {},
    window_capture_exes = {},
    captured_exes = {},
    source_signals = {},
    source_exe = {},
    last_capture_refresh = 0,
    active_context = nil,
    current_segment = nil,
    last_focus_key = nil,
    auto_stop_context = nil,
    auto_stop_pending = false,
    auto_stop_started_at = 0,
    pending_auto_start = false,
    pending_start_segment = nil,
    auto_restart = false,
    auto_start_attempts = 0,
    auto_start_last_try = 0,
    auto_split_grace_until = 0,
    baseline_refresh_pending = false,
    current_recording_file = nil,
    recording_output = nil,
    recording_signal_handler = nil,
    last_recording_check = 0,
    event_callback = nil,
    exiting = false,
    status_handle = nil,
    status_view = nil,
    status_hdr = nil,
    moved_handle = nil,
    moved_view = nil,
    moved_hdr = nil,
    pending_replay_path = nil,
    pending_replay_attempts = 0,
}

local ffi = require("ffi")
ffi.cdef[[
    typedef void* HANDLE;
    typedef void* HWND;
    typedef unsigned long DWORD;
    typedef int BOOL;
    typedef unsigned int UINT;
    typedef const unsigned short* LPCWSTR;
    typedef size_t SIZE_T;
    HWND GetForegroundWindow(void);
    DWORD GetWindowThreadProcessId(HWND hWnd, DWORD* lpdwProcessId);
    HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
    BOOL CloseHandle(HANDLE hObject);
    BOOL QueryFullProcessImageNameW(HANDLE hProcess, DWORD dwFlags, unsigned short* lpExeName, DWORD* lpdwSize);
    int MultiByteToWideChar(UINT CodePage, DWORD dwFlags, const char* lpMultiByteStr, int cbMultiByte, unsigned short* lpWideCharStr, int cchWideChar);
    int WideCharToMultiByte(UINT CodePage, DWORD dwFlags, const unsigned short* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
    DWORD GetFileVersionInfoSizeW(LPCWSTR lptstrFilename, DWORD* lpdwHandle);
    BOOL GetFileVersionInfoW(LPCWSTR lptstrFilename, DWORD dwHandle, DWORD dwLen, void* lpData);
    BOOL VerQueryValueW(const void* pBlock, LPCWSTR lpSubBlock, void** lplpBuffer, UINT* puLen);
    HANDLE CreateFileW(LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
    HANDLE CreateFileMappingW(HANDLE, void*, DWORD, DWORD, DWORD, LPCWSTR);
    HANDLE OpenFileMappingW(DWORD, BOOL, LPCWSTR);
    void* MapViewOfFile(HANDLE, DWORD, DWORD, DWORD, SIZE_T);
    BOOL UnmapViewOfFile(void*);
]]

local kernel32 = ffi.load("kernel32")
local user32 = ffi.load("user32")
local version_dll = ffi.load("version")
local bridge_handle = nil
local bridge_view = nil
local bridge_hdr = nil

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

local function bridge_drain()
    if not bridge_hdr then return end
    bridge_hdr[1] = bridge_hdr[0]
end

local function bridge_read_one()
    if not bridge_hdr then return nil end
    local ws, rs = bridge_hdr[0], bridge_hdr[1]
    if rs >= ws then return nil end
    local idx = rs % BRIDGE_SLOTS
    local slot = ffi.cast("unsigned char*", bridge_view) + BRIDGE_HEADER + idx * BRIDGE_SLOT
    local len = ffi.cast("unsigned int*", slot)[0]
    if len == 0 or len > BRIDGE_SLOT - 4 then
        bridge_hdr[1] = rs + 1
        return nil
    end
    local buf = ffi.new("char[?]", len)
    ffi.copy(buf, slot + 4, len)
    bridge_hdr[1] = rs + 1
    return ffi.string(buf, len)
end

local function pr_is_active()
    local h = kernel32.OpenFileMappingW(0x0004, 0, bridge_wide(PR_NOTIFY_NAME))
    if h == nil or h == ffi.cast("HANDLE", 0) then
        return false
    end
    kernel32.CloseHandle(h)
    return true
end

local function status_open()
    if STATE.status_view then return true end
    STATE.status_handle = kernel32.CreateFileMappingW(ffi.cast("HANDLE", -1), nil, 0x04, 0, STATUS_SIZE, bridge_wide(STATUS_NAME))
    if STATE.status_handle == nil or STATE.status_handle == ffi.cast("HANDLE", 0) then
        STATE.status_handle = nil
        return false
    end
    STATE.status_view = kernel32.MapViewOfFile(STATE.status_handle, 0x000F001F, 0, 0, STATUS_SIZE)
    if STATE.status_view == nil then
        kernel32.CloseHandle(STATE.status_handle)
        STATE.status_handle = nil
        return false
    end
    STATE.status_hdr = ffi.cast("unsigned int*", STATE.status_view)
    STATE.status_hdr[0] = 1
    STATE.status_hdr[1] = CONFIG.enabled and 1 or 0
    STATE.status_hdr[2] = 0
    STATE.status_hdr[3] = 0
    return true
end

local function status_update()
    if not STATE.status_hdr then return end
    STATE.status_hdr[1] = CONFIG.enabled and 1 or 0
end

local function status_close()
    if STATE.status_view then
        kernel32.UnmapViewOfFile(STATE.status_view)
        STATE.status_view = nil
    end
    if STATE.status_handle then
        kernel32.CloseHandle(STATE.status_handle)
        STATE.status_handle = nil
    end
    STATE.status_hdr = nil
end

local function moved_open()
    if STATE.moved_view then return true end
    STATE.moved_handle = kernel32.CreateFileMappingW(ffi.cast("HANDLE", -1), nil, 0x04, 0, MOVED_TOTAL, bridge_wide(MOVED_NAME))
    if STATE.moved_handle == nil or STATE.moved_handle == ffi.cast("HANDLE", 0) then
        STATE.moved_handle = nil
        return false
    end
    STATE.moved_view = kernel32.MapViewOfFile(STATE.moved_handle, 0x000F001F, 0, 0, MOVED_TOTAL)
    if STATE.moved_view == nil then
        kernel32.CloseHandle(STATE.moved_handle)
        STATE.moved_handle = nil
        return false
    end
    STATE.moved_hdr = ffi.cast("unsigned int*", STATE.moved_view)
    return true
end

local function moved_write(path, info, status)
    if not STATE.moved_view or not STATE.moved_hdr then return end
    path = tostring(path or "")
    info = tostring(info or "")
    local plen, ilen = #path, #info
    if plen == 0 or plen > MOVED_PAYLOAD_MAX then return end
    if ilen > MOVED_PAYLOAD_MAX - plen then return end
    local ws = STATE.moved_hdr[0]
    local idx = ws % MOVED_SLOTS
    local slot = ffi.cast("unsigned char*", STATE.moved_view) + MOVED_HEADER + idx * MOVED_SLOT
    ffi.cast("unsigned int*", slot)[0] = plen
    ffi.cast("unsigned int*", slot + 4)[0] = ilen
    ffi.cast("unsigned int*", slot + 8)[0] = tonumber(status) or 0
    ffi.copy(slot + 12, path, plen)
    if ilen > 0 then
        ffi.copy(slot + 12 + plen, info, ilen)
    end
    STATE.moved_hdr[0] = ws + 1
end

local function moved_close()
    if STATE.moved_view then
        kernel32.UnmapViewOfFile(STATE.moved_view)
        STATE.moved_view = nil
    end
    if STATE.moved_handle then
        kernel32.CloseHandle(STATE.moved_handle)
        STATE.moved_handle = nil
    end
    STATE.moved_hdr = nil
end

local default_loc = nil
local current_loc = nil
local locale_initialized = false

local function load_locale_file(path)
    if not obs.obs_data_create_from_json_file then return nil end
    local ok, data = pcall(obs.obs_data_create_from_json_file, path)
    return ok and data or nil
end

local function init_locale()
    if locale_initialized then return end
    locale_initialized = true
    local source = type(script_path) == "function" and script_path() or nil
    local dir = source and source:match("(.*[/\\])") or ""
    local loc_dir = dir .. "locale/"
    local lang = "en-US"
    if obs.obs_get_locale then
        lang = obs.obs_get_locale() or lang
    end
    default_loc = load_locale_file(loc_dir .. "en-US " .. LOCALE_BASENAME .. ".json")
    current_loc = load_locale_file(loc_dir .. tostring(lang) .. " " .. LOCALE_BASENAME .. ".json")
        or load_locale_file(loc_dir .. tostring(lang):sub(1, 2) .. " " .. LOCALE_BASENAME .. ".json")
end

local function getString(key)
    init_locale()
    local value = current_loc and obs.obs_data_get_string(current_loc, key) or ""
    if value == "" and default_loc then
        value = obs.obs_data_get_string(default_loc, key)
    end
    return value ~= "" and value or key
end

local function now_ms()
    if obs.os_gettime_ns then
        local v = tonumber(obs.os_gettime_ns())
        if v then
            return v / 1000000
        end
    end
    return os.time() * 1000
end

local function invalid_handle(h)
    return h == nil or h == ffi.cast("HANDLE", 0) or h == ffi.cast("HANDLE", -1)
end

local function utf8_to_wide(value)
    if not value or value == "" then return nil end
    local ok, result = pcall(function()
        local length = kernel32.MultiByteToWideChar(CP_UTF8, 0, value, -1, nil, 0)
        if not length or length <= 0 or length > MAX_PATH_CHARS then return nil end
        local buffer = ffi.new("unsigned short[?]", length)
        if kernel32.MultiByteToWideChar(CP_UTF8, 0, value, -1, buffer, length) == 0 then return nil end
        return buffer
    end)
    return ok and result or nil
end

local function wide_to_utf8(pointer, length)
    if pointer == nil then return nil end
    length = tonumber(length) or 0
    if length <= 0 then return nil end
    local ok, result = pcall(function()
        local size = kernel32.WideCharToMultiByte(CP_UTF8, 0, pointer, length, nil, 0, nil, nil)
        if not size or size <= 0 or size > 65536 then return nil end
        local buffer = ffi.new("char[?]", size + 1)
        kernel32.WideCharToMultiByte(CP_UTF8, 0, pointer, length, buffer, size, nil, nil)
        return ffi.string(buffer, size)
    end)
    return ok and result or nil
end

local function wide_strlen(pointer, max_chars)
    if pointer == nil then return 0 end
    max_chars = tonumber(max_chars) or 0
    if max_chars <= 0 or max_chars > MAX_PATH_CHARS then
        max_chars = MAX_PATH_CHARS
    end
    for i = 0, max_chars - 1 do
        if pointer[i] == 0 then return i end
    end
    return max_chars
end

local function normalize_slashes(p)
    return (tostring(p or ""):gsub("\\", "/"))
end

local function dirname(p)
    p = normalize_slashes(p)
    return p:match("^(.*)/[^/]*$") or "."
end

local function basename(p)
    p = normalize_slashes(p)
    return p:match("([^/]*)$") or p
end

local function trim(v)
    return (tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_exe_name(v)
    local name = basename(trim(v))
    name = name:gsub("%.[eE][xX][eE]$", "")
    return name:lower()
end

local function utf8_truncate(value, max_bytes)
    if #value <= max_bytes then return value end
    local cut = max_bytes
    while cut > 0 do
        local byte = value:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    return value:sub(1, cut)
end

local function sanitize_folder_name(value)
    local name = trim(value)
    if name == "" then return nil end
    name = name:gsub("[<>:\"/\\|%?%*]", "_"):gsub("%c", "_")
    while name:match("[%. ]$") do
        name = name:sub(1, -2)
    end
    name = trim(name)
    if name == "" then return nil end
    local upper = name:upper()
    local stem = upper:match("^([^.]+)") or upper
    if stem == "CON" or stem == "PRN" or stem == "AUX" or stem == "NUL" or stem:match("^COM%d$") or stem:match("^LPT%d$") then
        name = "_" .. name
    end
    name = utf8_truncate(name, 120)
    while name:match("[%. ]$") do
        name = name:sub(1, -2)
    end
    name = trim(name)
    return name ~= "" and name or nil
end

local function file_exists(path)
    return obs.os_file_exists(path)
end

local function recursive_mkdir(path)
    path = normalize_slashes(path)
    local current = ""
    if path:sub(1, 2) == "//" then
        current = "//"
    elseif path:sub(1, 1) == "/" then
        current = "/"
    end
    for part in path:gmatch("[^/]+") do
        if part:match("^%a:$") and current == "" then
            current = part
        elseif current == "" or current == "/" or current == "//" then
            current = current .. part
        else
            current = current .. "/" .. part
        end
        if not file_exists(current) then
            obs.os_mkdir(current)
        end
    end
    return file_exists(path)
end

local function path_is_inside(path, directory)
    local source = normalize_slashes(path):lower()
    local target = normalize_slashes(directory):lower():gsub("/+$", "")
    return source == target or source:sub(1, #target + 1) == target .. "/"
end

local function uniquify_path(path)
    if not file_exists(path) then return path end
    local stem, extension = path:match("^(.*)(%.[^./\\]+)$")
    if not stem then
        stem, extension = path, ""
    end
    for index = 2, 999 do
        local candidate = stem .. " (" .. index .. ")" .. extension
        if not file_exists(candidate) then return candidate end
    end
    return stem .. " (" .. os.time() .. ")" .. extension
end

local function is_file_unlocked(path)
    local ok, result = pcall(function()
        local wpath = utf8_to_wide(normalize_slashes(path):gsub("/", "\\"))
        if not wpath then return true end
        local handle = kernel32.CreateFileW(wpath, FILE_READ_ATTRIBUTES, 0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nil)
        if invalid_handle(handle) then return false end
        kernel32.CloseHandle(handle)
        return true
    end)
    return ok and result or true
end

local function output_directory(output)
    if not output then return nil end
    local dir = nil
    local settings = obs.obs_output_get_settings(output)
    if settings then
        dir = obs.obs_data_get_string(settings, "directory")
        obs.obs_data_release(settings)
    end
    if dir == "" then dir = nil end
    return dir
end

local function replay_directory()
    local output = obs.obs_frontend_get_replay_buffer_output()
    if not output then return nil end
    local dir = output_directory(output)
    obs.obs_output_release(output)
    return dir
end

local function recording_directory()
    local output = obs.obs_frontend_get_recording_output()
    if not output then return nil end
    local dir = output_directory(output)
    obs.obs_output_release(output)
    return dir
end

local function profile_recording_directory()
    if not obs.obs_frontend_get_profile_config or not obs.config_get_string then return nil end
    local config = obs.obs_frontend_get_profile_config()
    if not config then return nil end
    local mode = obs.config_get_string(config, "Output", "Mode") or ""
    local dir = nil
    if mode:lower() == "advanced" then
        local record_type = obs.config_get_string(config, "AdvOut", "RecType") or ""
        if record_type ~= "Standard" then
            dir = obs.config_get_string(config, "AdvOut", "FFFilePath")
        else
            dir = obs.config_get_string(config, "AdvOut", "RecFilePath")
        end
    else
        dir = obs.config_get_string(config, "SimpleOutput", "FilePath")
    end
    if dir == "" then dir = nil end
    return dir
end

local function resolve_base_directory(media_type, file_path)
    local dir = nil
    if media_type == "screenshot" then
        dir = profile_recording_directory() or recording_directory()
    elseif media_type == "recording" then
        dir = recording_directory()
    else
        dir = replay_directory()
    end
    if not dir or dir == "" then
        dir = dirname(file_path)
    end
    return normalize_slashes(dir):gsub("/+$", "")
end

local product_cache = {}

local function get_product_name(executable_path)
    if not executable_path or executable_path == "" then return nil end
    local cached = product_cache[executable_path]
    if cached ~= nil then
        return cached == false and nil or cached
    end
    local ok, value = pcall(function()
        local wide_path = utf8_to_wide(executable_path)
        if not wide_path then return nil end
        local size_handle = ffi.new("DWORD[1]", 0)
        local size = tonumber(version_dll.GetFileVersionInfoSizeW(wide_path, size_handle)) or 0
        if size <= 0 or size > 16 * 1024 * 1024 then return nil end
        local data = ffi.new("unsigned char[?]", size)
        if version_dll.GetFileVersionInfoW(wide_path, 0, size, data) == 0 then return nil end
        local function query(sub_block)
            local wide_sub = utf8_to_wide(sub_block)
            if not wide_sub then return nil, 0 end
            local pointer = ffi.new("void*[1]")
            local length = ffi.new("UINT[1]")
            if version_dll.VerQueryValueW(data, wide_sub, pointer, length) == 0 or pointer[0] == nil then
                return nil, 0
            end
            return ffi.cast("unsigned short*", pointer[0]), tonumber(length[0]) or 0
        end
        local translations = {}
        local tptr, tlen = query("\\VarFileInfo\\Translation")
        if tptr and tlen >= 4 then
            local count = math.min(math.floor(tlen / 4), 64)
            for i = 0, count - 1 do
                translations[#translations + 1] = string.format("%04x%04x", tptr[i * 2], tptr[i * 2 + 1])
            end
        end
        translations[#translations + 1] = "040904b0"
        for _, code in ipairs(translations) do
            local vptr, vlen = query("\\StringFileInfo\\" .. code .. "\\ProductName")
            if vptr and vlen > 0 then
                local chars = wide_strlen(vptr, vlen)
                if chars > 0 then
                    local product = trim(wide_to_utf8(vptr, chars))
                    if product ~= "" then return product end
                end
            end
        end
        return nil
    end)
    if not ok or not value then
        product_cache[executable_path] = false
        return nil
    end
    product_cache[executable_path] = value
    return value
end

local function get_foreground_info()
    local ok, full_path, executable = pcall(function()
        local window = user32.GetForegroundWindow()
        if window == nil or window == ffi.cast("HWND", 0) then return nil end
        local pid_buf = ffi.new("DWORD[1]", 0)
        user32.GetWindowThreadProcessId(window, pid_buf)
        if pid_buf[0] == 0 then return nil end
        local process = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid_buf[0])
        if invalid_handle(process) then return nil end
        local buffer = ffi.new("unsigned short[?]", MAX_PATH_CHARS)
        local size = ffi.new("DWORD[1]", MAX_PATH_CHARS)
        local result = kernel32.QueryFullProcessImageNameW(process, 0, buffer, size)
        kernel32.CloseHandle(process)
        if result == 0 or size[0] == 0 then return nil end
        local path = wide_to_utf8(buffer, size[0])
        if not path or path == "" then return nil end
        return path, normalize_exe_name(path)
    end)
    if not ok or not full_path then return nil end
    return {full_path = full_path, exe = executable}
end

local function get_hooked_info(source)
    local handler = obs.obs_source_get_proc_handler(source)
    if not handler then return false, nil end
    local cd = obs.calldata_create()
    if not cd then return false, nil end
    local hooked, exe = false, nil
    pcall(function()
        if obs.proc_handler_call(handler, "get_hooked", cd) then
            if obs.calldata_bool then
                hooked = obs.calldata_bool(cd, "hooked") and true or false
            end
            if hooked then
                exe = obs.calldata_string(cd, "executable")
                if not exe or exe == "" then
                    exe = obs.calldata_string(cd, "hooked_exe")
                end
            end
        end
    end)
    obs.calldata_destroy(cd)
    return hooked, exe
end

local function exe_from_window_setting(window)
    if not window or window == "" then return nil end
    if not (window:lower():find(".exe", 1, true) or window:find("\\", 1, true) or window:find("/", 1, true)) then return nil end
    local bracketed = window:match("%[([^%]]+)%]")
    if bracketed and bracketed:lower():find(".exe", 1, true) then return bracketed end
    local candidate, fallback = nil, nil
    for segment in window:gmatch("[^:]+") do
        fallback = segment
        if segment:lower():find(".exe", 1, true) then
            candidate = segment
        end
    end
    candidate = candidate or fallback
    if not candidate then return nil end
    candidate = trim((candidate:gsub("^%s*%[", ""):gsub("%]%s*$", "")))
    return candidate ~= "" and candidate or nil
end

local function window_capture_exe(source)
    local hooked, exe = get_hooked_info(source)
    if hooked and exe and exe ~= "" then return exe end
    local settings = obs.obs_source_get_settings(source)
    if not settings then return nil end
    local window = obs.obs_data_get_string(settings, "window")
    if not window or window == "" then
        window = obs.obs_data_get_string(settings, "title")
    end
    obs.obs_data_release(settings)
    return exe_from_window_setting(window)
end

local function rebuild_captured_exes()
    local combined = {}
    for k in pairs(STATE.game_capture_exes) do combined[k] = true end
    for k in pairs(STATE.window_capture_exes) do combined[k] = true end
    STATE.captured_exes = combined
end

local function same_set(a, b)
    for k in pairs(a) do
        if not b[k] then return false end
    end
    for k in pairs(b) do
        if not a[k] then return false end
    end
    return true
end

local function refresh_window_capture_exes()
    local captured = {}
    local sources = obs.obs_enum_sources()
    if sources then
        for _, source in ipairs(sources) do
            pcall(function()
                if obs.obs_source_get_id(source) ~= "window_capture" then return end
                local active = true
                if obs.obs_source_active then
                    local ok_a, v = pcall(obs.obs_source_active, source)
                    if ok_a then active = v end
                end
                local width = tonumber(obs.obs_source_get_width(source)) or 0
                if not active or width <= 0 then return end
                local exe = window_capture_exe(source)
                if exe and exe ~= "" then
                    local name = normalize_exe_name(exe)
                    if name ~= "" then captured[name] = true end
                end
            end)
        end
        if obs.source_list_release then obs.source_list_release(sources) end
    end
    local changed = not same_set(STATE.window_capture_exes, captured)
    STATE.window_capture_exes = captured
    rebuild_captured_exes()
    return changed
end

local function compute_focus_context()
    local foreground = get_foreground_info()
    if not foreground or not foreground.exe then return { matched = false } end
    if not STATE.captured_exes[foreground.exe] then
        return {matched = false, exe = foreground.exe}
    end
    local product = get_product_name(foreground.full_path)
    local folder = product and sanitize_folder_name(product) or nil
    if not folder then
        local process_name = basename(foreground.full_path or ""):gsub("%.[eE][xX][eE]$", "")
        if process_name == "" then process_name = foreground.exe end
        folder = sanitize_folder_name(process_name)
    end
    return {matched = true, exe = foreground.exe, full_path = foreground.full_path, folder = folder}
end

local function snapshot_context()
    local focus = STATE.focus_context
    if not focus then
        focus = compute_focus_context()
    end
    if focus and focus.matched then
        return {known = true, matched = true, folder = focus.folder, exe = focus.exe}
    end
    return {known = true, matched = false}
end

local function focus_key(context)
    if context and context.matched then return "game:" .. tostring(context.exe) end
    return "desktop"
end

local function update_focus_if_changed()
    local hwnd = user32.GetForegroundWindow()
    if hwnd == nil or hwnd == ffi.cast("HWND", 0) then
        if STATE.focus_hwnd ~= hwnd then
            STATE.focus_hwnd = hwnd
            refresh_window_capture_exes()
            STATE.focus_context = {matched = false}
        end
        return
    end
    if hwnd == STATE.focus_hwnd then return end
    STATE.focus_hwnd = hwnd
    refresh_window_capture_exes()
    STATE.focus_context = compute_focus_context()
end

local function refresh_focus_now()
    STATE.focus_hwnd = nil
    update_focus_if_changed()
end

local function refresh_capture_if_due()
    local now = now_ms()
    if now - STATE.last_capture_refresh < CAPTURE_REFRESH_MS then return end
    STATE.last_capture_refresh = now
    if refresh_window_capture_exes() then
        STATE.focus_context = compute_focus_context()
    end
end

local function make_capture_callback(source)
    return function()
        local hooked, exe = get_hooked_info(source)
        local previous = STATE.source_exe[source]
        local changed = false
        if hooked and exe and exe ~= "" then
            local key = normalize_exe_name(exe)
            if key ~= "" and previous ~= key then
                if previous then STATE.game_capture_exes[previous] = nil end
                STATE.source_exe[source] = key
                STATE.game_capture_exes[key] = true
                changed = true
            end
        elseif previous then
            STATE.game_capture_exes[previous] = nil
            STATE.source_exe[source] = nil
            changed = true
        end
        if changed then
            rebuild_captured_exes()
            STATE.focus_hwnd = nil
            STATE.focus_context = compute_focus_context()
        end
    end
end

local function release_source_signals()
    for _, info in pairs(STATE.source_signals) do
        pcall(function()
            obs.signal_handler_disconnect(info.handler, "hooked", info.cb)
            obs.signal_handler_disconnect(info.handler, "unhooked", info.cb)
        end)
    end
    STATE.source_signals = {}
    STATE.source_exe = {}
    STATE.game_capture_exes = {}
    rebuild_captured_exes()
end

local function rescan_sources()
    release_source_signals()
    local sources = obs.obs_enum_sources()
    if sources then
        for _, source in ipairs(sources) do
            pcall(function()
                if obs.obs_source_get_id(source) ~= "game_capture" then return end
                local handler = obs.obs_source_get_signal_handler(source)
                if not handler then return end
                local cb = make_capture_callback(source)
                if obs.signal_handler_connect(handler, "hooked", cb) then
                    obs.signal_handler_connect(handler, "unhooked", cb)
                    STATE.source_signals[source] = { handler = handler, cb = cb }
                end
                local hooked, exe = get_hooked_info(source)
                if hooked and exe and exe ~= "" then
                    local key = normalize_exe_name(exe)
                    if key ~= "" then
                        STATE.source_exe[source] = key
                        STATE.game_capture_exes[key] = true
                    end
                end
            end)
        end
        if obs.source_list_release then obs.source_list_release(sources) end
    end
    rebuild_captured_exes()
    refresh_focus_now()
end

local function queue_file(path, media_type, context)
    if not CONFIG.enabled or not path or path == "" then return false end
    path = normalize_slashes(path)
    if STATE.seen[path] then return false end
    STATE.seen[path] = true
    STATE.queue[#STATE.queue + 1] = {path = path, media_type = media_type, context = context, deadline = now_ms() + MOVE_DEADLINE_MS, retry_at = 0}
    return true
end

local function process_file(job)
    local path = job.path
    if not file_exists(path) then return true end
    local context = job.context
    if not context or not context.known then
        context = snapshot_context()
        job.context = context
    end
    local folder = context.folder
    if context.matched and (not folder or folder == "") then
        local exe = context.exe
        if exe and exe ~= "" then
            local process_name = tostring(exe):gsub("%.[eE][xX][eE]$", "")
            folder = sanitize_folder_name(process_name)
        end
    end
    if not context.matched or not folder or folder == "" then
        folder = DESKTOP_FOLDER_NAME
    end
    local base = context.base_dir or resolve_base_directory(job.media_type, path)
    if not base or base == "" then base = dirname(path) end
    base = normalize_slashes(base):gsub("/+$", "")
    context.base_dir = base
    local target_directory = base .. "/" .. folder
    if path_is_inside(path, target_directory) then
        moved_write(path, folder, 1)
        return true
    end
    if not is_file_unlocked(path) then return false end
    if not file_exists(target_directory) then
        if not recursive_mkdir(target_directory) then return false end
    end
    local target = uniquify_path(target_directory .. "/" .. basename(path))
    local result = obs.os_rename(path, target)
    if result == 0 then
        moved_write(path, folder, 1)
        return true
    end
    if not file_exists(path) then
        moved_write(path, folder, 1)
        return true
    end
    return false
end

local function process_queue()
    local queue = STATE.queue
    if #queue == 0 then return end
    local now = now_ms()
    local index, processed = 1, 0
    while index <= #queue do
        local job = queue[index]
        if now > job.deadline then
            STATE.seen[job.path] = nil
            local info = "OBS"
            if job.context and job.context.base_dir then
                info = basename(job.context.base_dir)
            end
            moved_write(job.path, info, 0)
            table.remove(queue, index)
        elseif job.retry_at > now then
            index = index + 1
        else
            local ok, done = pcall(process_file, job)
            if not ok then
                STATE.seen[job.path] = nil
                local info = "OBS"
                if job.context and job.context.base_dir then
                    info = basename(job.context.base_dir)
                end
                moved_write(job.path, info, 0)
                table.remove(queue, index)
            elseif done then
                STATE.seen[job.path] = nil
                table.remove(queue, index)
            else
                job.retry_at = now + MOVE_RETRY_DELAY_MS
                index = index + 1
            end
            processed = processed + 1
            if processed >= MAX_QUEUE_PER_TICK then return end
        end
    end
end

local function read_bridge()
    if not bridge_hdr then
        if not bridge_open() then return end
    end
    while true do
        local path = bridge_read_one()
        if not path then break end
        if path ~= "" then
            local template = snapshot_context()
            queue_file(path, "child_replay", {known = true, matched = template.matched, folder = template.folder, exe = template.exe})
        end
    end
end

local function recording_active()
    return obs.obs_frontend_recording_active and obs.obs_frontend_recording_active() or false
end

local function recording_current_file(output)
    if not output then return nil end
    local path = nil
    local settings = obs.obs_output_get_settings(output)
    if settings then
        path = obs.obs_data_get_string(settings, "path")
        obs.obs_data_release(settings)
    end
    if not path or path == "" then
        local handler = obs.obs_output_get_proc_handler(output)
        if handler then
            local cd = obs.calldata_create()
            if cd then
                pcall(function()
                    if obs.proc_handler_call(handler, "get_last_file", cd) then
                        path = obs.calldata_string(cd, "path")
                    end
                end)
                obs.calldata_destroy(cd)
            end
        end
    end
    if not path or path == "" then return nil end
    if path:match("^[%a][%w+.-]*://") then return nil end
    return path
end

local on_recording_file_changed

local function disconnect_recording()
    if STATE.recording_signal_handler and obs.signal_handler_disconnect then
        pcall(obs.signal_handler_disconnect, STATE.recording_signal_handler, "file_changed", on_recording_file_changed)
    end
    if STATE.recording_output then pcall(obs.obs_output_release, STATE.recording_output) end
    STATE.recording_output = nil
    STATE.recording_signal_handler = nil
    STATE.current_recording_file = nil
end

local function recording_file_context(directory, allow_stale)
    local source = nil
    if STATE.auto_stop_context then
        source = STATE.auto_stop_context
    elseif CONFIG.auto_split and STATE.current_segment and (allow_stale or not STATE.baseline_refresh_pending) then
        source = STATE.current_segment
    else
        source = STATE.active_context
    end
    if source then
        return {known = true, matched = source.matched and true or false, folder = source.folder, exe = source.exe, base_dir = directory}
    end
    return { known = false, base_dir = directory }
end

on_recording_file_changed = function(calldata)
    pcall(function()
        local next_file = nil
        if calldata and obs.calldata_string then
            next_file = obs.calldata_string(calldata, "next_file")
        end
        if next_file and next_file:match("^[%a][%w+.-]*://") then next_file = nil end
        if not next_file or next_file == "" then
            next_file = recording_current_file(STATE.recording_output)
        end
        local previous = STATE.current_recording_file
        if previous and previous ~= "" and previous ~= next_file then
            queue_file(previous, "recording", recording_file_context(dirname(previous)))
        end
        STATE.current_recording_file = next_file
        if next_file and next_file ~= "" and next_file ~= previous and CONFIG.auto_split and not STATE.auto_stop_pending and not STATE.pending_auto_start then
            STATE.baseline_refresh_pending = true
        end
    end)
end

local function connect_recording()
    local output = obs.obs_frontend_get_recording_output()
    if not output then return false end
    disconnect_recording()
    local handler = obs.obs_output_get_signal_handler(output)
    if not handler then
        obs.obs_output_release(output)
        return false
    end
    obs.signal_handler_connect(handler, "file_changed", on_recording_file_changed)
    STATE.recording_output = output
    STATE.recording_signal_handler = handler
    STATE.current_recording_file = recording_current_file(output)
    return true
end

local function on_recording_started()
    local pending = STATE.pending_start_segment
    STATE.pending_start_segment = nil
    STATE.auto_stop_context = nil
    STATE.auto_stop_pending = false
    STATE.auto_stop_started_at = 0
    STATE.pending_auto_start = false
    STATE.auto_restart = false
    STATE.auto_start_attempts = 0
    STATE.auto_start_last_try = 0
    STATE.last_recording_check = 0
    STATE.baseline_refresh_pending = false
    connect_recording()
    if CONFIG.auto_split then
        if not pending then
            refresh_focus_now()
        end
        STATE.current_segment = pending or STATE.focus_context
        STATE.last_focus_key = focus_key(STATE.current_segment)
        STATE.auto_split_grace_until = pending and 0 or (now_ms() + AUTO_SPLIT_GRACE_MS)
        STATE.active_context = nil
    else
        STATE.current_segment = nil
        STATE.last_focus_key = nil
        STATE.auto_split_grace_until = 0
        refresh_focus_now()
        STATE.active_context = snapshot_context()
    end
end

local function on_recording_stopped()
    local path = obs.obs_frontend_get_last_recording()
    if not path or path == "" then
        path = STATE.current_recording_file
    end
    local context = nil
    if path and path ~= "" then
        context = recording_file_context(dirname(path), true)
    else
        local source = STATE.auto_stop_context or STATE.current_segment or STATE.active_context
        if source then
            context = {known = true, matched = source.matched and true or false, folder = source.folder, exe = source.exe}
        else
            context = { known = false }
        end
    end
    if path and path ~= "" then
        queue_file(path, "recording", context)
    end
    local restart = CONFIG.auto_split and STATE.auto_restart
    disconnect_recording()
    STATE.current_segment = nil
    STATE.active_context = nil
    STATE.auto_stop_context = nil
    STATE.auto_stop_pending = false
    STATE.auto_stop_started_at = 0
    STATE.auto_restart = false
    STATE.last_focus_key = nil
    STATE.auto_split_grace_until = 0
    STATE.baseline_refresh_pending = false
    if restart then
        STATE.pending_auto_start = true
        STATE.auto_start_attempts = 0
        STATE.auto_start_last_try = 0
    end
end

local function auto_split_tick()
    if not CONFIG.auto_split then return end
    local now = now_ms()
    if STATE.pending_auto_start then
        if recording_active() then
            STATE.pending_auto_start = false
            if STATE.pending_start_segment then
                STATE.current_segment = STATE.pending_start_segment
                STATE.pending_start_segment = nil
                STATE.last_focus_key = focus_key(STATE.current_segment)
                STATE.auto_split_grace_until = 0
            end
            return
        end
        if STATE.auto_start_attempts >= AUTO_START_MAX_ATTEMPTS then
            STATE.pending_auto_start = false
            STATE.pending_start_segment = nil
            STATE.auto_restart = false
            return
        end
        if now - STATE.auto_start_last_try >= AUTO_START_RETRY_MS then
            STATE.auto_start_last_try = now
            STATE.auto_start_attempts = STATE.auto_start_attempts + 1
            obs.obs_frontend_recording_start()
        end
        return
    end
    if not recording_active() then
        if STATE.auto_stop_pending and STATE.auto_stop_started_at > 0 and now - STATE.auto_stop_started_at >= AUTO_STOP_TIMEOUT_MS then
            local restart = STATE.auto_restart
            STATE.auto_stop_pending = false
            STATE.auto_stop_started_at = 0
            STATE.auto_stop_context = nil
            STATE.auto_restart = false
            if restart then
                STATE.pending_auto_start = true
                STATE.auto_start_attempts = 0
                STATE.auto_start_last_try = 0
            end
        end
        STATE.current_segment = nil
        STATE.last_focus_key = nil
        STATE.auto_split_grace_until = 0
        STATE.baseline_refresh_pending = false
        return
    end
    if STATE.auto_stop_pending then
        if STATE.auto_stop_started_at > 0 and now - STATE.auto_stop_started_at >= AUTO_STOP_TIMEOUT_MS then
            STATE.auto_stop_started_at = now
            obs.obs_frontend_recording_stop()
        end
        return
    end
    local focus = STATE.focus_context
    local key = focus_key(focus)
    if STATE.auto_split_grace_until > 0 then
        if now < STATE.auto_split_grace_until then
            if key ~= STATE.last_focus_key then
                STATE.current_segment = focus
                STATE.last_focus_key = key
            end
            return
        end
        STATE.auto_split_grace_until = 0
    end
    if not STATE.last_focus_key then
        STATE.last_focus_key = key
        STATE.current_segment = focus
        return
    end
    if key == STATE.last_focus_key then return end
    local previous = STATE.current_segment or { matched = false }
    STATE.last_focus_key = key
    if (focus and focus.matched) or previous.matched then
        STATE.auto_stop_context = {known = true, matched = previous.matched and true or false, folder = previous.folder, exe = previous.exe}
        STATE.pending_start_segment = focus
        STATE.auto_restart = true
        STATE.auto_stop_pending = true
        STATE.auto_stop_started_at = now
        obs.obs_frontend_recording_stop()
    else
        STATE.current_segment = focus
    end
end

local function recover_recording()
    if not STATE.recording_output then
        if connect_recording() then
            if CONFIG.auto_split and not STATE.current_segment then
                refresh_focus_now()
                STATE.current_segment = STATE.focus_context
                STATE.last_focus_key = focus_key(STATE.current_segment)
                STATE.auto_split_grace_until = now_ms() + AUTO_SPLIT_GRACE_MS
            elseif not CONFIG.auto_split and not STATE.active_context then
                STATE.active_context = snapshot_context()
            end
        end
    elseif not STATE.current_recording_file then
        STATE.current_recording_file = recording_current_file(STATE.recording_output)
    end
end

local function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        if CONFIG.enabled and recording_active() and not STATE.recording_output then
            on_recording_started()
        end
    elseif event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        if CONFIG.enabled then
            rescan_sources()
        end
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        if CONFIG.enabled then
            on_recording_started()
        end
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        if CONFIG.enabled then
            on_recording_stopped()
        end
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        if CONFIG.enabled and not pr_is_active() then
            local path = obs.obs_frontend_get_last_replay()
            if path and path ~= "" then
                STATE.pending_replay_path = path
                STATE.pending_replay_attempts = 0
            end
        end
    elseif event == obs.OBS_FRONTEND_EVENT_SCREENSHOT_TAKEN then
        if CONFIG.enabled then
            local path = obs.obs_frontend_get_last_screenshot()
            if path and path ~= "" then
                refresh_focus_now()
                queue_file(path, "screenshot", snapshot_context())
            end
        end
    elseif event == obs.OBS_FRONTEND_EVENT_EXIT then
        STATE.exiting = true
        disconnect_recording()
        STATE.pending_replay_path = nil
        STATE.pending_replay_attempts = 0
    end
end

local function read_settings(settings)
    if not settings then return end
    CONFIG.enabled = obs.obs_data_get_bool(settings, "enabled")
    CONFIG.auto_split = obs.obs_data_get_bool(settings, "auto_split")
end

function script_description()
    init_locale()
    return getString("ScriptDescription")
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "enabled", true)
    obs.obs_data_set_default_bool(settings, "auto_split", false)
end

function script_properties()
    init_locale()
    local props = obs.obs_properties_create()
    local m = obs.obs_properties_create()
    obs.obs_properties_add_bool(m, "enabled", getString("EnableSorting"))
    obs.obs_properties_add_bool(m, "auto_split", getString("AutoSplit"))
    obs.obs_properties_add_group(props, "group_management", getString("GroupManagement"), obs.OBS_GROUP_NORMAL, m)
    return props
end

function script_load(settings)
    init_locale()
    read_settings(settings)
    rescan_sources()
    if bridge_open() then
        bridge_drain()
    end
    status_open()
    moved_open()
    STATE.event_callback = function(event) pcall(on_frontend_event, event) end
    obs.obs_frontend_add_event_callback(STATE.event_callback)
    if CONFIG.enabled and recording_active() then
        on_recording_started()
    end
end

function script_update(settings)
    read_settings(settings)
    status_update()
    if not CONFIG.enabled then
        STATE.queue = {}
        STATE.seen = {}
        STATE.pending_replay_path = nil
        STATE.pending_replay_attempts = 0
        disconnect_recording()
        STATE.pending_auto_start = false
        STATE.pending_start_segment = nil
        STATE.auto_restart = false
        STATE.auto_start_attempts = 0
        STATE.auto_start_last_try = 0
        STATE.auto_stop_pending = false
        STATE.auto_stop_started_at = 0
        STATE.auto_stop_context = nil
        STATE.current_segment = nil
        STATE.active_context = nil
        STATE.last_focus_key = nil
        STATE.auto_split_grace_until = 0
        STATE.baseline_refresh_pending = false
        return
    end
    local active = recording_active()
    if active and not STATE.recording_output then
        on_recording_started()
    end
    if CONFIG.auto_split then
        STATE.active_context = nil
        if active and not STATE.current_segment then
            refresh_focus_now()
            STATE.current_segment = STATE.focus_context
            STATE.last_focus_key = focus_key(STATE.current_segment)
            STATE.auto_split_grace_until = now_ms() + AUTO_SPLIT_GRACE_MS
        end
    else
        STATE.pending_auto_start = false
        STATE.pending_start_segment = nil
        STATE.auto_restart = false
        STATE.auto_start_attempts = 0
        STATE.auto_start_last_try = 0
        STATE.current_segment = nil
        STATE.last_focus_key = nil
        STATE.auto_split_grace_until = 0
        STATE.baseline_refresh_pending = false
        if active then
            refresh_focus_now()
            STATE.active_context = snapshot_context()
        else
            STATE.active_context = nil
        end
    end
end

function script_save(settings)
    obs.obs_data_set_bool(settings, "enabled", CONFIG.enabled)
    obs.obs_data_set_bool(settings, "auto_split", CONFIG.auto_split)
end

function script_tick(seconds)
    if not CONFIG.enabled then
        if bridge_hdr then
            bridge_drain()
        end
        if #STATE.queue > 0 then
            STATE.queue = {}
        end
        STATE.pending_replay_path = nil
        STATE.pending_replay_attempts = 0
        return
    end
    if STATE.pending_replay_path then
        STATE.pending_replay_attempts = STATE.pending_replay_attempts + 1
        local path = STATE.pending_replay_path
        local ok, result = pcall(function()
            refresh_focus_now()
            local ctx = snapshot_context()
            return queue_file(path, "replay", ctx)
        end)
        if not ok then
            if STATE.pending_replay_attempts >= PENDING_REPLAY_MAX_ATTEMPTS then
                STATE.pending_replay_path = nil
                STATE.pending_replay_attempts = 0
            end
        elseif result then
            STATE.pending_replay_path = nil
            STATE.pending_replay_attempts = 0
        else
            STATE.pending_replay_path = nil
            STATE.pending_replay_attempts = 0
        end
    end
    pcall(update_focus_if_changed)
    local rb_active = obs.obs_frontend_replay_buffer_active and obs.obs_frontend_replay_buffer_active() or false
    if STATE.recording_output or rb_active then
        pcall(refresh_capture_if_due)
    end
    pcall(read_bridge)
    pcall(process_queue)
    local active = recording_active()
    if active then
        if STATE.recording_output and not CONFIG.auto_split then
            local focus = STATE.focus_context
            if focus and focus.matched then
                STATE.active_context = focus
            end
        end
        if not STATE.recording_output and now_ms() - STATE.last_recording_check >= 1000 then
            STATE.last_recording_check = now_ms()
            pcall(recover_recording)
        end
    end
    if STATE.baseline_refresh_pending then
        STATE.baseline_refresh_pending = false
        if CONFIG.auto_split and active then
            STATE.current_segment = STATE.focus_context
            STATE.last_focus_key = focus_key(STATE.current_segment)
        end
    end
    if CONFIG.auto_split then
        pcall(auto_split_tick)
    end
end

function script_unload()
    if STATE.event_callback then
        obs.obs_frontend_remove_event_callback(STATE.event_callback)
        STATE.event_callback = nil
    end
    disconnect_recording()
    release_source_signals()
    bridge_close()
    status_close()
    moved_close()
    STATE.queue = {}
    STATE.seen = {}
    STATE.pending_replay_path = nil
    STATE.pending_replay_attempts = 0
    STATE.focus_hwnd = nil
    STATE.focus_context = nil
    STATE.active_context = nil
    STATE.current_segment = nil
    STATE.last_focus_key = nil
    STATE.auto_stop_context = nil
    STATE.auto_stop_pending = false
    STATE.auto_stop_started_at = 0
    STATE.pending_auto_start = false
    STATE.pending_start_segment = nil
    STATE.auto_restart = false
    STATE.auto_split_grace_until = 0
    STATE.baseline_refresh_pending = false
end