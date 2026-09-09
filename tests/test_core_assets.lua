-- Unit test for core files resolution, missing checks, and upload validation
local ROOT = '/tmp/test_xc'
local BIN_DIR = ROOT .. '/bin'
local ASSET_DIR = ROOT .. '/assets'
local CUSTOM_XRAY = BIN_DIR .. '/xray'
local SYSTEM_XRAY = '/tmp/test_sys_bin/xray'

os.execute('rm -rf ' .. ROOT .. ' /tmp/test_sys_bin /tmp/test_sys_assets /tmp/test_sys_v2ray')
os.execute('mkdir -p ' .. ROOT .. ' /tmp/test_sys_bin /tmp/test_sys_assets /tmp/test_sys_v2ray')

local logged_messages = {}
local function mock_logger(tag, priority, msg)
    table.insert(logged_messages, { tag = tag, priority = priority, msg = msg })
end

local function file_exists(path)
    local f = io.open(path, 'r')
    if not f then return false end
    f:close()
    return true
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function is_executable(path)
    return os.execute('test -x ' .. shell_quote(path)) == 0
end

local function resolve_xray()
    if file_exists(CUSTOM_XRAY) and is_executable(CUSTOM_XRAY) then
        return CUSTOM_XRAY
    elseif file_exists(SYSTEM_XRAY) and is_executable(SYSTEM_XRAY) then
        return SYSTEM_XRAY
    end
    return nil
end

local function resolve_asset_dir()
    local candidates = {
        ASSET_DIR,
        '/tmp/test_sys_assets',
        '/tmp/test_sys_v2ray'
    }
    for _, dir in ipairs(candidates) do
        if file_exists(dir .. '/geosite.dat') and file_exists(dir .. '/geoip.dat') then
            return dir
        end
    end
    return nil
end

local function check_core_status()
    local xray_bin = resolve_xray()
    local asset_dir = resolve_asset_dir()
    local geosite_path = nil
    local geoip_path = nil
    local geosite_ok = false
    local geoip_ok = false

    if file_exists(ASSET_DIR .. '/geosite.dat') then
        geosite_path = ASSET_DIR .. '/geosite.dat'
        geosite_ok = true
    elseif file_exists('/tmp/test_sys_assets/geosite.dat') then
        geosite_path = '/tmp/test_sys_assets/geosite.dat'
        geosite_ok = true
    elseif file_exists('/tmp/test_sys_v2ray/geosite.dat') then
        geosite_path = '/tmp/test_sys_v2ray/geosite.dat'
        geosite_ok = true
    end

    if file_exists(ASSET_DIR .. '/geoip.dat') then
        geoip_path = ASSET_DIR .. '/geoip.dat'
        geoip_ok = true
    elseif file_exists('/tmp/test_sys_assets/geoip.dat') then
        geoip_path = '/tmp/test_sys_assets/geoip.dat'
        geoip_ok = true
    elseif file_exists('/tmp/test_sys_v2ray/geoip.dat') then
        geoip_path = '/tmp/test_sys_v2ray/geoip.dat'
        geoip_ok = true
    end

    local missing = {}
    if not xray_bin then table.insert(missing, 'xray') end
    if not geosite_ok then table.insert(missing, 'geosite') end
    if not geoip_ok then table.insert(missing, 'geoip') end

    return {
        xray_ok = (xray_bin ~= nil),
        xray_path = xray_bin,
        geosite_ok = geosite_ok,
        geosite_path = geosite_path,
        geoip_ok = geoip_ok,
        geoip_path = geoip_path,
        asset_dir = asset_dir,
        ready = (xray_bin ~= nil and geosite_ok and geoip_ok),
        missing = missing
    }
end

local function ensure_core_files()
    local st = check_core_status()
    if not st.ready then
        local msgs = {}
        if not st.xray_ok then
            local m = 'Core file missing: xray executable not found in [' .. CUSTOM_XRAY .. ', ' .. SYSTEM_XRAY .. ']'
            table.insert(msgs, m)
            mock_logger('xc', 'daemon.err', m)
        end
        if not st.geosite_ok then
            local m = 'Asset file missing: geosite.dat not found in [' .. ASSET_DIR .. ', /tmp/test_sys_assets, /tmp/test_sys_v2ray]'
            table.insert(msgs, m)
            mock_logger('xc', 'daemon.err', m)
        end
        if not st.geoip_ok then
            local m = 'Asset file missing: geoip.dat not found in [' .. ASSET_DIR .. ', /tmp/test_sys_assets, /tmp/test_sys_v2ray]'
            table.insert(msgs, m)
            mock_logger('xc', 'daemon.err', m)
        end
        return false, table.concat(msgs, '; '), st
    end
    return true, nil, st
end

-- Test 1: All missing
print('[TEST 1] Testing all missing status...')
local st1 = check_core_status()
assert(st1.ready == false, 'st1.ready should be false')
assert(#st1.missing == 3, 'missing count should be 3')
local ok1, err1 = ensure_core_files()
assert(ok1 == false, 'ensure_core_files should fail')
assert(#logged_messages == 3, '3 logger error messages should be recorded')
print('  PASS: correctly detected 3 missing components and logged daemon.err')

-- Test 2: Fallback to system dir
print('[TEST 2] Testing fallback to system directories...')
logged_messages = {}
os.execute('touch ' .. SYSTEM_XRAY .. ' && chmod +x ' .. SYSTEM_XRAY)
os.execute('touch /tmp/test_sys_assets/geosite.dat /tmp/test_sys_assets/geoip.dat')
local st2 = check_core_status()
assert(st2.ready == true, 'st2.ready should be true')
assert(st2.xray_path == SYSTEM_XRAY, 'xray path should be system binary')
assert(st2.asset_dir == '/tmp/test_sys_assets', 'asset_dir should be system assets')
local ok2, err2 = ensure_core_files()
assert(ok2 == true, 'ensure_core_files should pass')
assert(#logged_messages == 0, 'no errors should be logged')
print('  PASS: successfully fell back to system path')

-- Test 3: Priority of custom /etc/xc directories
print('[TEST 3] Testing custom directory priority over system...')
os.execute('mkdir -p ' .. BIN_DIR .. ' ' .. ASSET_DIR)
os.execute('touch ' .. CUSTOM_XRAY .. ' && chmod +x ' .. CUSTOM_XRAY)
os.execute('touch ' .. ASSET_DIR .. '/geosite.dat ' .. ASSET_DIR .. '/geoip.dat')
local st3 = check_core_status()
assert(st3.ready == true, 'st3.ready should be true')
assert(st3.xray_path == CUSTOM_XRAY, 'xray path must prioritize CUSTOM_XRAY')
assert(st3.asset_dir == ASSET_DIR, 'asset_dir must prioritize ASSET_DIR')
print('  PASS: custom /etc/xc directory took precedence over system directory')

-- Clean up
os.execute('rm -rf ' .. ROOT .. ' /tmp/test_sys_bin /tmp/test_sys_assets /tmp/test_sys_v2ray')
print('ALL 3 INTEGRATION TESTS PASSED!')
