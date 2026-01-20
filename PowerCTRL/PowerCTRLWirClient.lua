-- =================================================================
-- PowerCTRLWirClient.lua
-- =================================================================
term.clear()
term.setCursorPos(1,1)
print("--- EMS REMOTE SETUP ---")
write("Wireless Channel: ")
local channel = tonumber(read()) or 48

local modem = peripheral.find("modem", function(n, p) return p.isWireless() end)
if not modem then error("No Wireless Modem found!") end
modem.open(channel)

local lastData = nil

-- UI RENDERING (Your Original Logic)
local function drawUI(mon, data)
    if not data then
        mon.clear()
        mon.setCursorPos(2,2)
        mon.write("Waiting for Server...")
        return
    end

    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    mon.setTextScale(w < 40 and 0.5 or 1)
    mon.setCursorPos(2, 1)
    mon.setTextColor(colors.yellow)
    mon.write("Energy Maintenance System")

    mon.setCursorPos(2, 3)
    mon.setTextColor(colors.white)
    mon.write("Energy: ")
    local col = colors.orange
    if data.flow == "Charging" then col = colors.green
    elseif data.flow == "OVERDRIVE" or data.flow == "Empty" then col = colors.red end
    mon.setTextColor(col)
    mon.write(data.flow)

    mon.setCursorPos(2, 5)
    mon.setTextColor(colors.white)
    mon.write("Automanage CTRL Rods: ")
    mon.setBackgroundColor(data.auto and colors.green or colors.red)
    mon.write(data.auto and " [ ON ] " or " [ OFF ] ")
    mon.setBackgroundColor(colors.black)

    mon.setCursorPos(2, 7)
    mon.setTextColor(colors.white)
    mon.write("Rod Insertion: " .. data.rods .. "%")
    
    mon.setCursorPos(2, 8)
    mon.write("Reactor Status: ")
    mon.setTextColor(data.active and colors.green or colors.red)
    mon.write(data.active and "active" or "inactive")

    mon.setCursorPos(2, 9)
    mon.setTextColor(colors.white)
    mon.write("Reactor Pr: ")
    mon.setTextColor(colors.lightBlue)
    mon.write(string.format("%.1f RF/t", data.prod))

    mon.setCursorPos(2, 11)
    mon.setBackgroundColor(colors.green)
    mon.setTextColor(colors.black)
    mon.write(" [ ENABLE ] ")
    
    mon.setCursorPos(15, 11)
    mon.setBackgroundColor(colors.red)
    mon.setTextColor(colors.white)
    mon.write(" [ DISABLE ] ")
    mon.setBackgroundColor(colors.black)

    -- Right Side Battery
    local bX, bW = w - 4, 3
    mon.setCursorPos(bX - 4, 2)
    mon.setTextColor(colors.lightGray)
    mon.write("Storage %")

    local bH = h - 3
    local fill = math.floor(data.percent * (bH - 2))
    mon.setBackgroundColor(colors.gray)
    for y = 3, h-1 do
        mon.setCursorPos(bX, y) mon.write(" ")
        mon.setCursorPos(bX+bW, y) mon.write(" ")
    end
    for x = bX, bX+bW do
        mon.setCursorPos(x, 3) mon.write(" ")
        mon.setCursorPos(x, h-1) mon.write(" ")
    end

    mon.setBackgroundColor(colors.green)
    for i = 0, fill - 1 do
        mon.setCursorPos(bX+1, (h-2)-i)
        mon.write(string.rep(" ", bW-1))
    end
end

local function sendCmd(c)
    modem.transmit(channel, channel, {type = "CMD", cmd = c})
end

-- Main Event Loop
while true do
    local ev, side, x, y, msg = os.pullEvent()
    
    -- Handle Data from Server
    if ev == "modem_message" and msg and msg.type == "DATA" then
        lastData = msg
        for _, n in ipairs(peripheral.getNames()) do
            if peripheral.getType(n) == "monitor" then drawUI(peripheral.wrap(n), lastData) end
        end
    
    -- Handle Clicks (Immediate UI change for reactivity)
    elseif ev == "monitor_touch" and lastData then
        if y == 5 then
            lastData.auto = not lastData.auto
            sendCmd("TOGGLE_AUTO")
        elseif y == 11 then
            if x < 14 then
                lastData.active = true
                sendCmd("ON")
            else
                lastData.active = false
                lastData.auto = false -- Disable auto if manually turned off
                sendCmd("OFF")
            end
        end
        -- Redraw immediately with predicted state
        for _, n in ipairs(peripheral.getNames()) do
            if peripheral.getType(n) == "monitor" then drawUI(peripheral.wrap(n), lastData) end
        end
    end
end
