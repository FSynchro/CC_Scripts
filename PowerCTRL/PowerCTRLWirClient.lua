-- =================================================================
-- PowerCTRLWirClient.lua (Industrial HD Edition)
-- =================================================================
local channel = 4335
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem", function(n, p) return p.isWireless() end)

if not modem then error("No Wireless Modem found!") end
modem.open(channel)

local lastData = nil

-- HELPER: Draw a solid HD Box with a Title
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
    mon.setCursorPos(xMin + 2, yMin)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(titleColor or colors.white)
    mon.write(" " .. title .. " ")
    mon.setBackgroundColor(colors.black)
end

-- HELPER: Vertical Bar for ROD/BATT
local function drawVerticalBar(x, y, height, percent, color, label)
    local fillHeight = math.floor(percent * (height - 2))
    -- Label
    mon.setTextColor(colors.lightGray)
    mon.setCursorPos(x, y - 1); mon.write(label)
    -- Border
    mon.setBackgroundColor(colors.gray)
    for i = 0, height - 1 do
        mon.setCursorPos(x, y + i); mon.write("   ")
    end
    -- Content Area
    mon.setBackgroundColor(colors.black)
    for i = 1, height - 2 do
        mon.setCursorPos(x + 1, y + i); mon.write(" ")
    end
    -- Fill (Bottom up)
    mon.setBackgroundColor(color)
    for i = 0, fillHeight - 1 do
        mon.setCursorPos(x + 1, (y + height - 2) - i); mon.write(" ")
    end
    mon.setBackgroundColor(colors.black)
end

-- REACTOR ASCII ART
local function drawReactorArt(x, y, active)
    local col = active and colors.lime or colors.red
    mon.setTextColor(colors.gray)
    mon.setCursorPos(x, y);   mon.write("  [#####]  ")
    mon.setCursorPos(x, y+1); mon.write(" /       \\ ")
    mon.setCursorPos(x, y+2); mon.write("|  ")
    mon.setTextColor(col);    mon.write("(o)"); mon.setTextColor(colors.gray); mon.write("  |")
    mon.setCursorPos(x, y+3); mon.write(" \\_______/ ")
    mon.setTextColor(colors.gray)
end

local function drawUI(data)
    mon.setBackgroundColor(colors.black)
    mon.clear()
    local w, h = mon.getSize()

    -- Layout Containers
    drawBox(2, 26, 2, 10, "CORE STATUS", colors.yellow)
    drawBox(2, 26, 12, 18, "CONTROL", colors.orange)
    drawBox(28, 50, 2, 18, "DIAGNOSTICS", colors.lightBlue)

    if not data then
        mon.setTextColor(colors.red)
        mon.setCursorPos(5, 6); mon.write("WAITING FOR SERVER...")
        return
    end

    -- CORE STATUS (Top Left)
    mon.setTextColor(colors.white)
    mon.setCursorPos(4, 4); mon.write("Energy: ")
    local flowCol = (data.flow == "Charging") and colors.green or colors.red
    mon.setTextColor(flowCol); mon.write(data.flow)
    
    mon.setTextColor(colors.white)
    mon.setCursorPos(4, 6); mon.write("Output: " .. math.floor(data.prod) .. " RF/t")
    mon.setCursorPos(4, 8); mon.write("Status: ")
    mon.setTextColor(data.active and colors.green or colors.red)
    mon.write(data.active and "ONLINE" or "OFFLINE")

    -- CONTROL BUTTONS (Bottom Left)
    mon.setCursorPos(4, 14)
    mon.setBackgroundColor(data.auto and colors.green or colors.red)
    mon.setTextColor(colors.black)
    mon.write(" AUTO-RODS: " .. (data.auto and "ON " or "OFF") .. " ")
    
    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.white)
    mon.setCursorPos(4, 16); mon.write(" [ON] ")
    mon.setCursorPos(12, 16); mon.write(" [OFF] ")
    mon.setBackgroundColor(colors.black)

    -- DIAGNOSTICS (Right Side)
    drawReactorArt(34, 4, data.active)
    drawVerticalBar(32, 10, 7, data.rods / 100, colors.yellow, "ROD")
    drawVerticalBar(42, 10, 7, data.percent, colors.green, "BATT")
    
    mon.setTextColor(colors.white)
    mon.setCursorPos(32, 17); mon.write(math.floor(data.rods) .. "%")
    mon.setCursorPos(42, 17); mon.write(math.floor(data.percent * 100) .. "%")
end

-- Command Sender
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
        -- Button Detection Logic
        if y == 14 and x >= 4 and x <= 20 then
            sendCmd("TOGGLE_AUTO")
        elseif y == 16 then
            if x >= 4 and x <= 9 then sendCmd("ON")
            elseif x >= 12 and x <= 18 then sendCmd("OFF") end
        end
    end
end
