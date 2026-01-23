-- =================================================================
-- PowerCTRLWirClient.lua - FULL RESTORED VERSION
-- =================================================================
local channel = 4335 
local aeChannel = 1425 
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem", function(n, p) return p.isWireless() end)

if not modem then error("No Wireless Modem found!") end
modem.open(channel)
modem.open(aeChannel) 

local lastData = nil
local aeData = { yellorium = 0 } 
local currentView = "REACTOR"
local modemLog = {}
local pendingActive, pendingAuto = nil, nil
local animIndex = 1

local function logMsg(dir, msg)
    local t = os.date("%H:%M:%S")
    local content = (type(msg) == "table") and (msg.type or "CMD") or tostring(msg)
    table.insert(modemLog, 1, "["..t.."] "..dir..": "..content)
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
    mon.setBackgroundColor(colors.gray)
    for i = 0, height - 1 do mon.setCursorPos(x, y + i); mon.write("   ") end
    mon.setBackgroundColor(colors.black)
    for i = 1, height - 2 do mon.setCursorPos(x + 1, y + i); mon.write(" ") end
    local fillHeight = math.floor(percent * (height - 2))
    mon.setBackgroundColor(color)
    for i = 0, fillHeight - 1 do mon.setCursorPos(x + 1, (y + height - 2) - i); mon.write(" ") end
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.setCursorPos(x, y + height); mon.write(math.floor(percent * 100) .. "%")
end

local function drawReactorArt(x, y, active)
    mon.setCursorPos(x, y)
    mon.setTextColor(colors.gray); mon.write("  [")
    mon.setTextColor(colors.red);  mon.write("#####")
    mon.setTextColor(colors.gray); mon.write("]  ")
    mon.setCursorPos(x, y+1); mon.write(" /       \\ ")
    mon.setCursorPos(x, y+2); mon.write("|   ")
    mon.setTextColor(active and colors.lime or colors.red)
    mon.write("(o)"); mon.setTextColor(colors.gray); mon.write("   |")
    mon.setCursorPos(x, y+3); mon.write(" \\")
    if active then
        for i = 1, 7 do
            if i == animIndex then mon.setTextColor(colors.red); mon.write("#")
            else mon.write(" ") end
        end
    else
        mon.setTextColor(colors.gray); mon.write("_______")
    end
    mon.setTextColor(colors.gray); mon.write("/ ")
end

local function drawIngotIcon(x, y, fuelCount)
    mon.setBackgroundColor(colors.yellow)
    mon.setTextColor(colors.black)
    mon.setCursorPos(x+1, y);   mon.write("---")
    mon.setCursorPos(x, y+1);   mon.write("|   |")
    mon.setCursorPos(x, y+2);   mon.write("'---'")
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.yellow)
    mon.setCursorPos(x, y+4); mon.write("Yello")
    mon.setCursorPos(x, y+5); mon.write("Ingots")
    mon.setTextColor(colors.white)
    mon.setCursorPos(x, y+6); mon.write(string.format("%d", math.floor(fuelCount)))
end

local function drawUI()
    mon.setBackgroundColor(colors.black)
    mon.clear()
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

    drawBox(2, 26, 3, 10, "REACTOR STATUS", colors.yellow)
    drawBox(2, 26, 12, 18, "CONTROL", colors.orange)
    drawBox(28, 52, 3, 18, "DIAGNOSTICS", colors.lightBlue)

    if not lastData then
        mon.setTextColor(colors.red); mon.setCursorPos(5, 6); mon.write("WAITING FOR DATA...")
        return
    end

    if pendingActive == lastData.active then pendingActive = nil end
    if pendingAuto == lastData.auto then pendingAuto = nil end

    mon.setTextColor(colors.white); mon.setCursorPos(4, 5); mon.write("Energy: ")
    mon.setTextColor(lastData.flow == "Charging" and colors.green or colors.red); mon.write(lastData.flow)
    mon.setTextColor(colors.white); mon.setCursorPos(4, 7); mon.write("Prod: "..math.floor(lastData.prod).." RF/t")
    mon.setCursorPos(4, 9); mon.write("Status: ")
    local sCol = (pendingActive ~= nil) and colors.yellow or (lastData.active and colors.green or colors.red)
    mon.setTextColor(sCol); mon.write(lastData.active and "ONLINE" or "OFFLINE")

    mon.setCursorPos(4, 14)
    mon.setBackgroundColor(pendingAuto ~= nil and colors.yellow or (lastData.auto and colors.green or colors.red))
    mon.setTextColor(colors.black); mon.write(" AUTO-RODS: "..(lastData.auto and "ON " or "OFF").." ")
    
    mon.setTextColor(colors.white)
    mon.setBackgroundColor(pendingActive == true and colors.yellow or colors.gray)
    mon.setCursorPos(4, 16); mon.write(" [ENABLE] ")
    mon.setBackgroundColor(pendingActive == false and colors.yellow or colors.gray)
    mon.setCursorPos(15, 16); mon.write(" [DISABLE] ")

    drawReactorArt(35, 5, lastData.active)
    drawIngotIcon(31, 11, aeData.yellorium)
    drawVerticalBar(39, 11, 6, (lastData.rods or 0)/100, colors.yellow, "ROD")
    drawVerticalBar(45, 11, 6, (lastData.percent or 0), colors.green, "BATT")
end

local function sendCmd(c)
    local payload = {type = "CMD", cmd = c}
    modem.transmit(channel, channel, payload)
    logMsg("SENT", payload)
end

local animTimer = os.startTimer(0.5)
while true do
    drawUI()
    local ev, p1, p2, p3, p4 = os.pullEvent()
    if ev == "modem_message" then
        if p2 == channel then
            if type(p4) == "table" and p4.type == "DATA" then lastData = p4 end
elseif p2 == aeChannel then
    if type(p4) == "table" then 
        -- This must match the 'count' key sent above
        aeData.yellorium = p4.count or 0 
    end
end        logMsg("RECV", p4)
    elseif ev == "monitor_touch" then
        local x, y = p2, p3
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
    elseif ev == "timer" and p1 == animTimer then
        animIndex = (animIndex % 7) + 1
        animTimer = os.startTimer(0.5)
    end
end
