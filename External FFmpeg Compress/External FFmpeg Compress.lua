local obs = obslua
local ffi = require("ffi")

ffi.cdef[[
    typedef void* HANDLE;
    typedef int BOOL;
    typedef unsigned long DWORD;
    typedef unsigned int UINT;
    typedef unsigned short WORD;
    typedef unsigned char BYTE;
    typedef struct _STARTUPINFOA {
        DWORD cb;
        char* lpReserved;
        char* lpDesktop;
        char* lpTitle;
        DWORD dwX;
        DWORD dwY;
        DWORD dwXSize;
        DWORD dwYSize;
        DWORD dwXCountChars;
        DWORD dwYCountChars;
        DWORD dwFillAttribute;
        DWORD dwFlags;
        WORD wShowWindow;
        WORD cbReserved2;
        BYTE* lpReserved2;
        HANDLE hStdInput;
        HANDLE hStdOutput;
        HANDLE hStdError;
    } STARTUPINFOA;
    typedef struct _PROCESS_INFORMATION {
        HANDLE hProcess;
        HANDLE hThread;
        DWORD dwProcessId;
        DWORD dwThreadId;
    } PROCESS_INFORMATION;
    typedef struct _SECURITY_ATTRIBUTES {
        DWORD nLength;
        void* lpSecurityDescriptor;
        BOOL bInheritHandle;
    } SECURITY_ATTRIBUTES;
    HANDLE CreateFileA(const char* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
    BOOL CreateProcessA(const char* lpApplicationName, char* lpCommandLine, void* lpProcessAttributes, void* lpThreadAttributes, BOOL bInheritHandles, DWORD dwCreationFlags, void* lpEnvironment, const char* lpCurrentDirectory, STARTUPINFOA* lpStartupInfo, PROCESS_INFORMATION* lpProcessInformation);
    DWORD GetExitCodeProcess(HANDLE hProcess, DWORD* lpExitCode);
    DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
    BOOL TerminateProcess(HANDLE hProcess, UINT uExitCode);
    DWORD GetLastError(void);
    BOOL CloseHandle(HANDLE hObject);
]]

local kernel32 = ffi.load("kernel32")
local CREATE_NO_WINDOW = 0x08000000
local STARTF_USESTDHANDLES = 0x00000100
local STILL_ACTIVE = 259
local WAIT_TIMEOUT = 0x00000102
local GENERIC_WRITE = 0x40000000
local FILE_SHARE_READ = 0x00000001
local FILE_SHARE_WRITE = 0x00000002
local OPEN_EXISTING = 3
local NULL_HANDLE = ffi.cast("HANDLE", 0)
local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)
local LOCALE_BASENAME = "External FFmpeg Compress"
local hwaccel_priority = { "cuda", "qsv", "d3d11va", "dxva2" }
local default_loc = nil
local current_loc = nil
local input_file = ""
local crf_value = 26
local use_hw_accel = true
local resolution_value = 1080
local use_resolution = false
local fps_value = 60
local use_fps = false
local ffmpeg_exe = ""
local ffmpeg_autodetect_done = false
local global_settings = nil
local available_hwaccels = {}
local hwaccels_detected = false
local nul_handle = nil
local comp_state = nil

local function is_valid_handle(h)
    return h ~= nil and h ~= NULL_HANDLE and h ~= INVALID_HANDLE_VALUE
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

local function basename(p)
    return p and p:match("[^/\\]+$") or ""
end

local function is_tool_name(path, name)
    return basename(path):lower() == name:lower()
end

local function file_exists(name)
    if not name or name == "" then return false end
    local f = io.open(name, "r")
    if f ~= nil then io.close(f); return true end
    return false
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

local function ensure_nul_handle()
    if is_valid_handle(nul_handle) then
        return nul_handle
    end
    local sa = ffi.new("SECURITY_ATTRIBUTES[1]")
    sa[0].nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
    sa[0].lpSecurityDescriptor = nil
    sa[0].bInheritHandle = 1
    local h = kernel32.CreateFileA("NUL", GENERIC_WRITE, ffi.cast("DWORD", FILE_SHARE_READ + FILE_SHARE_WRITE), sa, OPEN_EXISTING, 0, nil)
    if not is_valid_handle(h) then
        return nil
    end
    nul_handle = h
    return nul_handle
end

local function spawn_hidden(cmdline)
    if not cmdline or #cmdline == 0 then
        return nil, nil, "empty cmdline"
    end
    ensure_nul_handle()
    local si = ffi.new("STARTUPINFOA[1]")
    si[0].cb = ffi.sizeof("STARTUPINFOA")
    if nul_handle ~= nil then
        si[0].dwFlags = STARTF_USESTDHANDLES
        si[0].hStdInput = nul_handle
        si[0].hStdOutput = nul_handle
        si[0].hStdError = nul_handle
    end
    local buf = ffi.new("char[?]", #cmdline + 1)
    ffi.copy(buf, cmdline)
    local pi = ffi.new("PROCESS_INFORMATION[1]")
    local inherit = (nul_handle ~= nil) and 1 or 0
    local ok = kernel32.CreateProcessA(nil, buf, nil, nil, inherit, CREATE_NO_WINDOW, nil, nil, si, pi)
    if ok == 0 then
        return nil, nil, kernel32.GetLastError()
    end
    kernel32.CloseHandle(pi[0].hThread)
    return pi[0].hProcess, tonumber(pi[0].dwProcessId), nil
end

local function run_hidden_sync(cmdline, timeout_ms)
    local h, pid, err = spawn_hidden(cmdline)
    if not h then return nil, tostring(err) end
    local wait = kernel32.WaitForSingleObject(h, timeout_ms or 5000)
    local code = nil
    if wait == WAIT_TIMEOUT then
        kernel32.TerminateProcess(h, 1)
        kernel32.WaitForSingleObject(h, 1000)
    else
        local buf = ffi.new("DWORD[1]")
        kernel32.GetExitCodeProcess(h, buf)
        code = tonumber(buf[0])
    end
    kernel32.CloseHandle(h)
    if code == nil then return nil, "timeout" end
    return code, nil
end

local function poll_process(h)
    local buf = ffi.new("DWORD[1]")
    local ok = kernel32.GetExitCodeProcess(h, buf)
    if ok == 0 then return "error", nil end
    local code = tonumber(buf[0])
    if code == STILL_ACTIVE then return "running", nil end
    if code == 0 then return "ok", 0 end
    return "failed", code
end

local function kill_process(h)
    if h then kernel32.TerminateProcess(h, 1) end
end

local function close_process(h)
    if is_valid_handle(h) then kernel32.CloseHandle(h) end
end

local function test_hwaccel_init(name)
    local cmd = '"' .. ffmpeg_exe .. '" -hide_banner -loglevel quiet -init_hw_device ' .. name .. ' -f lavfi -i nullsrc -t 0.1 -f null -'
    local code = run_hidden_sync(cmd, 5000)
    return code == 0
end

local function detect_hwaccels()
    if hwaccels_detected then return end
    hwaccels_detected = true
    available_hwaccels = {}
    for _, name in ipairs(hwaccel_priority) do
        if test_hwaccel_init(name) then
            available_hwaccels[name] = true
        end
    end
end

local function build_ffmpeg_cmd(in_path, out_path, crf, hwaccel, res_enabled, res_height, fps_enabled, fps_rate)
    local clean_ffmpeg = ffmpeg_exe:gsub("/", "\\")
    local clean_input = in_path:gsub("/", "\\")
    local clean_output = out_path:gsub("/", "\\")
    local decoder_arg = hwaccel and (" -hwaccel " .. hwaccel) or ""
    local vf_arg = ""
    if res_enabled and res_height and res_height > 0 then
        vf_arg = ' -vf "scale=-2:' .. res_height .. '"'
    end
    local fps_arg = ""
    if fps_enabled and fps_rate then
        fps_arg = " -r " .. fps_rate
    end
    return string.format('"%s" -y%s -i "%s"%s%s -c:v libx264 -crf %d -preset veryfast -pix_fmt yuv420p -x264-params "bframes=2" -movflags +faststart -c:a copy "%s"', clean_ffmpeg, decoder_arg, clean_input, vf_arg, fps_arg, crf, clean_output)
end

local function finalize_compression_success()
    local st = comp_state
    comp_state = nil
    local clean = st.output_path:gsub("/", "\\")
    local h = spawn_hidden('explorer.exe /select,"' .. clean .. '"')
    if h then kernel32.CloseHandle(h) end
end

local function finalize_compression_failure()
    comp_state = nil
end

local function launch_attempt(index)
    if not comp_state then return end
    local total = #comp_state.attempts
    if index > total then
        finalize_compression_failure()
        return
    end
    local name = comp_state.attempts[index]
    local hwaccel = (name ~= "__software__") and name or nil
    comp_state.attempt_index = index
    comp_state.current_label = hwaccel or "software"
    local cmd = build_ffmpeg_cmd(comp_state.input_path, comp_state.output_path, comp_state.crf, hwaccel, comp_state.res_enabled, comp_state.res_height, comp_state.fps_enabled, comp_state.fps_rate)
    local h, pid = spawn_hidden(cmd)
    if not h then
        launch_attempt(index + 1)
        return
    end
    comp_state.process_handle = h
    comp_state.pid = pid
end

local function start_compression(in_path, crf, hw_enabled, res_enabled, res_height, fps_enabled, fps_rate)
    if comp_state then return false end
    if in_path == nil or in_path == "" then return false end
    local f = io.open(in_path, "r")
    if not f then return false end
    io.close(f)
    local dir, filename = in_path:match("^(.*[/\\])(.-)$")
    if not dir then dir = ""; filename = in_path end
    local out_path = dir .. "Compressed " .. filename
    local attempts = {}
    if hw_enabled then
        for _, name in ipairs(hwaccel_priority) do
            if available_hwaccels[name] then
                attempts[#attempts + 1] = name
            end
        end
    end
    attempts[#attempts + 1] = "__software__"
    comp_state = {input_path = in_path, output_path = out_path, crf = crf, res_enabled = res_enabled, res_height = res_height, fps_enabled = fps_enabled, fps_rate = fps_rate, attempts = attempts, attempt_index = 0, current_label = nil, process_handle = nil, pid = nil}
    launch_attempt(1)
    return true
end

local function compress_file()
    if input_file == "" or input_file == nil then return false end
    if not valid_tool_path(ffmpeg_exe, "ffmpeg.exe") then return false end
    if comp_state then return false end
    if use_hw_accel then
        detect_hwaccels()
    end
    if start_compression(input_file, crf_value, use_hw_accel, use_resolution, resolution_value, use_fps, fps_value) then
        if global_settings ~= nil then
            obs.obs_data_set_string(global_settings, "input_file", "")
        end
        input_file = ""
    end
    return true
end

function script_tick(seconds)
    if comp_state and comp_state.process_handle then
        local status = poll_process(comp_state.process_handle)
        if status ~= "running" then
            close_process(comp_state.process_handle)
            comp_state.process_handle = nil
            if status == "ok" then
                finalize_compression_success()
            else
                launch_attempt(comp_state.attempt_index + 1)
            end
        end
    end
end

function script_load(settings)
    init_locale()
    if settings then
        ffmpeg_exe = obs.obs_data_get_string(settings, "ffmpeg_path") or ""
        input_file = obs.obs_data_get_string(settings, "input_file") or ""
        if obs.obs_data_has_user_value(settings, "crf_value") then
            crf_value = obs.obs_data_get_int(settings, "crf_value")
        end
        use_hw_accel = obs.obs_data_get_bool(settings, "use_hw_accel")
        if obs.obs_data_has_user_value(settings, "resolution_value") then
            resolution_value = obs.obs_data_get_int(settings, "resolution_value")
        end
        use_resolution = obs.obs_data_get_bool(settings, "use_resolution")
        if obs.obs_data_has_user_value(settings, "fps_value") then
            fps_value = obs.obs_data_get_int(settings, "fps_value")
        end
        use_fps = obs.obs_data_get_bool(settings, "use_fps")
    end
end

function script_save(settings)
    obs.obs_data_set_string(settings, "ffmpeg_path", ffmpeg_exe or "")
    obs.obs_data_set_bool(settings, "use_hw_accel", use_hw_accel)
    obs.obs_data_set_int(settings, "crf_value", crf_value)
    obs.obs_data_set_bool(settings, "use_resolution", use_resolution)
    obs.obs_data_set_int(settings, "resolution_value", resolution_value)
    obs.obs_data_set_bool(settings, "use_fps", use_fps)
    obs.obs_data_set_int(settings, "fps_value", fps_value)
end

function script_update(settings)
    if not settings then return end
    obs.obs_data_addref(settings)
    if global_settings then
        obs.obs_data_release(global_settings)
    end
    global_settings = settings
    ffmpeg_exe = obs.obs_data_get_string(settings, "ffmpeg_path") or ""
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
    input_file = obs.obs_data_get_string(settings, "input_file")
    if obs.obs_data_has_user_value(settings, "crf_value") then
        crf_value = obs.obs_data_get_int(settings, "crf_value")
    end
    use_hw_accel = obs.obs_data_get_bool(settings, "use_hw_accel")
    if obs.obs_data_has_user_value(settings, "resolution_value") then
        resolution_value = obs.obs_data_get_int(settings, "resolution_value")
    end
    use_resolution = obs.obs_data_get_bool(settings, "use_resolution")
    if obs.obs_data_has_user_value(settings, "fps_value") then
        fps_value = obs.obs_data_get_int(settings, "fps_value")
    end
    use_fps = obs.obs_data_get_bool(settings, "use_fps")
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "crf_value", 26)
    obs.obs_data_set_default_bool(settings, "use_hw_accel", true)
    obs.obs_data_set_default_int(settings, "resolution_value", 1080)
    obs.obs_data_set_default_bool(settings, "use_resolution", false)
    obs.obs_data_set_default_int(settings, "fps_value", 60)
    obs.obs_data_set_default_bool(settings, "use_fps", false)
end

function script_unload()
    if comp_state and comp_state.process_handle then
        pcall(kill_process, comp_state.process_handle)
        pcall(close_process, comp_state.process_handle)
    end
    comp_state = nil
    if is_valid_handle(nul_handle) then pcall(kernel32.CloseHandle, nul_handle) end
    nul_handle = nil
    if global_settings then pcall(obs.obs_data_release, global_settings); global_settings = nil end
    if default_loc then pcall(obs.obs_data_release, default_loc); default_loc = nil end
    if current_loc then pcall(obs.obs_data_release, current_loc); current_loc = nil end
end

function script_properties()
    init_locale()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "script_description_text", getString("ScriptDescription"), obs.OBS_TEXT_INFO)
    local g_ffmpeg = obs.obs_properties_create()
    obs.obs_properties_add_path(g_ffmpeg, "ffmpeg_path", getString("FFmpegPath"), obs.OBS_PATH_FILE, "Executable files (*.exe);;All files (*.*)", nil)
    obs.obs_properties_add_group(props, "group_ffmpeg", getString("GroupFFmpeg"), obs.OBS_GROUP_NORMAL, g_ffmpeg)
    local g_compress = obs.obs_properties_create()
    obs.obs_properties_add_path(g_compress, "input_file", getString("InputFile"), obs.OBS_PATH_FILE, getString("VideoFilesFilter"), nil)
    obs.obs_properties_add_bool(g_compress, "use_hw_accel", getString("UseHWDecoding"))
    obs.obs_properties_add_int_slider(g_compress, "crf_value", getString("CRFValue"), 1, 51, 1)
    local res_list = obs.obs_properties_add_list(g_compress, "resolution_value", getString("Resolution"), obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
    obs.obs_property_list_add_int(res_list, "144p", 144)
    obs.obs_property_list_add_int(res_list, "240p", 240)
    obs.obs_property_list_add_int(res_list, "360p", 360)
    obs.obs_property_list_add_int(res_list, "480p", 480)
    obs.obs_property_list_add_int(res_list, "720p", 720)
    obs.obs_property_list_add_int(res_list, "1080p", 1080)
    obs.obs_property_list_add_int(res_list, "1440p", 1440)
    obs.obs_property_list_add_int(res_list, "2160p", 2160)
    obs.obs_properties_add_bool(g_compress, "use_resolution", getString("UseResolution"))
    obs.obs_properties_add_int_slider(g_compress, "fps_value", getString("FPSValue"), 30, 60, 1)
    obs.obs_properties_add_bool(g_compress, "use_fps", getString("UseFPS"))
    obs.obs_properties_add_button(g_compress, "compress_button", getString("CompressButton"), function(properties, property) return compress_file() end)
    obs.obs_properties_add_group(props, "group_compress", getString("GroupCompress"), obs.OBS_GROUP_NORMAL, g_compress)
    return props
end