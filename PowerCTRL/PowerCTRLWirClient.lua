-- =================================================================
-- PowerCTRLWirClient.lua (UI Restoration Edition)
-- =================================================================
term.clear()
term.setCursorPos(1,1)
print("--- EMS CLIENT SETUP ---")
write("Server Channel: ")
local channel = tonumber(read()) or 48

local wirelessModem
for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if peripheral.getType(name) == "modem" and p.isWireless() then wirelessModem = p end
end

if not wirelessModem then error("Wireless Modem NOT found!") end
wirelessModem.open(channel)

local function drawUI(mon, data)
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    mon.setTextScale(w < 40 and 0.5 or 1)

    mon.setCursorPos(2, 1)
    mon.setTextColor(colors.yellow)
    mon.write("Energy Maintenance System")

    -- Left Panel
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

    -- Buttons
    mon.setCursorPos(2, 11)
    mon.setBackgroundColor(colors.green)
    mon.setTextColor(colors.black)
    mon.write(" [ ENABLE ] ")
    mon.setCursorPos(15, 11)
    mon.setBackgroundColor(colors.red)
    mon.setTextColor(colors.white)
    mon.write(" [ DISABLE ] ")
    mon.setBackgroundColor(colors.black)

    -- Battery Bar (Right)
    local bX, bW = w - 4, 3
    mon.setCursorPos(bX - 4, 2)
    mon.setTextColor(colors.lightGray)
    mon.write("Storage %")

    local bH = h - 3
    local fill = math.floor(data.percent * (bH - 2))
    mon.setBackgroundColor(colors.gray)
    for y = 3, h-1 do
        mon.setCursorPos(bX, y); mon.write(" ")
        mon.setCursorPos(bX+bW, y); mon.write(" ")
    end
    for x = bX, bX+bW do
        mon.setCursorPos(x, 3); mon.write(" "); mon.setCursorPos(x, h-1); mon.write(" ")
    end

    mon.setBackgroundColor(colors.green)
    for i = 0, fill - 1 do
        mon.setCursorPos(bX+1, (h-2)-i)
        mon.write(string.rep(" ", bW-1))
    end

    -- Rod Graphic
    local rX, rY = bX - 7, h - 2
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.gray)
    mon.setCursorPos(rX-1, rY-6) mon.write("RODS")
    for i = 0, 4 do
        local rc = colors.green
        if data.rods == 100 then rc = colors.yellow
        elseif data.rods >= 90 then rc = (i == 0) and colors.red or colors.yellow
        elseif data.rods == 0 then rc = colors.red end
        mon.setBackgroundColor(rc)
        mon.setCursorPos(rX+1, rY-i) mon.write(" ")
    end
end

while true do
    local ev, side, x, y, msg = os.pullEvent()
    if ev == "modem_message" and msg.type == "DATA" then
        for _, n in ipairs(peripheral.getNames()) do
            if peripheral.getType(n) == "monitor" then drawUI(peripheral.wrap(n), msg) end
        end
    elseif ev == "monitor_touch" then
        if y == 5 then wirelessModem.transmit(channel, channel, {type="CMD", cmd="TOGGLE_AUTO"})
        elseif y == 11 and x < 14 then wirelessModem.transmit(channel, channel, {type="CMD", cmd="ON"})
        elseif y == 11 and x >= 14 then wirelessModem.transmit(channel, channel, {type="CMD", cmd="OFF"}) end
    end
end
