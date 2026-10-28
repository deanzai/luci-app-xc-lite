module("luci.controller.xc", package.seeall)

local http = require "luci.http"
local util = require "luci.util"
luci.http = http
luci.util = util

function index()
    local nixio = require "nixio"
    if not nixio.fs.access("/etc/config/xc") then
        return
    end

    -- 现代 LuCI 规范：菜单与视图统一由 /usr/share/luci/menu.d/luci-app-xc.json 声明加载
    -- 本控制器仅提供核心大文件安全的流式上传端点，施加严格 root 鉴权与 CSRF 防御
    local e = entry({"admin", "services", "xc", "upload"}, call("act_upload"))
    e.leaf = true
    e.sysauth = "root"
    e.sysauth_authenticator = "htmlauth"
end

local function notify_source_switch(source_payload)
    os.execute("ubus call luci.xc switch_source " .. luci.util.shellquote(source_payload) .. " >/dev/null 2>&1")
end

function act_upload(target_type)
    local nixio = require "nixio"
    local fs = require "nixio.fs"
    local tmp_file = "/tmp/xc_upload.tmp"
    local file_handle = nil
    local upload_err = nil
    local file_size = 0
    local form_type = nil
    local form_token = nil
    local uploaded_filename = nil

    luci.http.setfilehandler(
        function(meta, chunk, eof)
            local field_name = type(meta) == "table" and meta.name or meta
            if field_name == "type" and chunk and #chunk > 0 then
                form_type = (form_type or "") .. chunk
            end
            if field_name == "token" and chunk and #chunk > 0 then
                form_token = (form_token or "") .. chunk
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

    -- 驱动解析 multipart 请求流并提取参数与 CSRF Token
    local form_val_type = luci.http.formvalue("type")
    local form_val_token = luci.http.formvalue("token") or form_token
    local query_string = luci.http.getenv("QUERY_STRING") or ""
    if not form_val_token and query_string then
        form_val_token = query_string:match("token=([%w_%-]+)")
    end
    if not form_val_token then
        form_val_token = luci.http.getenv("HTTP_X_CSRF_TOKEN")
    end

    if file_handle then
        file_handle:close()
        file_handle = nil
    end

    luci.http.prepare_content("application/json")

    -- CSRF Token 严格安全鉴权校验
    local session_token = (luci.http.context and luci.http.context.token)
        or (luci.dispatcher and luci.dispatcher.context and (luci.dispatcher.context.token or luci.dispatcher.context.requesttoken))
    if not session_token or form_val_token ~= session_token then
        os.remove(tmp_file)
        luci.http.status(403, "Forbidden")
        luci.http.write('{"code":403,"message":"CSRF Token 鉴权失败，请刷新页面重新登录"}')
        return
    end

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
            local archive_type = is_zip and "zip" or "tar.gz"

            if is_zip then
                local check_unzip = os.execute("which unzip >/dev/null 2>&1")
                if check_unzip ~= 0 then
                    os.remove(tmp_file)
                    os.execute(string.format("rm -rf %s", luci.util.shellquote(extract_dir)))
                    luci.http.write('{"code":1,"message":"解压工具缺失：系统未安装 unzip 工具。请先在路由器安装 unzip (opkg install unzip) 或使用 tar.gz / 二进制核心上传"}')
                    return
                end
            end

            local unpack_cmd = is_zip 
                and string.format("unzip -o -q %s -d %s", luci.util.shellquote(tmp_file), luci.util.shellquote(extract_dir))
                or string.format("tar -zxf %s -C %s", luci.util.shellquote(tmp_file), luci.util.shellquote(extract_dir))

            local unpack_ret = os.execute(unpack_cmd)
            os.remove(tmp_file)

            if unpack_ret ~= 0 then
                os.execute(string.format("rm -rf %s", luci.util.shellquote(extract_dir)))
                luci.http.write(string.format('{"code":1,"message":"解压失败：无法解压上传的 %s 压缩包"}', archive_type))
                return
            end

            local find_cmd = string.format("find %s -type f \\( -name 'xray' -o -name 'Xray' \\) | head -n 1", luci.util.shellquote(extract_dir))
            local fp = io.popen(find_cmd)
            local found_xray = fp and fp:read("*l") or ""
            if fp then fp:close() end

            if not found_xray or #found_xray == 0 then
                os.execute(string.format("rm -rf %s", luci.util.shellquote(extract_dir)))
                luci.http.write('{"code":1,"message":"压缩包内未找到 xray 主程序"}')
                return
            end

            local dest = BIN_DIR .. "/xray"
            os.remove(dest)
            local cp_ret = os.execute(string.format("cp -f %s %s", luci.util.shellquote(found_xray), luci.util.shellquote(dest)))
            os.execute(string.format("rm -rf %s", luci.util.shellquote(extract_dir)))

            if cp_ret ~= 0 then
                luci.http.write('{"code":1,"message":"核心文件转存至 /etc/xc/bin/xray 失败"}')
                return
            end
        elseif is_elf then
            local dest = BIN_DIR .. "/xray"
            os.remove(dest)
            if not fs.move(tmp_file, dest) then
                local cp_ret = os.execute(string.format("cp -f %s %s && rm -f %s", luci.util.shellquote(tmp_file), luci.util.shellquote(dest), luci.util.shellquote(tmp_file)))
                if cp_ret ~= 0 then
                    luci.http.write('{"code":1,"message":"核心文件转存至 /etc/xc/bin/xray 失败"}')
                    return
                end
            end
        else
            os.remove(tmp_file)
            luci.http.write('{"code":1,"message":"文件格式不支持：请上传 Linux ELF 二进制程序或 .zip / .tar.gz 压缩包"}')
            return
        end

        local dest = BIN_DIR .. "/xray"
        fs.chmod(dest, 755)

        -- 架构执行与版本有效性校验
        local ver_cmd = string.format("%s version 2>&1 | head -n 1", luci.util.shellquote(dest))
        local ver_p = io.popen(ver_cmd)
        local ver_str = ver_p and ver_p:read("*l") or ""
        if ver_p then ver_p:close() end

        if not ver_str or not ver_str:find("Xray") then
            os.remove(dest)
            os.execute("logger -t xc-upload -p daemon.warn " .. luci.util.shellquote("Uploaded xray binary could not be executed: " .. (ver_str or "none")))
            luci.http.write(string.format('{"code":1,"message":"架构不兼容：核心无法正常运行，请确认是否为当前路由器架构 (测试输出: %s)"}', ver_str or "无法运行"))
            return
        end

        os.execute("logger -t xc-upload -p daemon.info " .. luci.util.shellquote("Successfully installed xray core: " .. ver_str))
        notify_source_switch('{"core_source":"custom"}')
        -- 平滑等待监听建立，防止前端过早查询显示端口为红色未监听
        for _ = 1, 15 do
            local p = io.popen("netstat -lnt 2>/dev/null | grep ':7890 '")
            local line = p and p:read("*l")
            if p then p:close() end
            if line then break end
            os.execute("sleep 0.3")
        end
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
            os.execute(string.format("cp -f %s %s && rm -f %s", luci.util.shellquote(tmp_file), luci.util.shellquote(dest), luci.util.shellquote(tmp_file)))
        end
        fs.chmod(dest, 644)
        os.execute("logger -t xc-upload -p daemon.info 'Successfully uploaded geosite.dat to /etc/xc/assets/geosite.dat'")
        notify_source_switch('{"asset_source":"custom"}')
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
            os.execute(string.format("cp -f %s %s && rm -f %s", luci.util.shellquote(tmp_file), luci.util.shellquote(dest), luci.util.shellquote(tmp_file)))
        end
        fs.chmod(dest, 644)
        os.execute("logger -t xc-upload -p daemon.info 'Successfully uploaded geoip.dat to /etc/xc/assets/geoip.dat'")
        notify_source_switch('{"asset_source":"custom"}')
        luci.http.write('{"code":0,"message":"geoip.dat 规则库已上传并激活生效！"}')
    else
        os.remove(tmp_file)
        luci.http.write('{"code":1,"message":"未知的上传文件类型"}')
    end
end
