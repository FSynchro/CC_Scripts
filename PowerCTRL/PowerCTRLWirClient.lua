-- =================================================================
-- PowerCTRLWirClient.lua 
-- =================================================================
local channel = 4335
term.clear()
term.setCursorPos(1,1)
print("--- EMS REMOTE ACTIVE ---")
print("Listening on: " .. channel)

local modem = peripheral.find("modem", function(n, p) return p.isWireless() end)
if not modem then error("No Wireless Modem found!") end
modem.open(channel)

local lastData = nil

local function drawUI(mon, data)
    if not mon then return end
    if not data then
        mon.clear()
        mon.setCursorPos(1,1)
        mon.write("Waiting for Server...")
        return
    end

    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    if mon.setTextScale then mon.setTextScale(w < 40 and 0.5 or 1) end
    
    -- Main Stats
    mon.setTextColor(colors.yellow)
    mon.setCursorPos(2, 1)
    mon.write("Energy Maintenance System")

    mon.setCursorPos(2, 3)
    mon.setTextColor(colors.white)
    mon.write("Energy: ")
    local col = (data.flow == "Charging") and colors.green or ((data.flow == "OVERDRIVE" or data.flow == "Empty") and colors.red or colors.orange)
    mon.setTextColor(col)
    mon.write(data.flow)

    mon.setCursorPos(2, 5)
    mon.setTextColor(colors.white)
    mon.write("Auto-Rods: ")
    mon.setBackgroundColor(data.auto and colors.green or colors.red)
    mon.write(data.auto and " [ ON ] " or " [ OFF ] ")
    mon.setBackgroundColor(colors.black)

    mon.setCursorPos(2, 7)
    mon.write("Rod Level: " .. math.floor(data.rods) .. "%")
    
    mon.setCursorPos(2, 8)
    mon.write("Reactor: ")
    mon.setTextColor(data.active and colors.green or colors.red)
    mon.write(data.active and "ONLINE" or "OFFLINE")

    mon.setCursorPos(2, 11)
    mon.setBackgroundColor(colors.green)
    mon.setTextColor(colors.black)
    mon.write(" [ ENABLE ] ")
    mon.setCursorPos(15, 11)
    mon.setBackgroundColor(colors.red)
    mon.setTextColor(colors.white)
    mon.write(" [ DISABLE ] ")
    mon.setBackgroundColor(colors.black)

    -- Battery Bar Rendering
    local barH = h - 6
    local startY = 4
    local bX = w - 4
    local bFill = math.floor(data.percent * (barH - 2))
    
    mon.setBackgroundColor(colors.gray)
    for y = startY, startY + barH - 1 do mon.setCursorPos(bX, y) mon.write("   ") end
    mon.setBackgroundColor(colors.green)
    for i = 0, bFill - 1 do
        mon.setCursorPos(bX + 1, (startY + barH - 2) - i)
        mon.write(" ")
    end
    mon.setBackgroundColor(colors.black)
end

local function sendCmd(c)
    modem.transmit(channel, channel, {type = "CMD", cmd = c})
end

-- Force initial clear
local monitor = peripheral.find("monitor")
drawUI(monitor, nil)

while true do
    local ev, side, ch, rep, msg = os.pullEvent()
    
    if ev == "modem_message" and ch == channel and type(msg) == "table" and msg.type == "DATA" then
        lastData = msg
        print("[" .. os.date("%H:%M:%S") .. "] Data Received")
        drawUI(monitor, lastData)
    
    elseif ev == "monitor_touch" and lastData then
        local x, y = side, ch -- PullEvent parameters for touch
        if y == 5 then
            sendCmd("TOGGLE_AUTO")
        elseif y == 11 then
            if x < 14 then sendCmd("ON") else sendCmd("OFF") end
        end
    end
end
