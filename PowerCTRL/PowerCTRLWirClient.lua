-- =================================================================
-- PowerCTRLWirClient.lua (Scalable & Fixed Listener)
-- =================================================================
local channel = 4335
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem", function(n, p) return p.isWireless() end)

if not modem then error("No Wireless Modem found!") end
modem.open(channel)

local lastData = nil

-- HELPER: Draw a solid HD Box with a Title (Scalable)
local function drawBox(xMin, xMax, yMin, yMax, title, titleColor)
    mon.setBackgroundColor(colors.gray)
    for x = xMin, xMax do
        mon.setCursorPos(x, yMin); mon.write(" ")
        mon.setCursorPos(x, yMax); mon.write(" ")
    end
    for y = yMin, yMax do
        mon.setCursorPos(xMin, y); mon.write(" ")
        mon.setCursorPos(xMax, y); mon.write(" ")
    end
    
    if (xMax - xMin) > #title + 4 then
        mon.setCursorPos(xMin + 2, yMin)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(titleColor or colors.white)
        mon.write(" " .. title .. " ")
    end
    mon.setBackgroundColor(colors.black)
end

-- HELPER: Vertical Bar (Scalable)
local function drawVerticalBar(x, y, width, height, percent, color, label)
    local fillHeight = math.floor(percent * (height - 2))
    if height > 4 then
        mon.setTextColor(colors.lightGray)
        mon.setCursorPos(x, y - 1); mon.write(label:sub(1, width))
    end
    
    mon.setBackgroundColor(colors.gray)
    for i = 0, height - 1 do
        mon.setCursorPos(x, y + i); mon.write(string.rep(" ", width))
    end
    
    mon.setBackgroundColor(colors.black)
    for i = 1, height - 2 do
        mon.setCursorPos(x + 1, y + i); mon.write(string.rep(" ", width - 2))
    end
    
    mon.setBackgroundColor(color)
    for i = 0, fillHeight - 1 do
        mon.setCursorPos(x + 1, (y + height - 2) - i); mon.write(string.rep(" ", width - 2))
    end
    mon.setBackgroundColor(colors.black)
end

local function drawUI(data)
    local w, h = mon.getSize()
    mon.setBackgroundColor
