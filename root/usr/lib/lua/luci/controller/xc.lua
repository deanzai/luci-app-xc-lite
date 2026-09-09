module("luci.controller.xc", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/xc") then
        return
    end

    entry({"admin", "services", "xc"}, template("xc/overview"), _("xc 节点分流"), 60).dependent = true
    entry({"admin", "services", "xc", "status"}, call("act_status")).leaf = true
    entry({"admin", "services", "xc", "get_nodes"}, call("act_get_nodes")).leaf = true
    entry({"admin", "services", "xc", "switch_node"}, call("act_switch_node")).leaf = true
    entry({"admin", "services", "xc", "probe_node"}, call("act_probe_node")).leaf = true
    entry({"admin", "services", "xc", "save_node"}, call("act_save_node")).leaf = true
    entry({"admin", "services", "xc", "delete_node"}, call("act_delete_node")).leaf = true
    entry({"admin", "services", "xc", "switch_source"}, call("act_switch_source")).leaf = true
    entry({"admin", "services", "xc", "test_health"}, call("act_test_health")).leaf = true
    entry({"admin", "services", "xc", "get_settings"}, call("act_get_settings")).leaf = true
    entry({"admin", "services", "xc", "save_settings"}, call("act_save_settings")).leaf = true
    entry({"admin", "services", "xc", "restart_service"}, call("act_restart_service")).leaf = true
    entry({"admin", "services", "xc", "stop_service"}, call("act_stop_service")).leaf = true
    entry({"admin", "services", "xc", "upload"}, call("act_upload")).leaf = true
end

local function call_rpcd(method, input_json)
    local cmd
    if input_json and #input_json > 0 then
        cmd = "echo " .. luci.util.shellquote(input_json) .. " | /usr/libexec/rpcd/luci.xc call " .. method .. " 2>/dev/null"
    else
        cmd = "/usr/libexec/rpcd/luci.xc call " .. method .. " 2>/dev/null"
    end
    local p = io.popen(cmd)
    local res = p and p:read("*a") or "{}"
    if p then p:close() end
    luci.http.prepare_content("application/json")
    luci.http.write(res)
end

local function silent_rpcd(method, input_json)
    local cmd
    if input_json and #input_json > 0 then
        cmd = "echo " .. luci.util.shellquote(input_json) .. " | /usr/libexec/rpcd/luci.xc call " .. method .. " >/dev/null 2>&1"
    else
        cmd = "/usr/libexec/rpcd/luci.xc call " .. method .. " >/dev/null 2>&1"
    end
    os.execute(cmd)
end

function act_status()
    call_rpcd("get_status")
end

function act_get_nodes()
    call_rpcd("get_nodes")
end

function act_switch_node()
    local id = luci.http.formvalue("id")
    call_rpcd("switch_node", string.format('{"id":%d}', tonumber(id) or 0))
end

function act_probe_node()
    local id = luci.http.formvalue("id")
    call_rpcd("probe_node", string.format('{"id":%d}', tonumber(id) or 0))
end

function act_save_node()
    local content = luci.http.content() or "{}"
    call_rpcd("save_node", content)
end

function act_delete_node()
    local id = luci.http.formvalue("id")
    call_rpcd("delete_node", string.format('{"id":%d}', tonumber(id) or 0))
end

function act_switch_source()
    local content = luci.http.content() or "{}"
    call_rpcd("switch_source", content)
end

function act_test_health()
    call_rpcd("test_health")
end

function act_get_settings()
    call_rpcd("get_settings")
end

function act_save_settings()
    local content = luci.http.content() or "{}"
    call_rpcd("save_settings", content)
end

function act_restart_service()
    call_rpcd("restart_service")
end

function act_stop_service()
    call_rpcd("stop_service")
end

function act_upload(target_type)
    local nixio = require "nixio"
    local fs = require "nixio.fs"
    local tmp_file = "/tmp/xc_upload.tmp"
    local file_handle = nil
    local upload_err = nil
    local file_size = 0
    local form_type = nil
    local uploaded_filename = nil

    luci.http.setfilehandler(
        function(meta, chunk, eof)
            local field_name = type(meta) == "table" and meta.name or meta
            if field_name == "type" and chunk and #chunk > 0 then
                form_type = (form_type or "") .. chunk
            end
            if field_name == "file" or (type(meta) == "table" and meta.file) then
                if type(meta) == "table" and meta.file then
                    uploaded_filename = meta.file
                end
                if not file_handle then
                    file_handle = io.open(tmp_file, "wb")
                end
                if file_handle and chunk then
                    file_size = file_size + #chunk
                    if file_size > 60 * 1024 * 1024 then
                        upload_err = "file_too_large"
                        file_handle:close()
                        file_handle = nil
                        os.remove(tmp_file)
                        return
                    end
                    file_handle:write(chunk)
                end
                if file_handle and eof then
                    file_handle:close()
                    file_handle = nil
                end
            end
        end
    )

    -- 必须在进入具体逻辑前调用 formvalue 强制驱动 LuCI 解析整个 multipart 请求流
    local form_val_type = luci.http.formvalue("type")
    local form_val_token = luci.http.formvalue("token")

    if file_handle then
        file_handle:close()
        file_handle = nil
    end

    local query_string = luci.http.getenv("QUERY_STRING") or ""
    local q_type = query_string:match("type=([%w_]+)")
    local raw_type = target_type or form_val_type or form_type or q_type
    if type(raw_type) == "table" then
        raw_type = raw_type[1] or raw_type[#raw_type]
    end
    local upload_type = nil
    if type(raw_type) == "string" and #raw_type > 0 then
        upload_type = raw_type:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    end

    luci.http.header("Access-Control-Allow-Origin", "*")
    luci.http.prepare_content("application/json")

    if upload_err then
        luci.http.write(string.format('{"code":1,"message":"上传失败: %s"}', upload_err))
        return
    end

    local stat = fs.stat(tmp_file)
    if not stat or stat.size == 0 then
        os.remove(tmp_file)
        luci.http.write('{"code":1,"message":"未检测到上传文件或文件为空"}')
        return
    end

    -- 智能识别兜底：若客户端丢失或未传入 type 参数，根据文件特征自动推断
    if not upload_type or (upload_type ~= "xray" and upload_type ~= "geosite" and upload_type ~= "geoip") then
        local f = io.open(tmp_file, "rb")
        local header = f and f:read(4) or ""
        if f then f:close() end

        local lower_name = (uploaded_filename or ""):lower()
        if (header == "\127ELF" and stat.size >= 1024 * 1024) 
           or (header:sub(1, 2) == "\031\139" and (lower_name:find("xray") or lower_name:find("tar.gz") or lower_name:find("tgz")))
           or (header == "PK\03\04" and (lower_name:find("xray") or lower_name:find("zip"))) then
            upload_type = "xray"
        elseif lower_name:find("geosite") or (lower_name:match("%.dat$") and lower_name:find("site")) then
            upload_type = "geosite"
        elseif lower_name:find("geoip") or (lower_name:match("%.dat$") and lower_name:find("ip")) then
            upload_type = "geoip"
        end
    end

    local BIN_DIR = "/etc/xc/bin"
    local ASSET_DIR = "/etc/xc/assets"
    fs.mkdirr(BIN_DIR)
    fs.mkdirr(ASSET_DIR)

    if upload_type == "xray" then
        if stat.size < 50 * 1024 then
            os.remove(tmp_file)
            luci.http.write('{"code":1,"message":"文件异常：Xray 上传文件过小，请检查是否完整"}')
            return
        end

        local f = io.open(tmp_file, "rb")
        local header = f and f:read(4) or ""
        if f then f:close() end

        local is_zip = (header == "PK\03\04")
        local is_gzip = (header:sub(1, 2) == "\031\139")
        local is_elf = (header == "\127ELF")

        if is_zip or is_gzip then
            local extract_dir = "/tmp/xc_extract_" .. os.time()
            fs.mkdirr(extract_dir)
            local unpack_cmd = nil
            local archive_type = is_zip and "zip" or "tar.gz"

            if is_zip then
                local check_unzip = os.execute("which unzip >/dev/null 2>&1")
                if check_unzip ~= 0 then
                    os.remove(tmp_file)
                    os.execute(string.format("rm -rf %s", luci.util.shellquote(extract_dir)))
                    luci.http.write('{"code":1,"message":"解压工具缺失：系统未安装 unzip 工具。请先在路由器安装 unzip (opkg install unzip) 或使用 tar.gz / 二进制核心上传"}')
                    return
                end
                unpack_cmd = string.format("unzip -q -o %s -d %s 2>&1", luci.util.shellquote(tmp_file), luci.util.shellquote(extract_dir))
            else
                unpack_cmd = string.format("tar -xzf %s -C %s 2>&1", luci.util.shellquote(tmp_file), luci.util.shellquote(extract_dir))
            end

            local unpack_ret = os.execute(unpack_cmd)
            os.remove(tmp_file)

            if unpack_ret ~= 0 then
                os.execute(string.format("rm -rf %s", luci.util.shellquote(extract_dir)))
                luci.http.write(string.format('{"code":1,"message":"压缩包异常：%s 自动解压失败，请确认压缩包是否损坏或带有密码"}', archive_type))
                return
            end

            -- 遍历解压出来的文件，检测 ELF 可执行程序，优先匹配名为 xray 或 xray-core
            local p = io.popen(string.format("find %s -type f 2>/dev/null", luci.util.shellquote(extract_dir)))
            local candidate_file = nil
            local xray_named_file = nil

            if p then
                for line in p:lines() do
                    local fpath = line:gsub("^%s+", ""):gsub("%s+$", "")
                    local hf = io.open(fpath, "rb")
                    local hmagic = hf and hf:read(4) or ""
                    if hf then hf:close() end
                    if hmagic == "\127ELF" then
                        local fname = fpath:match("([^/]+)$")
                        if fname == "xray" or fname == "xray-core" then
                            xray_named_file = fpath
                            break
                        elseif not candidate_file then
                            candidate_file = fpath
                        end
                    end
                end
                p:close()
            end

            local chosen_file = xray_named_file or candidate_file
            if not chosen_file then
                os.execute(string.format("rm -rf %s", luci.util.shellquote(extract_dir)))
                luci.http.write('{"code":1,"message":"解压完成，但在压缩包内未找到 Linux ELF 二进制程序 (xray)"}')
                return
            end

            local dest = BIN_DIR .. "/xray"
            os.remove(dest)
            os.execute(string.format("cp -f %s %s", luci.util.shellquote(chosen_file), luci.util.shellquote(dest)))
            os.execute(string.format("rm -rf %s", luci.util.shellquote(extract_dir)))
            fs.chmod(dest, 755)

            -- 快速校验架构兼容性与版本号
            local ver_p = io.popen(dest .. " version 2>&1 | head -n 1")
            local ver_str = ver_p and ver_p:read("*l") or ""
            if ver_p then ver_p:close() end

            if not ver_str or not ver_str:find("Xray") then
                os.execute("logger -t xc-upload -p daemon.warn " .. luci.util.shellquote("Extracted xray binary could not be executed: " .. (ver_str or "none")))
                luci.http.write(string.format('{"code":1,"message":"架构不兼容：解压出的 Xray 核心无法正常运行，请确认是否为 ARM64 (aarch64) 架构 (测试输出: %s)"}', ver_str or "无法运行"))
                return
            end

            os.execute("logger -t xc-upload -p daemon.info " .. luci.util.shellquote("Successfully installed xray core from " .. archive_type .. ": " .. ver_str))
            silent_rpcd("switch_source", '{"core_source":"custom"}')
            luci.http.write(string.format('{"code":0,"message":"Xray %s 压缩包已自动解压并成功激活为自定义核心！(%s)"}', archive_type:upper(), ver_str))
            return
        end

        if not is_elf then
            os.remove(tmp_file)
            luci.http.write('{"code":1,"message":"格式错误：不是合法的 Linux ELF 二进制可执行文件或 .zip / .tar.gz 压缩包"}')
            return
        end

        if stat.size < 1024 * 1024 then
            os.remove(tmp_file)
            luci.http.write('{"code":1,"message":"文件异常：Xray 核心程序过小 (< 1MB)，请检查文件是否完整"}')
            return
        end

        local dest = BIN_DIR .. "/xray"
        os.remove(dest)
        if not fs.move(tmp_file, dest) then
            os.execute(string.format("cp -f %s %s && rm -f %s", tmp_file, dest, tmp_file))
        end
        fs.chmod(dest, 755)

        -- 快速校验架构兼容性与版本号
        local ver_p = io.popen(dest .. " version 2>&1 | head -n 1")
        local ver_str = ver_p and ver_p:read("*l") or ""
        if ver_p then ver_p:close() end

        if not ver_str or not ver_str:find("Xray") then
            os.execute("logger -t xc-upload -p daemon.warn " .. luci.util.shellquote("Uploaded xray binary could not be executed: " .. (ver_str or "none")))
            luci.http.write(string.format('{"code":1,"message":"架构不兼容：核心无法正常运行，请确认是否为 ARM64 (aarch64) 架构 (测试输出: %s)"}', ver_str or "无法运行"))
            return
        end

        os.execute("logger -t xc-upload -p daemon.info " .. luci.util.shellquote("Successfully installed xray core: " .. ver_str))
        silent_rpcd("switch_source", '{"core_source":"custom"}')
        luci.http.write(string.format('{"code":0,"message":"Xray 核心已成功安装并激活为自定义核心！(%s)"}', ver_str))
    elseif upload_type == "geosite" then
        if stat.size < 100 * 1024 then
            os.remove(tmp_file)
            luci.http.write('{"code":1,"message":"文件异常：geosite.dat 过小 (< 100KB)，请检查是否为完整规则库"}')
            return
        end
        local dest = ASSET_DIR .. "/geosite.dat"
        os.remove(dest)
        if not fs.move(tmp_file, dest) then
            os.execute(string.format("cp -f %s %s && rm -f %s", tmp_file, dest, tmp_file))
        end
        fs.chmod(dest, 644)
        os.execute("logger -t xc-upload -p daemon.info 'Successfully uploaded geosite.dat to /etc/xc/assets/geosite.dat'")
        silent_rpcd("switch_source", '{"asset_source":"custom"}')
        luci.http.write('{"code":0,"message":"geosite.dat 规则库已上传并激活生效！"}')
    elseif upload_type == "geoip" then
        if stat.size < 100 * 1024 then
            os.remove(tmp_file)
            luci.http.write('{"code":1,"message":"文件异常：geoip.dat 过小 (< 100KB)，请检查是否为完整规则库"}')
            return
        end
        local dest = ASSET_DIR .. "/geoip.dat"
        os.remove(dest)
        if not fs.move(tmp_file, dest) then
            os.execute(string.format("cp -f %s %s && rm -f %s", tmp_file, dest, tmp_file))
        end
        fs.chmod(dest, 644)
        os.execute("logger -t xc-upload -p daemon.info 'Successfully uploaded geoip.dat to /etc/xc/assets/geoip.dat'")
        silent_rpcd("switch_source", '{"asset_source":"custom"}')
        luci.http.write('{"code":0,"message":"geoip.dat 规则库已上传并激活生效！"}')
    else
        os.remove(tmp_file)
        luci.http.write('{"code":1,"message":"未知的上传文件类型"}')
    end
end
