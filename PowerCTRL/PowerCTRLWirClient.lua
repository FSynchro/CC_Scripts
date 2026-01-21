-- =================================================================
-- PowerCTRLWirClient.lua (Fully Auto-Scalable HD Edition)
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
    
    -- Only draw title if there's enough room
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
    
    -- Label (Only if enough vertical space)
    if height > 4 then
        mon.setTextColor(colors.lightGray)
        mon.setCursorPos(x, y - 1); mon.write(label:sub(1, width))
    end
    
    -- Border/Background
    mon.setBackgroundColor(colors.gray)
    for i = 0, height - 1 do
        mon.setCursorPos(x, y + i); mon.write(string.rep(" ", width))
    end
    
    -- Empty Interior
    mon.setBackgroundColor(colors.black)
    for i = 1, height - 2 do
        mon.setCursorPos(x + 1, y + i); mon.write(string.rep(" ", width - 2))
    end
    
    -- Progress Fill
    mon.setBackgroundColor(color)
    for i = 0, fillHeight - 1 do
        mon.setCursorPos(x + 1, (y + height - 2) - i); mon.write(string.rep(" ", width - 2))
    end
    mon.setBackgroundColor(colors.black)
end

local function drawUI(data)
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    
    -- Dynamic Scaling variables
    local midX = math.floor(w * 0.52)
    local leftW = midX - 3
    
    -- Boxes
    drawBox(2, midX - 2, 2, math.floor(h * 0.45), "CORE", colors.yellow)
    drawBox(2, midX - 2, math.floor(h * 0.55), h - 1, "CTRL", colors.orange)
    drawBox(midX, w - 1, 2, h - 1, "DIAG", colors.lightBlue)

    if not data then
        mon.setTextColor(colors.red)
        mon.setCursorPos(4, 4); mon.write("OFFLINE")
        return
    end

    -- CORE STATUS (Scales with height)
    mon.setTextColor(colors.white)
    mon.setCursorPos(4, 4); mon.write("E: ")
    mon.setTextColor((data.flow == "Charging") and colors.green or colors.red)
    mon.write(data.flow)
    
    if h > 10 then
        mon.setTextColor(colors.white)
        mon.setCursorPos(4, 6); mon.write("P: " .. math.floor(data.prod))
        mon.setCursorPos(4, 7); mon.write("R: " .. (data.active and "ON" or "OFF"))
    end

    -- CONTROL BUTTONS
    local btnY = math.floor(h * 0.7)
    mon.setCursorPos(4, btnY)
    mon.setBackgroundColor(data.auto and colors.green or colors.red)
    mon.setTextColor(colors.black)
    mon.write(" AUTO ")
    
    if h > 12 then
        mon.setBackgroundColor(colors.gray)
        mon.setTextColor(colors.white)
        mon.setCursorPos(4, btnY + 2); mon.write(" [ON] ")
        mon.setCursorPos(4 + 7, btnY + 2); mon.write(" [OFF] ")
    end
    mon.setBackgroundColor(colors.black)

    -- DIAGNOSTICS (Bars scale with monitor height/width)
    local barWidth = math.max(3, math.floor((w - midX) / 4))
    local barHeight = h - 8
    local barY = 5
    
    drawVerticalBar(midX + 2, barY, barWidth, barHeight, data.rods / 100, colors.yellow, "ROD")
    drawVerticalBar(midX + barWidth + 4, barY, barWidth, barHeight, data.percent, colors.green, "BATT")
end

local function sendCmd(c)
    modem.transmit(channel, channel, {type = "CMD", cmd = c})
end

-- Main Loop
while true do
    drawUI(lastData)
    local ev, side, ch, x, y = os.pullEvent()
    
    if ev == "modem_message" and ch == channel and type(x) == "table" and x.type == "DATA" then
        lastData = x
    elseif ev == "monitor_touch" and lastData then
        local w, h = mon.getSize()
        local btnY = math.floor(h * 0.7)
        -- Scalable Touch detection
        if y == btnY then sendCmd("TOGGLE_AUTO")
        elseif y == btnY + 2 then
            if x < 10 then sendCmd("ON") else sendCmd("OFF") end
        end
    end
end
