local obs = obslua
local LOCALE_NAME = "Notifier"
local SFO_STATUS_NAME = "Local\\OBS_SFO_Status_v1"
local SFO_STATUS_SIZE = 16
local SFO_MOVED_NAME = "Local\\OBS_SFO_Moved_v1"
local SFO_MOVED_HEADER = 8
local SFO_MOVED_SLOT = 2048
local SFO_MOVED_SLOTS = 128
local SFO_MOVED_TOTAL = SFO_MOVED_HEADER + SFO_MOVED_SLOT * SFO_MOVED_SLOTS
local SFO_MOVED_PAYLOAD_MAX = SFO_MOVED_SLOT - 12
local PR_NOTIFY_NAME = "Local\\OBS_PR_Notify_v1"
local PR_NOTIFY_HEADER = 8
local PR_NOTIFY_SLOT = 1024
local PR_NOTIFY_SLOTS = 128
local PR_NOTIFY_TOTAL = PR_NOTIFY_HEADER + PR_NOTIFY_SLOT * PR_NOTIFY_SLOTS
local PR_NOTIFY_PAYLOAD_MAX = PR_NOTIFY_SLOT - 8
local UTF8_CP = 65001
local WND_CLASS_NAME = "NotifierAlertBox"
local WND_TITLE_NAME = "NotifierAlert"

local CONFIG = {
    visual_enabled = true,
    sound_enabled = true,
    scale = 100,
    position = "top_right",
    duration = 3.0,
    sound_file = "",
}

local STATE = {
    sfo_moved_rs = nil,
    pr_notify_rs = nil,
    pending = {},
    alert_queue = {},
    active_alert = nil,
    sound_files = {},
    event_callback = nil,
    exiting = false,
    popup_hwnd = nil,
    popup_hinstance = nil,
    popup_class_atom = nil,
    title_font = nil,
    body_font = nil,
    alpha_value = 0,
    alpha_ramp = 0,
    popup_deadline = 0,
    heading_text = "",
    body_text = "",
    fonts_need_refresh = false,
    backbuffer_dc = nil,
    backbuffer_bitmap = nil,
    backbuffer_prev = nil,
    backbuffer_w = 0,
    backbuffer_h = 0,
}

local ffi = require("ffi")

ffi.cdef[[
    typedef void* HANDLE;
    typedef void* HWND;
    typedef void* HINSTANCE;
    typedef void* HDC;
    typedef void* HFONT;
    typedef void* HGDIOBJ;
    typedef void* HBRUSH;
    typedef void* HICON;
    typedef void* HCURSOR;
    typedef void* HBITMAP;
    typedef unsigned long DWORD;
    typedef int BOOL;
    typedef unsigned int UINT;
    typedef long LONG;
    typedef int64_t LONG_PTR;
    typedef uint64_t UINT_PTR;
    typedef UINT_PTR WPARAM;
    typedef LONG_PTR LPARAM;
    typedef LONG_PTR LRESULT;
    typedef unsigned short ATOM;
    typedef unsigned char BYTE;
    typedef DWORD COLORREF;
    typedef const char* LPCSTR;
    typedef const unsigned short* LPCWSTR;
    typedef unsigned short wchar_t;
    typedef size_t SIZE_T;
    int MultiByteToWideChar(UINT CodePage, DWORD dwFlags, const char* lpMultiByteStr, int cbMultiByte, unsigned short* lpWideCharStr, int cchWideChar);
    int WideCharToMultiByte(UINT CodePage, DWORD dwFlags, const unsigned short* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
    HANDLE CreateFileMappingW(HANDLE, void*, DWORD, DWORD, DWORD, LPCWSTR);
    HANDLE OpenFileMappingW(DWORD, BOOL, LPCWSTR);
    void* MapViewOfFile(HANDLE, DWORD, DWORD, DWORD, SIZE_T);
    BOOL UnmapViewOfFile(void*);
    BOOL CloseHandle(HANDLE);
    typedef LRESULT (*WNDPROC)(HWND, UINT, WPARAM, LPARAM);
    typedef struct tagWNDCLASSEXA {
        UINT cbSize;
        UINT style;
        WNDPROC lpfnWndProc;
        int cbClsExtra;
        int cbWndExtra;
        HINSTANCE hInstance;
        HICON hIcon;
        HCURSOR hCursor;
        HBRUSH hbrBackground;
        LPCSTR lpszMenuName;
        LPCSTR lpszClassName;
        HICON hIconSm;
    } WNDCLASSEXA;
    ATOM RegisterClassExA(const WNDCLASSEXA* lpwcx);
    BOOL UnregisterClassA(LPCSTR lpClassName, HINSTANCE hInstance);
    HWND CreateWindowExA(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, void*, HINSTANCE, void*);
    BOOL DestroyWindow(HWND);
    BOOL ShowWindow(HWND, int);
    BOOL SetLayeredWindowAttributes(HWND, COLORREF, BYTE, DWORD);
    BOOL SetWindowPos(HWND, HWND, int, int, int, int, UINT);
    LRESULT DefWindowProcA(HWND, UINT, WPARAM, LPARAM);
    BOOL IsWindow(HWND);
    HDC GetDC(HWND);
    int ReleaseDC(HWND, HDC);
    HINSTANCE GetModuleHandleA(LPCSTR);
    int GetSystemMetrics(int);
    HWND FindWindowA(LPCSTR, LPCSTR);
    BOOL PostMessageA(HWND, UINT, WPARAM, LPARAM);
    typedef struct tagRECT { LONG left, top, right, bottom; } RECT;
    BOOL GetClientRect(HWND, RECT*);
    HDC CreateCompatibleDC(HDC);
    HBITMAP CreateCompatibleBitmap(HDC, int, int);
    BOOL DeleteDC(HDC);
    BOOL BitBlt(HDC, int, int, int, int, HDC, int, int, DWORD);
    HFONT CreateFontA(int, int, int, int, int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, LPCSTR);
    HGDIOBJ SelectObject(HDC, HGDIOBJ);
    BOOL DeleteObject(HGDIOBJ);
    int SetBkMode(HDC, int);
    COLORREF SetTextColor(HDC, COLORREF);
    int DrawTextW(HDC, LPCWSTR, int, RECT*, UINT);
    int DrawTextA(HDC, LPCSTR, int, RECT*, UINT);
    HBRUSH CreateSolidBrush(COLORREF);
    int FillRect(HDC, const RECT*, HBRUSH);
    BOOL PlaySoundA(LPCSTR, HINSTANCE, DWORD);
    typedef struct {
        DWORD dwFileAttributes;
        DWORD ftCreationTime_L; DWORD ftCreationTime_H;
        DWORD ftLastAccessTime_L; DWORD ftLastAccessTime_H;
        DWORD ftLastWriteTime_L; DWORD ftLastWriteTime_H;
        DWORD nFileSizeHigh;
        DWORD nFileSizeLow;
        DWORD dwReserved0;
        DWORD dwReserved1;
        unsigned short cFileName[260];
        unsigned short cAlternateFileName[14];
    } WIN32_FIND_DATAW;
    HANDLE FindFirstFileW(LPCWSTR, void*);
    BOOL FindNextFileW(HANDLE, void*);
    BOOL FindClose(HANDLE);
]]

local kernel32 = ffi.load("kernel32")
local user32 = ffi.load("user32")
local gdi32 = ffi.load("gdi32")
local winmm = ffi.load("winmm")

local function rgb(r, g, b)
    return (b * 65536) + (g * 256) + r
end

local WIN = {
    WS_POPUP = 0x80000000,
    WS_EX_TOPMOST = 0x00000008,
    WS_EX_TOOLWINDOW = 0x00000080,
    WS_EX_NOACTIVATE = 0x08000000,
    WS_EX_LAYERED = 0x00080000,
    WS_EX_TRANSPARENT = 0x00000020,
    SW_HIDE = 0,
    SW_SHOWNOACTIVATE = 4,
    SWP_NOACTIVATE = 0x0010,
    LWA_ALPHA = 0x00000002,
    SM_CXSCREEN = 0,
    SM_CYSCREEN = 1,
    FW_BOLD = 700,
    DEFAULT_CHARSET = 1,
    OUT_DEFAULT_PRECIS = 0,
    CLIP_DEFAULT_PRECIS = 0,
    CLEARTYPE_QUALITY = 5,
    DEFAULT_PITCH = 0,
    DT_CENTER = 0x00000001,
    DT_VCENTER = 0x00000004,
    DT_SINGLELINE = 0x00000020,
    TRANSPARENT = 1,
    SND_FILENAME = 0x00020000,
    SND_ASYNC = 0x0001,
    SND_NODEFAULT = 0x0002,
    CS_HREDRAW = 0x0002,
    CS_VREDRAW = 0x0001,
    BG_COLOR = rgb(30, 30, 30),
    MAIN_COLOR = rgb(255, 255, 255),
    SUB_COLOR = rgb(200, 200, 200),
    STRIPE_COLOR = rgb(115, 180, 0),
    SRCCOPY = 0x00CC0020,
    WM_CLOSE = 0x0010
}

local PANEL_W = 350
local PANEL_H = 80
local PANEL_INSET = 16
local ALPHA_STEP = 10
local ALPHA_LIMIT = 220
local TICK_MS = 10
local HEADING_PX = -18
local BODY_PX = -14
local STRIPE_PX = 5
local CENTER_TEXT = WIN.DT_CENTER + WIN.DT_VCENTER + WIN.DT_SINGLELINE

local function timestamp_ms()
    if obs.os_gettime_ns then
        local v = tonumber(obs.os_gettime_ns())
        if v then
            return v / 1000000
        end
    end
    return os.time() * 1000
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
    default_loc = load_locale_file(loc_dir .. "en-US " .. LOCALE_NAME .. ".json")
    current_loc = load_locale_file(loc_dir .. tostring(lang) .. " " .. LOCALE_NAME .. ".json")
        or load_locale_file(loc_dir .. tostring(lang):sub(1, 2) .. " " .. LOCALE_NAME .. ".json")
end

local function getString(key)
    init_locale()
    local value = current_loc and obs.obs_data_get_string(current_loc, key) or ""
    if value == "" and default_loc then
        value = obs.obs_data_get_string(default_loc, key)
    end
    return value ~= "" and value or key
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
    return p:match("([^/]+)$") or p
end

local function output_directory(output)
    if not output then return nil end
    local settings = obs.obs_output_get_settings(output)
    if not settings then return nil end
    local dir = obs.obs_data_get_string(settings, "directory")
    obs.obs_data_release(settings)
    if dir == "" then return nil end
    return dir
end

local function replay_directory()
    local out = obs.obs_frontend_get_replay_buffer_output()
    if not out then return nil end
    local dir = output_directory(out)
    obs.obs_output_release(out)
    return dir
end

local function recording_directory()
    local out = obs.obs_frontend_get_recording_output()
    if not out then return nil end
    local dir = output_directory(out)
    obs.obs_output_release(out)
    return dir
end

local function profile_recording_directory()
    if not obs.obs_frontend_get_profile_config or not obs.config_get_string then return nil end
    local config = obs.obs_frontend_get_profile_config()
    if not config then return nil end
    local mode = obs.config_get_string(config, "Output", "Mode") or ""
    local dir = nil
    if mode:lower() == "advanced" then
        local rt = obs.config_get_string(config, "AdvOut", "RecType") or ""
        if rt ~= "Standard" then
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

local function root_folder_basename(media_type, file_path)
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
    dir = normalize_slashes(dir):gsub("/+$", "")
    return basename(dir)
end

local function bridge_wide(s)
    local b = ffi.new("unsigned short[?]", #s + 1)
    for i = 1, #s do
        b[i-1] = s:byte(i)
    end
    b[#s] = 0
    return b
end

local function wide(s)
    if not s or s == "" then return nil end
    local len = kernel32.MultiByteToWideChar(UTF8_CP, 0, s, -1, nil, 0)
    if not len or len <= 0 then return nil end
    local buf = ffi.new("unsigned short[?]", len)
    if kernel32.MultiByteToWideChar(UTF8_CP, 0, s, -1, buf, len) == 0 then return nil end
    return buf
end

local function sfo_status_read()
    local h = kernel32.OpenFileMappingW(0x000F001F, 0, bridge_wide(SFO_STATUS_NAME))
    if h == nil or h == ffi.cast("HANDLE", 0) then
        return {live = false, enabled = false}
    end
    local v = kernel32.MapViewOfFile(h, 0x000F001F, 0, 0, SFO_STATUS_SIZE)
    if v == nil then
        kernel32.CloseHandle(h)
        return {live = false, enabled = false}
    end
    local hdr = ffi.cast("unsigned int*", v)
    local version = tonumber(hdr[0])
    local enabled = tonumber(hdr[1])
    kernel32.UnmapViewOfFile(v)
    kernel32.CloseHandle(h)
    if version ~= 1 then return { live = false, enabled = false } end
    return {live = true, enabled = enabled == 1}
end

local function pr_is_active()
    local h = kernel32.OpenFileMappingW(0x0004, 0, bridge_wide(PR_NOTIFY_NAME))
    if h == nil or h == ffi.cast("HANDLE", 0) then
        return false
    end
    kernel32.CloseHandle(h)
    return true
end

local function sfo_moved_read_new()
    local h = kernel32.OpenFileMappingW(0x000F001F, 0, bridge_wide(SFO_MOVED_NAME))
    if h == nil or h == ffi.cast("HANDLE", 0) then
        STATE.sfo_moved_rs = nil
        return {}
    end
    local v = kernel32.MapViewOfFile(h, 0x000F001F, 0, 0, SFO_MOVED_TOTAL)
    if v == nil then
        kernel32.CloseHandle(h)
        return {}
    end
    local hdr = ffi.cast("unsigned int*", v)
    local ws = tonumber(hdr[0]) or 0
    local events = {}
    if STATE.sfo_moved_rs == nil then
        STATE.sfo_moved_rs = ws
    end
    if STATE.sfo_moved_rs > ws then
        STATE.sfo_moved_rs = ws
    end
    while STATE.sfo_moved_rs < ws do
        local idx = STATE.sfo_moved_rs % SFO_MOVED_SLOTS
        local slot = ffi.cast("unsigned char*", v) + SFO_MOVED_HEADER + idx * SFO_MOVED_SLOT
        local plen = tonumber(ffi.cast("unsigned int*", slot)[0])
        local ilen = tonumber(ffi.cast("unsigned int*", slot + 4)[0])
        local status = tonumber(ffi.cast("unsigned int*", slot + 8)[0])
        if plen > 0 and plen <= SFO_MOVED_PAYLOAD_MAX and ilen <= SFO_MOVED_PAYLOAD_MAX - plen then
            local pbuf = ffi.new("char[?]", plen)
            ffi.copy(pbuf, slot + 12, plen)
            local path = ffi.string(pbuf, plen)
            local info = ""
            if ilen > 0 then
                local ibuf = ffi.new("char[?]", ilen)
                ffi.copy(ibuf, slot + 12 + plen, ilen)
                info = ffi.string(ibuf, ilen)
            end
            events[#events + 1] = {path = path, info = info, status = status}
        end
        STATE.sfo_moved_rs = STATE.sfo_moved_rs + 1
    end
    kernel32.UnmapViewOfFile(v)
    kernel32.CloseHandle(h)
    return events
end

local function pr_notify_read_new()
    local h = kernel32.OpenFileMappingW(0x000F001F, 0, bridge_wide(PR_NOTIFY_NAME))
    if h == nil or h == ffi.cast("HANDLE", 0) then
        STATE.pr_notify_rs = nil
        return {}
    end
    local v = kernel32.MapViewOfFile(h, 0x000F001F, 0, 0, PR_NOTIFY_TOTAL)
    if v == nil then
        kernel32.CloseHandle(h)
        return {}
    end
    local hdr = ffi.cast("unsigned int*", v)
    local ws = tonumber(hdr[0]) or 0
    local events = {}
    if STATE.pr_notify_rs == nil then
        STATE.pr_notify_rs = ws
    end
    if STATE.pr_notify_rs > ws then
        STATE.pr_notify_rs = ws
    end
    while STATE.pr_notify_rs < ws do
        local idx = STATE.pr_notify_rs % PR_NOTIFY_SLOTS
        local slot = ffi.cast("unsigned char*", v) + PR_NOTIFY_HEADER + idx * PR_NOTIFY_SLOT
        local dur = tonumber(ffi.cast("unsigned int*", slot)[0])
        local plen = tonumber(ffi.cast("unsigned int*", slot + 4)[0])
        if plen > 0 and plen <= PR_NOTIFY_PAYLOAD_MAX then
            local pbuf = ffi.new("char[?]", plen)
            ffi.copy(pbuf, slot + 8, plen)
            events[#events + 1] = { path = ffi.string(pbuf, plen), duration = dur }
        end
        STATE.pr_notify_rs = STATE.pr_notify_rs + 1
    end
    kernel32.UnmapViewOfFile(v)
    kernel32.CloseHandle(h)
    return events
end

local function list_sound_files()
    local dir = (script_path():match("(.*[/\\])") or "") .. "notification sounds"
    local files = {}
    local pattern = dir .. "\\*.wav"
    local wsearch = bridge_wide(pattern)
    if not wsearch then return files end
    local data = ffi.new("WIN32_FIND_DATAW")
    local h = kernel32.FindFirstFileW(wsearch, data)
    if h == nil or h == ffi.cast("HANDLE", -1) or h == ffi.cast("HANDLE", 0) then
        return files
    end
    local function w2u(ptr, maxc)
        local n = 0
        while n < maxc and ptr[n] ~= 0 do
            n = n + 1
        end
        if n == 0 then return "" end
        local size = kernel32.WideCharToMultiByte(UTF8_CP, 0, ptr, n, nil, 0, nil, nil)
        if not size or size <= 0 then return "" end
        local buf = ffi.new("char[?]", size + 1)
        kernel32.WideCharToMultiByte(UTF8_CP, 0, ptr, n, buf, size, nil, nil)
        return ffi.string(buf, size)
    end
    repeat
        local name = w2u(data.cFileName, 260)
        if name ~= "" and name ~= "." and name ~= ".." then
            files[#files + 1] = name
        end
    until kernel32.FindNextFileW(h, data) == 0
    kernel32.FindClose(h)
    table.sort(files)
    return files
end

local function destroy_memdc()
    if STATE.backbuffer_prev and STATE.backbuffer_dc then
        pcall(gdi32.SelectObject, STATE.backbuffer_dc, STATE.backbuffer_prev)
    end
    STATE.backbuffer_prev = nil
    if STATE.backbuffer_bitmap then
        gdi32.DeleteObject(STATE.backbuffer_bitmap)
        STATE.backbuffer_bitmap = nil
    end
    if STATE.backbuffer_dc then
        gdi32.DeleteDC(STATE.backbuffer_dc)
        STATE.backbuffer_dc = nil
    end
    STATE.backbuffer_w = 0
    STATE.backbuffer_h = 0
end

local function paint_popup()
    if STATE.popup_hwnd == nil then return end
    if not user32.IsWindow(STATE.popup_hwnd) then return end
    if STATE.title_font == nil or STATE.body_font == nil then return end
    local hdc = user32.GetDC(STATE.popup_hwnd)
    if hdc == nil then return end
    local rect = ffi.new("RECT")
    user32.GetClientRect(STATE.popup_hwnd, rect)
    local w = rect.right
    local h = rect.bottom
    if STATE.backbuffer_dc == nil or STATE.backbuffer_w ~= w or STATE.backbuffer_h ~= h then
        destroy_memdc()
        STATE.backbuffer_dc = gdi32.CreateCompatibleDC(hdc)
        STATE.backbuffer_bitmap = gdi32.CreateCompatibleBitmap(hdc, w, h)
        if STATE.backbuffer_dc ~= nil and STATE.backbuffer_bitmap ~= nil then
            STATE.backbuffer_prev = gdi32.SelectObject(STATE.backbuffer_dc, STATE.backbuffer_bitmap)
            STATE.backbuffer_w = w
            STATE.backbuffer_h = h
        else
            destroy_memdc()
        end
    end
    local mdc = STATE.backbuffer_dc
    if mdc == nil then
        user32.ReleaseDC(STATE.popup_hwnd, hdc)
        return
    end
    local s = CONFIG.scale / 100.0
    local stripe = math.floor(STRIPE_PX * s)
    local ok = pcall(function()
        local bg = gdi32.CreateSolidBrush(WIN.BG_COLOR)
        if bg ~= nil then
            user32.FillRect(mdc, rect, bg)
            gdi32.DeleteObject(bg)
        end
        local accent = gdi32.CreateSolidBrush(WIN.STRIPE_COLOR)
        if accent ~= nil then
            local ar = ffi.new("RECT", { 0, 0, stripe, h })
            user32.FillRect(mdc, ar, accent)
            gdi32.DeleteObject(accent)
        end
        local old = gdi32.SelectObject(mdc, STATE.title_font)
        gdi32.SetBkMode(mdc, WIN.TRANSPARENT)
        gdi32.SetTextColor(mdc, WIN.MAIN_COLOR)
        local title = STATE.heading_text
        if not title or title == "" then title = " " end
        local text_left = stripe + math.floor(9 * s)
        local text_right = w - math.floor(12 * s)
        local title_rect = ffi.new("RECT", {text_left, math.floor(10 * s), text_right, math.floor(46 * s)})
        local tw = wide(title)
        if tw then
            user32.DrawTextW(mdc, tw, -1, title_rect, CENTER_TEXT)
        else
            user32.DrawTextA(mdc, title, -1, title_rect, CENTER_TEXT)
        end
        gdi32.SelectObject(mdc, STATE.body_font)
        gdi32.SetTextColor(mdc, WIN.SUB_COLOR)
        local msg = STATE.body_text or ""
        if msg ~= "" then
            local msg_rect = ffi.new("RECT", {text_left, math.floor(46 * s), text_right, h - math.floor(8 * s)})
            local mw = wide(msg)
            if mw then
                user32.DrawTextW(mdc, mw, -1, msg_rect, CENTER_TEXT)
            else
                user32.DrawTextA(mdc, msg, -1, msg_rect, CENTER_TEXT)
            end
        end
        if old ~= nil then
            gdi32.SelectObject(mdc, old)
        end
        gdi32.BitBlt(hdc, 0, 0, w, h, mdc, 0, 0, WIN.SRCCOPY)
    end)
    user32.ReleaseDC(STATE.popup_hwnd, hdc)
    if not ok then return end
end

local function prepare_fonts()
    local s = CONFIG.scale / 100.0
    if STATE.title_font == nil then
        STATE.title_font = gdi32.CreateFontA(math.floor(HEADING_PX * s), 0, 0, 0, WIN.FW_BOLD, 0, 0, 0, WIN.DEFAULT_CHARSET, WIN.OUT_DEFAULT_PRECIS, WIN.CLIP_DEFAULT_PRECIS, WIN.CLEARTYPE_QUALITY, WIN.DEFAULT_PITCH, "Segoe UI")
    end
    if STATE.body_font == nil then
        STATE.body_font = gdi32.CreateFontA(math.floor(BODY_PX * s), 0, 0, 0, 400, 0, 0, 0, WIN.DEFAULT_CHARSET, WIN.OUT_DEFAULT_PRECIS, WIN.CLIP_DEFAULT_PRECIS, WIN.CLEARTYPE_QUALITY, WIN.DEFAULT_PITCH, "Segoe UI")
    end
end

local function refresh_fonts()
    if STATE.title_font then
        gdi32.DeleteObject(STATE.title_font)
        STATE.title_font = nil
    end
    if STATE.body_font then
        gdi32.DeleteObject(STATE.body_font)
        STATE.body_font = nil
    end
    prepare_fonts()
end

local function position_xy(scale)
    local w = math.floor(PANEL_W * scale)
    local h = math.floor(PANEL_H * scale)
    local m = PANEL_INSET
    local sw = user32.GetSystemMetrics(WIN.SM_CXSCREEN)
    local sh = user32.GetSystemMetrics(WIN.SM_CYSCREEN)
    local x, y
    if CONFIG.position == "top_left" then
        x, y = m, m
    elseif CONFIG.position == "bottom_right" then
        x, y = sw - w - m, sh - h - m
    elseif CONFIG.position == "bottom_left" then
        x, y = m, sh - h - m
    else
        x, y = sw - w - m, m
    end
    return x, y, w, h
end

local function ensure_notification_class()
    if STATE.popup_class_atom then return end
    if STATE.popup_hinstance == nil then
        STATE.popup_hinstance = kernel32.GetModuleHandleA(nil)
    end
    local wc = ffi.new("WNDCLASSEXA")
    wc.cbSize = ffi.sizeof("WNDCLASSEXA")
    wc.style = WIN.CS_HREDRAW + WIN.CS_VREDRAW
    wc.lpfnWndProc = user32.DefWindowProcA
    wc.hInstance = STATE.popup_hinstance
    wc.hbrBackground = nil
    wc.lpszClassName = WND_CLASS_NAME
    local atom = user32.RegisterClassExA(wc)
    if atom ~= 0 then
        STATE.popup_class_atom = atom
    else
        STATE.popup_class_atom = 1
    end
end

local function ensure_notification_window()
    if STATE.popup_hwnd and user32.IsWindow(STATE.popup_hwnd) then
        return STATE.popup_hwnd
    end
    if STATE.popup_hwnd then
        STATE.popup_hwnd = nil
    end
    ensure_notification_class()
    local scale = CONFIG.scale / 100.0
    local x, y, w, h = position_xy(scale)
    local ex = WIN.WS_EX_TOPMOST + WIN.WS_EX_TOOLWINDOW + WIN.WS_EX_NOACTIVATE + WIN.WS_EX_LAYERED + WIN.WS_EX_TRANSPARENT
    STATE.popup_hwnd = user32.CreateWindowExA(ex, WND_CLASS_NAME, WND_TITLE_NAME, WIN.WS_POPUP, x, y, w, h, nil, nil, STATE.popup_hinstance, nil)
    if STATE.popup_hwnd == nil or STATE.popup_hwnd == ffi.cast("HWND", 0) then 
        STATE.popup_hwnd = nil
        return nil
    end
    user32.SetLayeredWindowAttributes(STATE.popup_hwnd, 0, 0, WIN.LWA_ALPHA)
    return STATE.popup_hwnd
end

local function destroy_notification_window()
    destroy_memdc()
    if STATE.popup_hwnd and user32.IsWindow(STATE.popup_hwnd) then
        user32.DestroyWindow(STATE.popup_hwnd)
    end
    STATE.popup_hwnd = nil
end

local function play_alert()
    if not CONFIG.sound_enabled then return end
    if winmm == nil then return end
    if CONFIG.sound_file == "" then return end
    local dir = (script_path():match("(.*[/\\])") or "") .. "notification sounds\\"
    local full = dir .. CONFIG.sound_file
    pcall(function()
        if not wide(full) then return end
        winmm.PlaySoundA(full, nil, WIN.SND_FILENAME + WIN.SND_ASYNC + WIN.SND_NODEFAULT)
    end)
end

local function enqueue_alert(title, body)
    STATE.alert_queue[#STATE.alert_queue + 1] = {title = title or "", body = body or ""}
end

local function apply_alpha(v)
    user32.SetLayeredWindowAttributes(STATE.popup_hwnd, 0, v, WIN.LWA_ALPHA)
end

local function advance_queue()
    if STATE.active_alert ~= nil then return end
    if #STATE.alert_queue == 0 then return end
    local item = table.remove(STATE.alert_queue, 1)
    STATE.heading_text = item.title
    STATE.body_text = item.body
    STATE.alpha_value = 0
    STATE.alpha_ramp = 1
    STATE.popup_deadline = timestamp_ms() + CONFIG.duration * 1000
    STATE.active_alert = { started = timestamp_ms() }
    if not CONFIG.visual_enabled then
        play_alert()
        return
    end
    local ok = pcall(function()
        if ensure_notification_window() == nil then return end
        local scale = CONFIG.scale / 100.0
        local x, y, w, h = position_xy(scale)
        local topmost = ffi.cast("HWND", ffi.cast("intptr_t", -1))
        user32.SetWindowPos(STATE.popup_hwnd, topmost, x, y, w, h, WIN.SWP_NOACTIVATE)
        user32.ShowWindow(STATE.popup_hwnd, WIN.SW_SHOWNOACTIVATE)
        user32.SetLayeredWindowAttributes(STATE.popup_hwnd, 0, 0, WIN.LWA_ALPHA)
        paint_popup()
    end)
    if not ok then return end
    play_alert()
end

local function step_animation()
    if STATE.active_alert == nil then
        advance_queue()
        return
    end
    if not CONFIG.visual_enabled then
        if timestamp_ms() - STATE.active_alert.started >= CONFIG.duration * 1000 then
            STATE.active_alert = nil
        end
        return
    end
    if STATE.popup_hwnd == nil then
        STATE.active_alert = nil
        return
    end
    if STATE.alpha_ramp > 0 then
        STATE.alpha_value = math.min(STATE.alpha_value + ALPHA_STEP, ALPHA_LIMIT)
        apply_alpha(STATE.alpha_value)
        paint_popup()
        if STATE.alpha_value >= ALPHA_LIMIT then
            STATE.alpha_ramp = 0
        end
    elseif STATE.alpha_ramp == 0 then
        if timestamp_ms() >= STATE.popup_deadline then
            STATE.alpha_ramp = -1
        end
    else
        STATE.alpha_value = math.max(STATE.alpha_value - ALPHA_STEP, 0)
        if STATE.alpha_value <= 0 then
            apply_alpha(0)
            user32.ShowWindow(STATE.popup_hwnd, WIN.SW_HIDE)
            STATE.alpha_ramp = 0
            STATE.active_alert = nil
            advance_queue()
            return
        end
        apply_alpha(STATE.alpha_value)
    end
end

local function title_for_replay() return getString("Replay") end
local function title_for_recording() return getString("Recording") end
local function title_for_screenshot() return getString("Screenshot") end

local function title_for_partial(dur)
    local fmt = getString("PartialReplayFormat")
    return string.format(fmt, dur)
end

local function body_saved_to(folder)
    local fmt = getString("SavedToFormat")
    return string.format(fmt, folder or "?")
end

local function enqueue_immediate(title, media_type, path)
    local folder = root_folder_basename(media_type, path)
    enqueue_alert(title, body_saved_to(folder))
end

local function enqueue_pending(title, path)
    STATE.pending[path] = { title = title }
end

local function handle_obs_event(kind, path, media_type)
    if not path or path == "" then return end
    local sfo = sfo_status_read()
    if sfo.live and sfo.enabled then
        enqueue_pending(kind, path)
    else
        enqueue_immediate(kind, media_type, path)
    end
end

local function on_frontend_event(event)
    if STATE.exiting then return end
    if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        if pr_is_active() then
            return
        end
        local path = obs.obs_frontend_get_last_replay()
        handle_obs_event(title_for_replay(), path, "replay")
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        local path = obs.obs_frontend_get_last_recording()
        handle_obs_event(title_for_recording(), path, "recording")
    elseif event == obs.OBS_FRONTEND_EVENT_SCREENSHOT_TAKEN then
        local path = obs.obs_frontend_get_last_screenshot()
        handle_obs_event(title_for_screenshot(), path, "screenshot")
    elseif event == obs.OBS_FRONTEND_EVENT_EXIT then
        STATE.exiting = true
    end
end

local function resolve_pending_if_sfo_down()
    if next(STATE.pending) == nil then return end
    local sfo = sfo_status_read()
    if sfo.live and sfo.enabled then return end
    for path, info in pairs(STATE.pending) do
        local folder = root_folder_basename("replay", path)
        enqueue_alert(info.title, body_saved_to(folder))
    end
    STATE.pending = {}
end

local function process_sfo_moved_events()
    local events = sfo_moved_read_new()
    for _, ev in ipairs(events) do
        local pending = STATE.pending[ev.path]
        if pending then
            local body
            if ev.status == 1 then
                body = body_saved_to(ev.info)
            else
                body = body_saved_to(ev.info ~= "" and ev.info or "OBS")
            end
            enqueue_alert(pending.title, body)
            STATE.pending[ev.path] = nil
        end
    end
end

local function process_pr_notify_events()
    local events = pr_notify_read_new()
    for _, ev in ipairs(events) do
        local title
        if ev.duration and ev.duration > 0 then
            title = title_for_partial(ev.duration)
        else
            title = title_for_replay()
        end
        local sfo = sfo_status_read()
        if sfo.live and sfo.enabled then
            enqueue_pending(title, ev.path)
        else
            local folder = root_folder_basename("replay", ev.path)
            enqueue_alert(title, body_saved_to(folder))
        end
    end
end

local function read_settings(settings)
    if not settings then return end
    CONFIG.visual_enabled = obs.obs_data_get_bool(settings, "visual_enabled")
    CONFIG.sound_enabled = obs.obs_data_get_bool(settings, "sound_enabled")
    CONFIG.scale = math.floor(obs.obs_data_get_double(settings, "scale"))
    CONFIG.position = obs.obs_data_get_string(settings, "position")
    if CONFIG.position == "" then
        CONFIG.position = "top_right"
    end
    CONFIG.duration = obs.obs_data_get_double(settings, "duration")
    CONFIG.sound_file = obs.obs_data_get_string(settings, "sound_file")
    if CONFIG.sound_file ~= "" then
        local found = false
        for _, f in ipairs(STATE.sound_files) do
            if f == CONFIG.sound_file then
                found = true
                break
            end
        end
        if not found then
            CONFIG.sound_file = ""
        end
    end
    if CONFIG.sound_file == "" and #STATE.sound_files > 0 then
        CONFIG.sound_file = STATE.sound_files[1]
    end
end

local function preview_alert(props, p)
    enqueue_alert(getString("TestTitle"), getString("TestBody"))
    return false
end

function script_description()
    init_locale()
    return getString("ScriptDescription")
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "visual_enabled", true)
    obs.obs_data_set_default_bool(settings, "sound_enabled", true)
    obs.obs_data_set_default_double(settings, "scale", 100.0)
    obs.obs_data_set_default_string(settings, "position", "top_right")
    obs.obs_data_set_default_double(settings, "duration", 3.0)
    obs.obs_data_set_default_string(settings, "sound_file", "")
end

function script_properties()
    init_locale()
    local props = obs.obs_properties_create()
    local vis_group = obs.obs_properties_create()
    obs.obs_properties_add_bool(vis_group, "visual_enabled", getString("VisualEnabled"))
    obs.obs_properties_add_float_slider(vis_group, "scale", getString("Scale"), 100, 300, 10)
    local pos = obs.obs_properties_add_list(vis_group, "position", getString("Position"), obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(pos, getString("PosTopRight"), "top_right")
    obs.obs_property_list_add_string(pos, getString("PosTopLeft"), "top_left")
    obs.obs_property_list_add_string(pos, getString("PosBottomRight"), "bottom_right")
    obs.obs_property_list_add_string(pos, getString("PosBottomLeft"), "bottom_left")
    obs.obs_properties_add_float_slider(vis_group, "duration", getString("Duration"), 1, 10, 0.5)
    obs.obs_properties_add_group(props, "group_visual", getString("GroupVisual"), obs.OBS_GROUP_NORMAL, vis_group)
    local snd_group = obs.obs_properties_create()
    obs.obs_properties_add_bool(snd_group, "sound_enabled", getString("SoundEnabled"))
    STATE.sound_files = list_sound_files()
    local snd = obs.obs_properties_add_list(snd_group, "sound_file", getString("SoundFile"), obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    if #STATE.sound_files == 0 then
        obs.obs_property_list_add_string(snd, getString("NoSound"), "")
    else
        for _, f in ipairs(STATE.sound_files) do
            obs.obs_property_list_add_string(snd, f, f)
        end
    end
    obs.obs_properties_add_group(props, "group_sound", getString("GroupSound"), obs.OBS_GROUP_NORMAL, snd_group)
    obs.obs_properties_add_button(props, "test_btn", getString("TestButton"), preview_alert)
    return props
end

function script_load(settings)
    init_locale()
    STATE.sound_files = list_sound_files()
    read_settings(settings)
    prepare_fonts()
    ensure_notification_class()
    pcall(function()
        local orphan = user32.FindWindowA(WND_CLASS_NAME, nil)
        if orphan ~= nil and orphan ~= ffi.cast("HWND", 0) then
            user32.DestroyWindow(orphan)
        end
    end)
    ensure_notification_window()
    STATE.fonts_need_refresh = false
    STATE.event_callback = function(event) pcall(on_frontend_event, event) end
    obs.obs_frontend_add_event_callback(STATE.event_callback)
    obs.timer_add(step_animation, TICK_MS)
end

function script_update(settings)
    STATE.sound_files = list_sound_files()
    read_settings(settings)
    refresh_fonts()
    STATE.fonts_need_refresh = false
end

function script_save(settings)
    obs.obs_data_set_bool(settings, "visual_enabled", CONFIG.visual_enabled)
    obs.obs_data_set_bool(settings, "sound_enabled", CONFIG.sound_enabled)
    obs.obs_data_set_double(settings, "scale", CONFIG.scale)
    obs.obs_data_set_string(settings, "position", CONFIG.position)
    obs.obs_data_set_double(settings, "duration", CONFIG.duration)
    obs.obs_data_set_string(settings, "sound_file", CONFIG.sound_file)
end

function script_tick(seconds)
    pcall(process_pr_notify_events)
    pcall(process_sfo_moved_events)
    pcall(resolve_pending_if_sfo_down)
end

function script_unload()
    if STATE.event_callback then
        obs.obs_frontend_remove_event_callback(STATE.event_callback)
        STATE.event_callback = nil
    end
    obs.timer_remove(step_animation)
    destroy_notification_window()
    if STATE.title_font then
        gdi32.DeleteObject(STATE.title_font)
        STATE.title_font = nil
    end
    if STATE.body_font then
        gdi32.DeleteObject(STATE.body_font)
        STATE.body_font = nil
    end
    if STATE.popup_class_atom and STATE.popup_hinstance then
        pcall(user32.UnregisterClassA, WND_CLASS_NAME, STATE.popup_hinstance)
    end
    STATE.popup_class_atom = nil
    STATE.popup_hinstance = nil
    STATE.pending = {}
    STATE.alert_queue = {}
    STATE.active_alert = nil
end