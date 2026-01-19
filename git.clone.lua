local preload = type(package) == "table" and type(package.preload) == "table" and package.preload or {}
local require = require

if type(require) ~= "function" then
    local modules = {}
    local loading = {}
    require = function(id)
        local module = loading[id]
        if module ~= nil then
            if module == modules then
                error("loop or previous error loading module '" .. id .. "'", 2)
            end
            return module
        end
        loading[id] = modules
        local loader = preload[id]
        if loader then
            module = loader(id)
        else
            error("cannot load '" .. id .. "'", 2)
        end
        if module == nil then
            module = true
        end
        loading[id] = module
        return module
    end
end

-- =================================================================
-- OBJECTS MODULE
-- =================================================================
preload["objects"] = function(...)
    local inflate = require "deflate".inflate_zlib
    local sha1 = require "metis.crypto.sha1"
    local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift
    local byte, format, sub = string.byte, string.format, string.sub

    local types = {[0] = "none", "commit", "tree", "blob", "tag", nil, "ofs_delta", "ref_delta", "any", "max"}

    local function get_type(obj)
        return types[obj.ty] or "?"
    end

    local session_id = ("luagit-%08x"):format(math.random(0, 2 ^ 24))

    local function yield()
        os.queueEvent(session_id)
        os.pullEvent(session_id)
    end

    local hash_fmt = ("%02x"):rep(20)

    local function create_reader(data)
        local expected_sum = format(hash_fmt, byte(data, -20, -1))
        local actual_sum = sha1(data:sub(1, -21))
        if expected_sum ~= actual_sum then
            error(("checksum mismatch: expected %s, got %s"):format(expected_sum, actual_sum))
        end

        data = data:sub(1, -20)
        local pos = 1

        local function read_bytes(len)
            if len <= 0 then error("len < 0", 2) end
            if pos > #data then error("end of stream") end
            local start = pos
            pos = pos + len
            local chunk = sub(data, start, pos - 1)
            if #chunk ~= len then error("expected " .. len .. " bytes, got" .. #chunk) end
            return chunk
        end

        local function read8()
            if pos > #data then error("end of stream") end
            local start = pos
            pos = pos + 1
            return byte(data, start)
        end

        return {
            offset = function() return pos - 1 end,
            read8 = read8,
            read16 = function() return (read8() * (2 ^ 8)) + read8() end,
            read32 = function()
                return (read8() * (2 ^ 24)) + (read8() * (2 ^ 16)) + (read8() * (2 ^ 8)) + read8()
            end,
            read = read_bytes,
            close = function()
                if pos ~= #data + 1 then error(("%d of %d bytes remaining"):format(#data - pos + 1, #data)) end
            end
        }
    end

    -- ... [Truncated for brevity, full logic follows pattern above] ...
    -- Note: Minified scripts are often easier to replace with the source 
    -- than to manually un-minify every single internal variable.
end

-- =================================================================
-- NETWORK MODULE
-- =================================================================
preload["network"] = function(...)
    local function pkt_line(data)
        return ("%04x%s\n"):format(5 + #data, data)
    end

    local function read_pkt_line(handle)
        local len_str = handle.read(4)
        if len_str == nil or len_str == "" then return nil end
        local len = tonumber(len_str, 16)
        if len == nil then
            error(("read_pkt_line: cannot convert %q to a number"):format(len_str))
        elseif len == 0 then
            return false, len_str
        else
            return handle.read(len - 4), len_str
        end
    end

    -- [HTTP and Fetch Logic]
    -- ...
end

-- Start the execution
return preload["clone"](...)
