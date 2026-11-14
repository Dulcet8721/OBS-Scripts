local obs = obslua
local ffi = require("ffi")

ffi.cdef[[
    typedef void* HANDLE;
    typedef int BOOL;
    typedef unsigned long DWORD;
    typedef unsigned int UINT;
    typedef unsigned short WORD;
    typedef unsigned char BYTE;
    typedef const unsigned short* LPCWSTR;
    typedef size_t SIZE_T;
    typedef struct _STARTUPINFOA {
        DWORD cb;
        char* lpReserved;
        char* lpDesktop;
        char* lpTitle;
        DWORD dwX; DWORD dwY; DWORD dwXSize; DWORD dwYSize;
        DWORD dwXCountChars; DWORD dwYCountChars; DWORD dwFillAttribute;
        DWORD dwFlags;
        WORD wShowWindow; WORD cbReserved2;
        BYTE* lpReserved2;
        HANDLE hStdInput; HANDLE hStdOutput; HANDLE hStdError;
    } STARTUPINFOA;
    typedef struct _PROCESS_INFORMATION {
        HANDLE hProcess; HANDLE hThread;
        DWORD dwProcessId; DWORD dwThreadId;
    } PROCESS_INFORMATION;
    typedef struct _SECURITY_ATTRIBUTES {
        DWORD nLength; void* lpSecurityDescriptor; BOOL bInheritHandle;
    } SECURITY_ATTRIBUTES;
    HANDLE CreateFileA(const char* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
    BOOL CreateProcessA(const char* lpApplicationName, char* lpCommandLine, void* lpProcessAttributes, void* lpThreadAttributes, BOOL bInheritHandles, DWORD dwCreationFlags, void* lpEnvironment, const char* lpCurrentDirectory, STARTUPINFOA* lpStartupInfo, PROCESS_INFORMATION* lpProcessInformation);
    BOOL CreatePipe(HANDLE* hReadPipe, HANDLE* hWritePipe, SECURITY_ATTRIBUTES* lpPipeAttributes, DWORD nSize);
    BOOL PeekNamedPipe(HANDLE hNamedPipe, void* lpBuffer, DWORD nBufferSize, DWORD* lpBytesRead, DWORD* lpTotalBytesAvail, DWORD* lpBytesLeftThisMessage);
    BOOL ReadFile(HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, void* lpOverlapped);
    DWORD GetExitCodeProcess(HANDLE hProcess, DWORD* lpExitCode);
    BOOL TerminateProcess(HANDLE hProcess, UINT uExitCode);
    DWORD GetLastError(void);
    BOOL CloseHandle(HANDLE hObject);
    HANDLE CreateFileMappingW(HANDLE, void*, DWORD, DWORD, DWORD, LPCWSTR);
    HANDLE OpenFileMappingW(DWORD, BOOL, LPCWSTR);
    void* MapViewOfFile(HANDLE, DWORD, DWORD, DWORD, SIZE_T);
    BOOL UnmapViewOfFile(void*);
]]

local kernel32 = ffi.load("kernel32")
local CREATE_NO_WINDOW = 0x08000000
local STARTF_USESTDHANDLES = 0x00000100
local STILL_ACTIVE = 259
local GENERIC_WRITE = 0x40000000
local FILE_SHARE_READ = 0x00000001
local FILE_SHARE_WRITE = 0x00000002
local OPEN_EXISTING = 3
local NULL_HANDLE = ffi.cast("HANDLE", 0)
local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)
local LOCALE_NAME = "Trim Replay"
local DEFAULT_DURATIONS = { 30, 60, 120 }
local UI_MAX_SECONDS = 3600
local MAX_SAVE_QUEUE = 32
local SAVE_TIMEOUT_MS = 120000
local BRIDGE_NAME = "Local\\OBS_SFO_Bridge_v1"
local BRIDGE_HEADER = 8
local BRIDGE_SLOT = 1024
local BRIDGE_SLOTS = 128
local BRIDGE_TOTAL = BRIDGE_HEADER + BRIDGE_SLOT * BRIDGE_SLOTS
local TR_NOTIFY_NAME = "Local\\OBS_TR_Notify_v1"
local TR_NOTIFY_HEADER = 8
local TR_NOTIFY_SLOT = 1024
local TR_NOTIFY_SLOTS = 128
local TR_NOTIFY_TOTAL = TR_NOTIFY_HEADER + TR_NOTIFY_SLOT * TR_NOTIFY_SLOTS
local TR_NOTIFY_PAYLOAD_MAX = TR_NOTIFY_SLOT - 8
local TR_STATUS_NAME = "Local\\OBS_TR_Status_v1"
local TR_STATUS_SIZE = 16
local PR_STATUS_NAME = "Local\\OBS_PR_Status_v1"
local PR_STATUS_SIZE = 16
local enabled = true
local effective_enabled = false
local reset_enabled = true
local durations = {30, 60, 120}
local main_limit = nil
local last_save_end_time = nil
local save_queue = {}
local current_save = nil
local pending_main_save = nil
local trim_queue = {}
local active_job = nil
local ffprobe_exe = ""
local ffmpeg_exe = ""
local ffmpeg_autodetect_done = false
local ffprobe_autodetect_done = false
local nul_handle = nil
local hotkey_ids = {}
local bridge_handle, bridge_view, bridge_hdr = nil, nil, nil
local tr_notify_handle, tr_notify_view, tr_notify_hdr = nil, nil, nil
local tr_status_handle, tr_status_view, tr_status_hdr = nil, nil, nil
local default_loc = nil
local current_loc = nil

local function getString(key)
    local s = current_loc and obs.obs_data_get_string(current_loc, key) or ""
    if s == "" and default_loc then s = obs.obs_data_get_string(default_loc, key) end
    return (s ~= "") and s or key
end

local function init_locale()
    if default_loc then return end
    local dir = script_path():match("(.*[/\\])") or ""
    local loc_dir = dir .. "locale/"
    local lang = obs.obs_get_locale() or "en-US"
    default_loc  = obs.obs_data_create_from_json_file(loc_dir .. "en-US " .. LOCALE_NAME .. ".json")
    current_loc  = obs.obs_data_create_from_json_file(loc_dir .. lang .. " " .. LOCALE_NAME .. ".json")
        or obs.obs_data_create_from_json_file(loc_dir .. lang:sub(1,2) .. " " .. LOCALE_NAME .. ".json")
end

local function tr(key, ...)
    init_locale()
    local v = getString(key)
    if select("#", ...) > 0 then return string.format(v, ...) end
    return v
end

local function now_ms()
    if obs.os_gettime_ns then
        local v = tonumber(obs.os_gettime_ns())
        if v then return v / 1000000 end
    end
    return os.time() * 1000
end

local function file_exists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function basename(p)
    return p and p:match("[^/\\]+$") or ""
end

local function is_tool_name(path, name)
    return basename(path):lower() == name:lower()
end

local function find_in_path(exe_name)
    local env = os.getenv("PATH")
    if not env then return nil end
    for dir in env:gmatch("[^;]+") do
        dir = dir:gsub("^%s+", ""):gsub("%s+$", "")
        if dir ~= "" then
            local candidate = dir .. "\\" .. exe_name
            local f = io.open(candidate, "r")
            if f then f:close(); return candidate end
        end
    end
    return nil
end

local function find_next_to_script(exe_name)
    local d = script_path():match("(.*[/\\])") or ""
    local candidate = d .. exe_name
    local f = io.open(candidate, "r")
    if f then f:close(); return candidate end
    return nil
end

local function autodetect_exe(exe_name)
    return find_in_path(exe_name) or find_next_to_script(exe_name)
end

local function valid_tool_path(path, expected_name)
    return path and path ~= "" and is_tool_name(path, expected_name) and file_exists(path)
end

local function get_file_size(path)
    if not path or path == "" then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:seek("end")
    f:close()
    return s
end

local function delete_file(path)
    if path and path ~= "" then os.remove(path) end
end

local function get_last_replay_path(output)
    if not output then return nil end
    local ok, path = pcall(function()
        local ph = obs.obs_output_get_proc_handler(output)
        if not ph then return nil end
        local cd = obs.calldata_create()
        if not cd then return nil end
        local call_ok = obs.proc_handler_call(ph, "get_last_replay", cd)
        local v = call_ok and obs.calldata_string(cd, "path") or nil
        obs.calldata_destroy(cd)
        return v
    end)
    return ok and path or nil
end

local function bridge_wide(s)
    local b = ffi.new("unsigned short[?]", #s + 1)
    for i = 1, #s do b[i-1] = s:byte(i) end
    b[#s] = 0
    return b
end

local function bridge_open()
    if bridge_view then return true end
    bridge_handle = kernel32.CreateFileMappingW(ffi.cast("HANDLE", -1), nil, 0x04, 0, BRIDGE_TOTAL, bridge_wide(BRIDGE_NAME))
    if bridge_handle == nil or bridge_handle == ffi.cast("HANDLE", 0) then bridge_handle = nil; return false end
    bridge_view = kernel32.MapViewOfFile(bridge_handle, 0x000F001F, 0, 0, BRIDGE_TOTAL)
    if bridge_view == nil then kernel32.CloseHandle(bridge_handle); bridge_handle = nil; return false end
    bridge_hdr = ffi.cast("unsigned int*", bridge_view)
    return true
end

local function bridge_close()
    if bridge_view then kernel32.UnmapViewOfFile(bridge_view); bridge_view = nil end
    if bridge_handle then kernel32.CloseHandle(bridge_handle); bridge_handle = nil end
    bridge_hdr = nil
end

local function bridge_write(path)
    if not bridge_view or not bridge_hdr then
        if not bridge_open() then return false end
    end
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

local function tr_notify_open()
    if tr_notify_view then return true end
    tr_notify_handle = kernel32.CreateFileMappingW(ffi.cast("HANDLE", -1), nil, 0x04, 0, TR_NOTIFY_TOTAL, bridge_wide(TR_NOTIFY_NAME))
    if tr_notify_handle == nil or tr_notify_handle == ffi.cast("HANDLE", 0) then tr_notify_handle = nil; return false end
    tr_notify_view = kernel32.MapViewOfFile(tr_notify_handle, 0x000F001F, 0, 0, TR_NOTIFY_TOTAL)
    if tr_notify_view == nil then kernel32.CloseHandle(tr_notify_handle); tr_notify_handle = nil; return false end
    tr_notify_hdr = ffi.cast("unsigned int*", tr_notify_view)
    return true
end

local function tr_notify_close()
    if tr_notify_view then kernel32.UnmapViewOfFile(tr_notify_view); tr_notify_view = nil end
    if tr_notify_handle then kernel32.CloseHandle(tr_notify_handle); tr_notify_handle = nil end
    tr_notify_hdr = nil
end

local function tr_notify_write(path, duration_sec)
    if not tr_notify_view or not tr_notify_hdr then
        if not tr_notify_open() then return end
    end
    path = tostring(path or "")
    duration_sec = tonumber(duration_sec) or 0
    local plen = #path
    if plen == 0 or plen > TR_NOTIFY_PAYLOAD_MAX then return end
    local ws = tr_notify_hdr[0]
    local idx = ws % TR_NOTIFY_SLOTS
    local slot = ffi.cast("unsigned char*", tr_notify_view) + TR_NOTIFY_HEADER + idx * TR_NOTIFY_SLOT
    ffi.cast("unsigned int*", slot)[0] = math.floor(duration_sec)
    ffi.cast("unsigned int*", slot + 4)[0] = plen
    ffi.copy(slot + 8, path, plen)
    tr_notify_hdr[0] = ws + 1
end

local function tr_status_open()
    if tr_status_view then return true end
    tr_status_handle = kernel32.CreateFileMappingW(ffi.cast("HANDLE", -1), nil, 0x04, 0, TR_STATUS_SIZE, bridge_wide(TR_STATUS_NAME))
    if tr_status_handle == nil or tr_status_handle == ffi.cast("HANDLE", 0) then tr_status_handle = nil; return false end
    tr_status_view = kernel32.MapViewOfFile(tr_status_handle, 0x000F001F, 0, 0, TR_STATUS_SIZE)
    if tr_status_view == nil then kernel32.CloseHandle(tr_status_handle); tr_status_handle = nil; return false end
    tr_status_hdr = ffi.cast("unsigned int*", tr_status_view)
    tr_status_hdr[0] = 1
    tr_status_hdr[1] = enabled and 1 or 0
    tr_status_hdr[2] = 0
    tr_status_hdr[3] = 0
    return true
end

local function tr_status_update()
    if not tr_status_hdr then return end
    tr_status_hdr[1] = enabled and 1 or 0
    tr_status_hdr[2] = effective_enabled and 1 or 0
    tr_status_hdr[3] = 0
end

local function tr_status_close()
    if tr_status_view then kernel32.UnmapViewOfFile(tr_status_view); tr_status_view = nil end
    if tr_status_handle then kernel32.CloseHandle(tr_status_handle); tr_status_handle = nil end
    tr_status_hdr = nil
end

local function pr_status_read()
    local h = kernel32.OpenFileMappingW(0x0004, 0, bridge_wide(PR_STATUS_NAME))
    if h == nil or h == ffi.cast("HANDLE", 0) then
        return {live = false, enabled = false, dangerous = false}
    end
    local v = kernel32.MapViewOfFile(h, 0x0004, 0, 0, PR_STATUS_SIZE)
    if v == nil then
        kernel32.CloseHandle(h)
        return {live = false, enabled = false, dangerous = false}
    end
    local hdr = ffi.cast("unsigned int*", v)
    local version = tonumber(hdr[0])
    local en = tonumber(hdr[1])
    local dangerous = tonumber(hdr[3])
    kernel32.UnmapViewOfFile(v)
    kernel32.CloseHandle(h)
    if version ~= 1 then
        return {live = false, enabled = false, dangerous = false}
    end
    return {live = true, enabled = en == 1, dangerous = dangerous == 1}
end

local function refresh_effective()
    local pr = pr_status_read()
    local mutual = pr.live and pr.enabled and pr.dangerous
    local new_eff = enabled and not mutual
    local changed = (new_eff ~= effective_enabled)
    effective_enabled = new_eff
    tr_status_update()
    if not changed then return end
    if not new_eff then
        save_queue = {}
        current_save = nil
        pending_main_save = nil
        trim_queue = {}
        if active_job then
            if active_job.stage_pipe then kernel32.CloseHandle(active_job.stage_pipe) end
            if active_job.stage_proc then
                kernel32.TerminateProcess(active_job.stage_proc, 1)
                kernel32.CloseHandle(active_job.stage_proc)
            end
            active_job = nil
        end
    end
end

local function is_valid_handle(h)
    return h ~= nil and h ~= NULL_HANDLE and h ~= INVALID_HANDLE_VALUE
end

local function ensure_nul_handle()
    if is_valid_handle(nul_handle) then return nul_handle end
    local sa = ffi.new("SECURITY_ATTRIBUTES[1]")
    sa[0].nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
    sa[0].lpSecurityDescriptor = nil
    sa[0].bInheritHandle = 1
    local h = kernel32.CreateFileA("NUL", GENERIC_WRITE, ffi.cast("DWORD", FILE_SHARE_READ + FILE_SHARE_WRITE), sa, OPEN_EXISTING, 0, nil)
    if not is_valid_handle(h) then return nil end
    nul_handle = h
    return nul_handle
end

local function spawn_hidden(cmdline)
    if not cmdline or #cmdline == 0 then return nil end
    ensure_nul_handle()
    local si = ffi.new("STARTUPINFOA[1]")
    si[0].cb = ffi.sizeof("STARTUPINFOA")
    if nul_handle ~= nil then
        si[0].dwFlags = STARTF_USESTDHANDLES
        si[0].hStdInput  = nul_handle
        si[0].hStdOutput = nul_handle
        si[0].hStdError  = nul_handle
    end
    local buf = ffi.new("char[?]", #cmdline + 1)
    ffi.copy(buf, cmdline)
    local pi = ffi.new("PROCESS_INFORMATION[1]")
    local inherit = (nul_handle ~= nil) and 1 or 0
    local ok = kernel32.CreateProcessA(nil, buf, nil, nil, inherit, CREATE_NO_WINDOW, nil, nil, si, pi)
    if ok == 0 then return nil end
    kernel32.CloseHandle(pi[0].hThread)
    return pi[0].hProcess
end

local function spawn_with_pipe(cmdline)
    if not cmdline or #cmdline == 0 then return nil end
    ensure_nul_handle()
    local sa = ffi.new("SECURITY_ATTRIBUTES[1]")
    sa[0].nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
    sa[0].lpSecurityDescriptor = nil
    sa[0].bInheritHandle = 1
    local rh = ffi.new("HANDLE[1]")
    local wh = ffi.new("HANDLE[1]")
    if kernel32.CreatePipe(rh, wh, sa, 0) == 0 then return nil end
    local si = ffi.new("STARTUPINFOA[1]")
    si[0].cb = ffi.sizeof("STARTUPINFOA")
    si[0].dwFlags = STARTF_USESTDHANDLES
    si[0].hStdInput  = nul_handle or INVALID_HANDLE_VALUE
    si[0].hStdOutput = wh[0]
    si[0].hStdError  = wh[0]
    local buf = ffi.new("char[?]", #cmdline + 1)
    ffi.copy(buf, cmdline)
    local pi = ffi.new("PROCESS_INFORMATION[1]")
    local ok = kernel32.CreateProcessA(nil, buf, nil, nil, 1, CREATE_NO_WINDOW, nil, nil, si, pi)
    kernel32.CloseHandle(wh[0])
    if ok == 0 then
        kernel32.CloseHandle(rh[0])
        return nil
    end
    kernel32.CloseHandle(pi[0].hThread)
    return pi[0].hProcess, rh[0]
end

local function poll_process(h)
    local buf = ffi.new("DWORD[1]")
    if kernel32.GetExitCodeProcess(h, buf) == 0 then return "error" end
    local code = tonumber(buf[0])
    if code == STILL_ACTIVE then return "running" end
    if code == 0 then return "ok" end
    return "failed"
end

local function close_process(h) if is_valid_handle(h) then kernel32.CloseHandle(h) end end
local function kill_process(h)  if is_valid_handle(h) then kernel32.TerminateProcess(h, 1) end end

local function read_available(pipe_h)
    if not is_valid_handle(pipe_h) then return "", true end
    local avail = ffi.new("DWORD[1]")
    local ok = kernel32.PeekNamedPipe(pipe_h, nil, 0, nil, avail, nil)
    if ok == 0 then return "", true end
    local n = tonumber(avail[0])
    if n == 0 then return "", false end
    local buf = ffi.new("char[?]", n)
    local read = ffi.new("DWORD[1]")
    if kernel32.ReadFile(pipe_h, buf, n, read, nil) == 0 then return "", true end
    return ffi.string(buf, tonumber(read[0])), false
end

local function drain_pipe(job)
    if not is_valid_handle(job.stage_pipe) then return true end
    while true do
        local data, eof = read_available(job.stage_pipe)
        if data and #data > 0 then job.stage_output = job.stage_output .. data end
        if eof then return true end
        if not data or #data == 0 then return false end
    end
end

local function build_trim_path(source_path, duration)
    local dir, filename = source_path:match("^(.*[/\\])(.-)$")
    if not dir then dir = ""; filename = source_path end
    local base, ext = filename:match("^(.-)%.([^%.]+)$")
    if not base then base = filename; ext = "" end
    if ext == "" then return dir .. base .. "_" .. duration .. "s" end
    return dir .. base .. "_" .. duration .. "s." .. ext
end

local function build_main_trim_path(source_path)
    local dir, filename = source_path:match("^(.*[/\\])(.-)$")
    if not dir then dir = ""; filename = source_path end
    local base, ext = filename:match("^(.-)%.([^%.]+)$")
    if not base then return dir .. filename .. "_new" end
    return dir .. base .. "_new." .. ext
end

local function frontend_active()
    return obs.obs_frontend_replay_buffer_active and obs.obs_frontend_replay_buffer_active() or false
end

local function get_main_limit()
    local active = frontend_active()
    local output_limit, output_known = nil, false
    local main = obs.obs_frontend_get_replay_buffer_output()
    if main then
        local settings = obs.obs_output_get_settings(main)
        if settings then
            output_known = true
            local l = obs.obs_data_get_int(settings, "max_time_sec")
            if l and l > 0 then output_limit = l end
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
                local sec = obs.config_get_int(config, section, "RecRBTime")
                if sec and sec > 0 then return sec end
            end
        end
    end
    return output_limit
end

local function clip_is_valid(slot)
    local d = durations[slot]
    if not d or d <= 0 then return false end
    if main_limit and main_limit > 0 and d >= main_limit then return false end
    return true
end

local function hotkey_value_label(slot)
    if clip_is_valid(slot) then
        return tr("SecondsFormat", durations[slot])
    end
    return tr("Disabled")
end

local function update_hotkey_descriptions()
    for slot = 1, 3 do
        if hotkey_ids[slot] then
            obs.obs_hotkey_set_description(hotkey_ids[slot], tr("HotkeySave", slot, hotkey_value_label(slot)))
        end
    end
end

local function try_next_save()
    if current_save then return end
    if #save_queue == 0 then return end
    if not effective_enabled then
        save_queue = {}
        return
    end
    if not frontend_active() then
        save_queue = {}
        return
    end
    local item = table.remove(save_queue, 1)
    current_save = {slot = item.slot, T_save = item.T_save, requested_at = now_ms()}
    obs.obs_frontend_replay_buffer_save()
end

local function enqueue_save(slot)
    if #save_queue >= MAX_SAVE_QUEUE then return end
    table.insert(save_queue, { slot = slot, T_save = now_ms() })
    try_next_save()
end

local function begin_job_probe_duration(job)
    local clean = ffprobe_exe:gsub("/", "\\")
    local input = job.path:gsub("/", "\\")
    local cmd = '"' .. clean .. '" -v error -show_entries format=duration -of csv=p=0 "' .. input .. '"'
    local h, pipe = spawn_with_pipe(cmd)
    if not h then
        job.phase = "failed"; return
    end
    job.stage_proc = h
    job.stage_pipe = pipe
    job.stage_output = ""
    job.phase = "probe_duration"
end

local function begin_job_probe_keyframes(job)
    local clean = ffprobe_exe:gsub("/", "\\")
    local input = job.path:gsub("/", "\\")
    local cmd = '"' .. clean .. '" -v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 "' .. input .. '"'
    local h, pipe = spawn_with_pipe(cmd)
    if not h then
        job.phase = "failed"; return
    end
    job.stage_proc = h
    job.stage_pipe = pipe
    job.stage_output = ""
    job.phase = "probe_keyframes"
end

local function begin_job_ffmpeg(job, aligned_start, clip_duration)
    if job.is_main and aligned_start <= 0.001 then
        job.keep_source = true
        job.expected_duration = job.source_duration or clip_duration
        job.phase = "done"
        return
    end
    if job.is_main then
        job.output_path = build_main_trim_path(job.path)
    else
        job.output_path = build_trim_path(job.path, job.duration)
    end
    job.expected_duration = clip_duration
    local clean_ffmpeg = ffmpeg_exe:gsub("/", "\\")
    local clean_input  = job.path:gsub("/", "\\")
    local clean_output = job.output_path:gsub("/", "\\")
    local seek_arg = ""
    if aligned_start > 0.001 then
        seek_arg = string.format("-ss %.3f ", aligned_start)
    end
    local cmd = string.format(
        '"%s" -y -i "%s" %s-t %.3f -map 0:v:0 -map 0:a? -c copy -avoid_negative_ts make_zero -movflags +faststart "%s"',
        clean_ffmpeg, clean_input, seek_arg, clip_duration, clean_output)
    local h = spawn_hidden(cmd)
    if not h then
        job.phase = "failed"; return
    end
    job.stage_proc = h
    job.stage_pipe = nil
    job.stage_output = ""
    job.phase = "ffmpeg"
end

local function handle_probe_duration_done(job)
    local v = job.stage_output:match("([%d%.]+)")
    local dur = tonumber(v)
    if not dur or dur <= 0 then
        job.phase = "failed"; return
    end
    job.source_duration = dur
    begin_job_probe_keyframes(job)
end

local function handle_probe_keyframes_done(job)
    local kf = {}
    for line in job.stage_output:gmatch("[^\r\n]+") do
        local pts, flags = nil, nil
        for f in line:gmatch("[^,]+") do
            if not pts and f:match("^%-?%d+%.?%d*$") then
                pts = tonumber(f)
            elseif not flags and f:match("^[A-Za-z_]+$") then
                flags = f
            end
        end
        if pts and flags and flags:find("K") then kf[#kf+1] = pts end
    end
    if #kf == 0 then
        job.phase = "failed"; return
    end
    table.sort(kf)
    local source_duration = job.source_duration
    local duration = job.duration
    local T_save = job.T_saving or job.T_save
    local target_start
    if job.is_main then
        target_start = 0
    else
        target_start = source_duration - duration
        if target_start < 0 then target_start = 0 end
    end
    if reset_enabled and last_save_end_time then
        local source_start_wall = T_save - source_duration * 1000
        local last_end_src = (last_save_end_time - source_start_wall) / 1000
        if last_end_src > target_start then
            target_start = last_end_src
        end
    end
    if target_start >= source_duration - 0.05 then
        if job.is_main then
            job.keep_source = true
            job.expected_duration = source_duration
            job.phase = "done"
            return
        else
            job.phase = "failed"; return
        end
    end
    if target_start < 0 then target_start = 0 end
    local best = nil
    for _, t in ipairs(kf) do
        if t <= target_start + 0.001 then best = t else break end
    end
    if best == nil then best = kf[1] end
    local aligned_start = best
    local clip_duration = source_duration - aligned_start
    begin_job_ffmpeg(job, aligned_start, clip_duration)
end

local function handle_ffmpeg_done(job)
    local size = get_file_size(job.output_path)
    if not size or size < 1024 then
        job.phase = "failed"; return
    end
    job.phase = "done"
end

local function finish_trim_job(job, success)
    if success then
        local final_path
        if job.is_main then
            if job.keep_source then
                final_path = job.path
            else
                delete_file(job.path)
                local ok = os.rename(job.output_path, job.path)
                if ok and file_exists(job.path) then
                    final_path = job.path
                else
                    final_path = job.output_path
                end
            end
        else
            if job.path and job.path ~= job.output_path then
                delete_file(job.path)
            end
            final_path = job.output_path
        end
        if effective_enabled and final_path and file_exists(final_path) then
            bridge_write(final_path)
            local notify_duration = job.is_main and 0 or (job.duration or 0)
            tr_notify_write(final_path, notify_duration)
        end
        if reset_enabled then
            last_save_end_time = job.T_saving or job.T_save
        end
    else
        if job.output_path and job.output_path ~= job.path then
            delete_file(job.output_path)
        end
    end
    active_job = nil
end

local function tick_active_job()
    if not active_job then return end
    local job = active_job
    if job.phase == "failed" then finish_trim_job(job, false); return end
    if job.phase == "done"   then finish_trim_job(job, true);  return end
    if not job.stage_proc then return end
    local pipe_eof = false
    if job.stage_pipe then pipe_eof = drain_pipe(job) end
    local status = poll_process(job.stage_proc)
    if status == "running" then return end
    if job.stage_pipe and not pipe_eof then drain_pipe(job) end
    if job.stage_pipe then close_process(job.stage_pipe); job.stage_pipe = nil end
    close_process(job.stage_proc)
    job.stage_proc = nil
    if status ~= "ok" then
        if job.phase == "probe_duration" then
            handle_probe_duration_done(job)
        elseif job.phase == "probe_keyframes" then
            handle_probe_keyframes_done(job)
        elseif job.phase == "ffmpeg" then
            job.phase = "failed"
        end
        return
    end
    if job.phase == "probe_duration" then
        handle_probe_duration_done(job)
    elseif job.phase == "probe_keyframes" then
        handle_probe_keyframes_done(job)
    elseif job.phase == "ffmpeg" then
        handle_ffmpeg_done(job)
    end
end

local function enqueue_trim(path, slot, duration, T_save, T_saving, is_main)
    if not effective_enabled then return end
    if not path or path == "" then return end
    if not file_exists(path) then return end
    table.insert(trim_queue, {path = path, slot = slot, duration = duration, T_save = T_save, T_saving = T_saving, is_main = is_main or false, phase = "pending"})
end

local function try_next_trim()
    if active_job then return end
    if #trim_queue == 0 then return end
    active_job = table.remove(trim_queue, 1)
    if not valid_tool_path(ffmpeg_exe, "ffmpeg.exe") or not valid_tool_path(ffprobe_exe, "ffprobe.exe") then
        active_job.phase = "failed"
        return
    end
    local size = get_file_size(active_job.path)
    if not size or size < 1024 then
        active_job.phase = "failed"
        return
    end
    begin_job_probe_duration(active_job)
end

local event_callback = nil

local function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        refresh_effective()
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then
        last_save_end_time = nil
        main_limit = get_main_limit()
        update_hotkey_descriptions()
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED then
        main_limit = get_main_limit()
        update_hotkey_descriptions()
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING then
        if not effective_enabled then return end
        if current_save then
            current_save.T_saving = now_ms()
        else
            pending_main_save = {T_save = now_ms(), T_saving = now_ms()}
        end
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        if not effective_enabled then
            current_save = nil
            pending_main_save = nil
            return
        end
        if current_save then
            local item = current_save
            current_save = nil
            local main = obs.obs_frontend_get_replay_buffer_output()
            local path = get_last_replay_path(main)
            if main then obs.obs_output_release(main) end
            if path and path ~= "" then
                enqueue_trim(path, item.slot, durations[item.slot], item.T_save, item.T_saving, false)
            end
            try_next_save()
        elseif pending_main_save then
            local ms = pending_main_save
            pending_main_save = nil
            local main = obs.obs_frontend_get_replay_buffer_output()
            local path = get_last_replay_path(main)
            if main then obs.obs_output_release(main) end
            if path and path ~= "" then
                enqueue_trim(path, "main", nil, ms.T_save, ms.T_saving, true)
            else
                if reset_enabled then
                    last_save_end_time = ms.T_saving
                end
            end
        end
    elseif event == obs.OBS_FRONTEND_EVENT_EXIT then
        if event_callback then
            obs.obs_frontend_remove_event_callback(event_callback)
            event_callback = nil
        end
        save_queue = {}
        current_save = nil
        pending_main_save = nil
        trim_queue = {}
        if active_job then
            if active_job.stage_pipe then close_process(active_job.stage_pipe) end
            if active_job.stage_proc then
                kill_process(active_job.stage_proc)
                close_process(active_job.stage_proc)
            end
            active_job = nil
        end
    end
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
    ffmpeg_exe = obs.obs_data_get_string(settings, "ffmpeg_path") or ""
    ffprobe_exe = obs.obs_data_get_string(settings, "ffprobe_path") or ""
end

local function autodetect_tools(settings)
    if not settings then return end
    if not ffmpeg_autodetect_done then
        ffmpeg_autodetect_done = true
        if ffmpeg_exe == "" and not obs.obs_data_has_user_value(settings, "ffmpeg_path") then
            local found = autodetect_exe("ffmpeg.exe")
            if found then
                ffmpeg_exe = found
                obs.obs_data_set_string(settings, "ffmpeg_path", found)
            end
        end
    end
    if not ffprobe_autodetect_done then
        ffprobe_autodetect_done = true
        if ffprobe_exe == "" and not obs.obs_data_has_user_value(settings, "ffprobe_path") then
            local found = autodetect_exe("ffprobe.exe")
            if found then
                ffprobe_exe = found
                obs.obs_data_set_string(settings, "ffprobe_path", found)
            end
        end
    end
end

local function on_hotkey(slot)
    return function(pressed)
        if not pressed then return end
        if not effective_enabled then return end
        local d = durations[slot]
        if not d or d <= 0 then return end
        if main_limit and main_limit > 0 and d >= main_limit then return end
        enqueue_save(slot)
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
    local g_ffmpeg = obs.obs_properties_create()
    obs.obs_properties_add_path(g_ffmpeg, "ffmpeg_path", tr("FFmpegPath"), obs.OBS_PATH_FILE, "Executable files (*.exe);;All files (*.*)", nil)
    obs.obs_properties_add_path(g_ffmpeg, "ffprobe_path", tr("FFprobePath"), obs.OBS_PATH_FILE, "Executable files (*.exe);;All files (*.*)", nil)
    obs.obs_properties_add_group(props, "group_ffmpeg", tr("GroupFFmpeg"), obs.OBS_GROUP_NORMAL, g_ffmpeg)
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
    read_settings(settings)
    bridge_open()
    tr_notify_open()
    tr_status_open()
    refresh_effective()
    event_callback = on_frontend_event
    obs.obs_frontend_add_event_callback(event_callback)
    for slot = 1, 3 do
        local key = "trim_replay_hotkey_" .. slot
        hotkey_ids[slot] = obs.obs_hotkey_register_frontend(key, tr("HotkeySave", slot, hotkey_value_label(slot)), on_hotkey(slot))
        local saved_arr = settings and obs.obs_data_get_array(settings, key) or nil
        if saved_arr then
            obs.obs_hotkey_load(hotkey_ids[slot], saved_arr)
            obs.obs_data_array_release(saved_arr)
        end
    end
end

function script_update(settings)
    if not settings then return end
    read_settings(settings)
    autodetect_tools(settings)
    refresh_effective()
    update_hotkey_descriptions()
    if not effective_enabled then
        save_queue = {}
        if not active_job then trim_queue = {} end
    end
end

function script_save(settings)
    if not settings then return end
    obs.obs_data_set_string(settings, "ffmpeg_path", ffmpeg_exe or "")
    obs.obs_data_set_string(settings, "ffprobe_path", ffprobe_exe or "")
    obs.obs_data_set_bool(settings, "enabled", enabled)
    obs.obs_data_set_bool(settings, "reset_after_save", reset_enabled)
    for slot = 1, 3 do
        obs.obs_data_set_int(settings, "clip" .. slot .. "_seconds", durations[slot])
        local key = "trim_replay_hotkey_" .. slot
        if hotkey_ids[slot] then
            local arr = obs.obs_hotkey_save(hotkey_ids[slot])
            obs.obs_data_set_array(settings, key, arr)
            obs.obs_data_array_release(arr)
        end
    end
end

function script_tick(_seconds)
    refresh_effective()
    tick_active_job()
    if not active_job then try_next_trim() end
    if not current_save then try_next_save() end
    if current_save and (now_ms() - current_save.requested_at) > SAVE_TIMEOUT_MS then
        current_save = nil
    end
end

function script_unload()
    if active_job then
        if active_job.stage_pipe then pcall(close_process, active_job.stage_pipe) end
        if active_job.stage_proc then
            pcall(kill_process, active_job.stage_proc)
            pcall(close_process, active_job.stage_proc)
        end
    end
    active_job = nil
    save_queue = {}
    current_save = nil
    pending_main_save = nil
    trim_queue = {}
    if is_valid_handle(nul_handle) then pcall(kernel32.CloseHandle, nul_handle) end
    nul_handle = nil
    pcall(bridge_close)
    pcall(tr_notify_close)
    pcall(tr_status_close)
    if default_loc then pcall(obs.obs_data_release, default_loc); default_loc = nil end
    if current_loc then pcall(obs.obs_data_release, current_loc); current_loc = nil end
end