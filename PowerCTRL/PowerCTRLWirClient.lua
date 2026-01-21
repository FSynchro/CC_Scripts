-- =================================================================
-- PowerCTRLWirClient.lua (Hardcoded 4335 - HD Edition)
-- =================================================================
local channel = 4335 -- Hardcoded as requested
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
    mon.setTextColor(colors.lightGray)
    mon.setCursorPos(x, y - 1); mon.write(label)
    
    mon.setBackgroundColor(colors.gray)
    for i = 0, height - 1 do
        mon.setCursorPos(x, y + i); mon.write("   ")
    end
    
    mon.setBackgroundColor(colors.black)
    for i = 1, height - 2 do
        mon.setCursorPos(x + 1, y + i); mon.write(" ")
    end
    
    mon.setBackgroundColor(color)
    for i = 0, fillHeight - 1 do
        mon.setCursorPos(x + 1, (y + height - 2) - i); mon.write(" ")
    end
    mon.setBackgroundColor(colors.black)
end

-- REACTOR ASCII ART (Changes based on 'active' status)
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
    
    -- Main Layout Containers
    drawBox(2, 26, 2, 10, "CORE STATUS", colors.yellow)
    drawBox(2, 26, 12, 18, "CONTROL", colors.orange)
    drawBox(28, 52, 2, 18, "DIAGNOSTICS", colors.lightBlue)

    if not data then
        mon.setTextColor(colors.red)
        mon.setCursorPos(5, 6); mon.write("WAITING FOR DATA...")
        mon.setCursorPos(5, 7); mon.write("CH: " .. channel)
        return
    end

    -- CORE STATUS
    mon.setTextColor(colors.white)
    mon.setCursorPos(4, 4); mon.write("Energy: ")
    local flowCol = (data.flow == "Charging") and colors.green or colors.red
    mon.setTextColor(flowCol); mon.write(data.flow)
    
    mon.setTextColor(colors.white)
    mon.setCursorPos(4, 6); mon.write("Prod: " .. math.floor(data.prod) .. " RF/t")
    mon.setCursorPos(4, 8); mon.write("Status: ")
    mon.setTextColor(data.active and colors.green or colors.red)
    mon.write(data.active and "ONLINE" or "OFFLINE")

    -- CONTROL BUTTONS
    mon.setCursorPos(4, 14)
    mon.setBackgroundColor(data.auto and colors.green or colors.red)
    mon.setTextColor(colors.black)
    mon.write(" AUTO-RODS: " .. (data.auto and "ON " or "OFF") .. " ")
    
    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.white)
    mon.setCursorPos(4, 16); mon.write(" [ENABLE] ")
    mon.setCursorPos(15, 16); mon.write(" [DISABLE] ")
    mon.setBackgroundColor(colors.black)

    -- DIAGNOSTICS (Right Side)
    drawReactorArt(35, 4, data.active)
    drawVerticalBar(34, 10, 7, data.rods / 100, colors.yellow, "ROD")
    drawVerticalBar(44, 10, 7, data.percent, colors.green, "BATT")
    
    mon.setTextColor(colors.white)
    mon.setCursorPos(34, 17); mon.write(math.floor(data.rods) .. "%")
    mon.setCursorPos(44, 17); mon.write(math.floor(data.percent * 100) .. "%")
end

local function sendCmd(c)
    modem.transmit(channel, channel, {type = "CMD", cmd = c})
end

-- Main Loop
while true do
    drawUI(lastData)
    local ev, side, ch, rep, msg = os.pullEvent()
    
    -- Corrected modem message check
    if ev == "modem_message" and ch == channel then
        if type(msg) == "table" and msg.type == "DATA" then
            lastData = msg
        end
    
    elseif ev == "monitor_touch" and lastData then
        local tx, ty = rep, msg -- monitor_touch returns side, x, y
        if ty == 14 and tx >= 4 and tx <= 20 then
            sendCmd("TOGGLE_AUTO")
        elseif ty == 16 then
            if tx >= 4 and tx <= 13 then sendCmd("ON")
            elseif tx >= 15 and tx <= 24 then sendCmd("OFF") end
        end
    end
end
