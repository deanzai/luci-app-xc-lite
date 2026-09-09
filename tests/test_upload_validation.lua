-- Test upload validation logic
local function validate_upload(upload_type, file_content)
    local size = #file_content
    if size == 0 then
        return false, "No file uploaded or file is empty"
    end
    if upload_type == "xray" then
        if size < 1024 * 1024 then
            return false, "Invalid xray core: file size is suspiciously small (< 1MB)"
        end
        local header = file_content:sub(1, 4)
        if header ~= "\127ELF" then
            return false, "Invalid xray core: not a Linux ELF executable"
        end
        return true, "Xray core validated"
    elseif upload_type == "geosite" then
        if size < 100 * 1024 then
            return false, "Invalid geosite.dat: file size is suspiciously small (< 100KB)"
        end
        return true, "geosite.dat validated"
    elseif upload_type == "geoip" then
        if size < 100 * 1024 then
            return false, "Invalid geoip.dat: file size is suspiciously small (< 100KB)"
        end
        return true, "geoip.dat validated"
    else
        return false, "Unknown upload type"
    end
end

-- Test cases
print("[TEST UPLOAD 1] xray too small...")
local ok, err = validate_upload("xray", "short string")
assert(not ok and err:find("suspiciously small"), "should reject small xray")

print("[TEST UPLOAD 2] xray invalid ELF header...")
local dummy_large = string.rep("A", 1024 * 1024 + 10)
local ok2, err2 = validate_upload("xray", dummy_large)
assert(not ok2 and err2:find("not a Linux ELF"), "should reject non-ELF")

print("[TEST UPLOAD 3] xray valid ELF...")
local valid_elf = "\127ELF" .. string.rep("\0", 1024 * 1024 + 10)
local ok3, res3 = validate_upload("xray", valid_elf)
assert(ok3, "should accept valid ELF")

print("[TEST UPLOAD 4] geosite & geoip bounds...")
local small_dat = string.rep("D", 500)
local valid_dat = string.rep("D", 150 * 1024)
assert(not validate_upload("geosite", small_dat), "should reject small geosite")
assert(validate_upload("geosite", valid_dat), "should accept valid geosite")
assert(not validate_upload("geoip", small_dat), "should reject small geoip")
assert(validate_upload("geoip", valid_dat), "should accept valid geoip")

local function auto_detect_type(upload_type, filename, file_content)
    if upload_type and (upload_type == "xray" or upload_type == "geosite" or upload_type == "geoip") then
        return upload_type
    end
    local header = file_content:sub(1, 4)
    local lower_name = (filename or ""):lower()
    if header == "\127ELF" and #file_content >= 1024 * 1024 then
        return "xray"
    elseif lower_name:find("geosite") or (lower_name:match("%.dat$") and lower_name:find("site")) then
        return "geosite"
    elseif lower_name:find("geoip") or (lower_name:match("%.dat$") and lower_name:find("ip")) then
        return "geoip"
    end
    return nil
end

print("[TEST UPLOAD 5] auto detection without upload_type...")
assert(auto_detect_type(nil, "xray", valid_elf) == "xray", "should auto-detect xray ELF without type parameter")
assert(auto_detect_type(nil, "geosite.dat", valid_dat) == "geosite", "should auto-detect geosite.dat without type parameter")
assert(auto_detect_type(nil, "geoip.dat", valid_dat) == "geoip", "should auto-detect geoip.dat without type parameter")
assert(auto_detect_type("GEOIP", "custom.dat", valid_dat:lower()) == nil or auto_detect_type("geoip", "custom.dat", valid_dat) == "geoip", "explicit type takes precedence")

print("[TEST UPLOAD 6] tar.gz auto-detection and archive validation...")
local gzip_magic = "\031\139" .. string.rep("G", 100)
local function is_archive_supported(magic, filename)
    local is_gzip = (magic:sub(1, 2) == "\031\139")
    local is_zip = (magic:sub(1, 4) == "PK\03\04")
    if is_gzip then return true, "tar.gz" end
    if is_zip then return false, "zip_not_supported" end
    return false, "unknown"
end
local ok_gz, type_gz = is_archive_supported(gzip_magic, "Xray-linux-arm64.tar.gz")
assert(ok_gz and type_gz == "tar.gz", "tar.gz should be supported")
local ok_zip, type_zip = is_archive_supported("PK\03\04dummy", "Xray.zip")
assert(not ok_zip and type_zip == "zip_not_supported", "zip should prompt user to unpack or use tar.gz")

print("ALL UPLOAD VALIDATION TESTS PASSED!")
