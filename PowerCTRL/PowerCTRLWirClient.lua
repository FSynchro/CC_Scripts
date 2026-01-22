-- =================================================================
-- PowerCTRLWirClient.lua
-- =================================================================
local channel = 4335 
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem", function(n, p) return p.isWireless() end)

if not modem then error("No Wireless Modem found!") end
modem.open(channel)

local lastData = nil
local currentView = "REACTOR"
local modemLog = {}
local pendingActive, pendingAuto = nil, nil
local animIndex = 1

local function logMsg(dir, msg)
    local t = os.date("%H:%M:%S")
    table.insert(modemLog, 1, "["..t.."] "..dir..": "..(msg.type or "CMD").." "..(msg.cmd or ""))
    if #modemLog > 12 then table.remove(modemLog) end
end

local function drawBox(xMin, xMax, yMin, yMax, title, titleColor)
    mon.setBackgroundColor(colors.gray)
    for x = xMin, xMax do mon.setCursorPos(x, yMin); mon.write(" "); mon.setCursorPos(x, yMax); mon.write(" ") end
    for y = yMin, yMax do mon.setCursorPos(xMin, y); mon.write(" "); mon.setCursorPos(xMax, y); mon.write(" ") end
    mon.setCursorPos(xMin + 2, yMin)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(titleColor or colors.white)
    mon.write(" " .. title .. " ")
end

local function drawVerticalBar(x, y, height, percent, color, label)
    mon.setTextColor(colors.white)
    mon.setBackgroundColor(colors.black)
    mon.setCursorPos(x, y - 1); mon.write(label)
    
    -- 1. Draw Gray Frame
    mon.setBackgroundColor(colors.gray)
    for i = 0, height - 1 do mon.setCursorPos(x, y + i); mon.write("   ") end
    
    -- 2. Draw Black Gutter (Inside)
    mon.setBackgroundColor(colors.black)
    for i = 1, height - 2 do mon.setCursorPos(x + 1, y + i); mon.write(" ") end
    
    -- 3. Draw Color Fill
    local fillHeight = math.floor(percent * (height - 2))
    mon.setBackgroundColor(color)
    for i = 0, fillHeight - 1 do mon.setCursorPos(x + 1, (y + height - 2) - i); mon.write(" ") end
    
    -- 4. Percentage Text
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.setCursorPos(x, y + height); mon.write(math.floor(percent * 100) .. "%")
end

local function drawReactorArt(x, y, active)
    -- Row 1: Top [#####] (Restored colors/structure)
    mon.setCursorPos(x, y)
    mon.setTextColor(colors.gray); mon.write("  [")
    mon.setTextColor(colors.gray);  mon.write("#####")
    mon.setTextColor(colors.gray); mon.write("]  ")

    -- Row 2: Slant
    mon.setCursorPos(x, y+1)
    mon.write(" /       \\ ")

    -- Row 3: Sides and Core
    mon.setCursorPos(x, y+2)
    mon.write("|   ")
    mon.setTextColor(active and colors.lime or colors.red)
    mon.write("(o)")
    mon.setTextColor(colors.gray)
    mon.write("   |")

    -- Row 4: Bottom and Animation
    mon.setCursorPos(x, y+3)
    mon.write(" \\")
    if active then
        -- Knight Rider: 1 red # moving through 7 slots
        for i = 1, 7 do
            if i == animIndex then
                mon.setTextColor(colors.red); mon.write("#")
            else
                mon.write(" ") -- Invisible background
            end
        end
    else
        mon.setTextColor(colors.gray); mon.write("_______")
    end
    mon.setTextColor(colors.gray); mon.write("/ ")
end

local function drawUI()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    
    -- Nav Buttons (Restored white text)
    mon.setTextColor(colors.white)
    mon.setCursorPos(2,1)
    mon.setBackgroundColor(currentView == "REACTOR" and colors.blue or colors.gray)
    mon.write(" [REACTOR] ")
    mon.setCursorPos(15,1)
    mon.setBackgroundColor(currentView == "MODEM" and colors.blue or colors.gray)
    mon.write("  [MODEM]  ")
    mon.setBackgroundColor(colors.black)

    if currentView == "MODEM" then
        drawBox(2, 52, 3, 18, "MODEM TRAFFIC", colors.lightBlue)
        mon.setTextColor(colors.white)
        for i, log in ipairs(modemLog) do
            mon.setCursorPos(4, 4 + i); mon.write(log)
        end
        return
    end

    -- REACTOR VIEW
    drawBox(2, 26, 3, 10, "REACTOR STATUS", colors.yellow)
    drawBox(2, 26, 12, 18, "CONTROL", colors.orange)
    drawBox(28, 52, 3, 18, "DIAGNOSTICS", colors.lightBlue)

    if not lastData then
        mon.setTextColor(colors.red); mon.setCursorPos(5, 6); mon.write("WAITING FOR DATA...")
        return
    end

    -- Sync feedback logic
    if pendingActive == lastData.active then pendingActive = nil end
    if pendingAuto == lastData.auto then pendingAuto = nil end

    -- CORE STATUS
    mon.setTextColor(colors.white); mon.setCursorPos(4, 5); mon.write("Energy: ")
    mon.setTextColor(lastData.flow == "Charging" and colors.green or colors.red); mon.write(lastData.flow)
    mon.setTextColor(colors.white); mon.setCursorPos(4, 7); mon.write("Prod: "..math.floor(lastData.prod).." RF/t")
    mon.setCursorPos(4, 9); mon.write("Status: ")
    local sCol = (pendingActive ~= nil) and colors.yellow or (lastData.active and colors.green or colors.red)
    mon.setTextColor(sCol); mon.write(lastData.active and "ONLINE" or "OFFLINE")

    -- CONTROL
    mon.setCursorPos(4, 14)
    mon.setBackgroundColor(pendingAuto ~= nil and colors.yellow or (lastData.auto and colors.green or colors.red))
    mon.setTextColor(colors.black); mon.write(" AUTO-RODS: "..(lastData.auto and "ON " or "OFF").." ")
    
    mon.setTextColor(colors.white)
    mon.setBackgroundColor(pendingActive == true and colors.yellow or colors.gray)
    mon.setCursorPos(4, 16); mon.write(" [ENABLE] ")
    mon.setBackgroundColor(pendingActive == false and colors.yellow or colors.gray)
    mon.setCursorPos(15, 16); mon.write(" [DISABLE] ")

    -- DIAGNOSTICS (Full layout restoration)
    drawReactorArt(35, 5, lastData.active)
    drawVerticalBar(34, 11, 6, (lastData.rods or 0)/100, colors.yellow, "ROD")
    drawVerticalBar(44, 11, 6, (lastData.percent or 0), colors.green, "BATT")
end

local function sendCmd(c)
    local payload = {type = "CMD", cmd = c}
    modem.transmit(channel, channel, payload)
    logMsg("SENT", payload)
end

-- Timing Loop
local animTimer = os.startTimer(1)
while true do
    drawUI()
    local ev, side, x, y, msg = os.pullEvent()
    
    if ev == "modem_message" and x == channel then
        if type(msg) == "table" and msg.type == "DATA" then lastData = msg end
        logMsg("RECV", msg)
    elseif ev == "monitor_touch" then
        if y == 1 then
            if x >= 2 and x <= 12 then currentView = "REACTOR"
            elseif x >= 15 and x <= 25 then currentView = "MODEM" end
        elseif currentView == "REACTOR" then
            if y == 14 and x >= 4 and x <= 20 then pendingAuto = not (lastData and lastData.auto); sendCmd("TOGGLE_AUTO")
            elseif y == 16 then
                if x >= 4 and x <= 13 then pendingActive = true; sendCmd("ON")
                elseif x >= 15 and x <= 24 then pendingActive = false; sendCmd("OFF") end
            end
        end
    elseif ev == "timer" and side == animTimer then
        animIndex = animIndex + 1
        if animIndex > 7 then animIndex = 1 end
        animTimer = os.startTimer(1) -- Slow 1-second animation
    end
end
