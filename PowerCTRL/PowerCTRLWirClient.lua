-- =================================================================
-- PowerCTRLWirClient.lua (Robust Version)
-- =================================================================
print("--- EMS CLIENT SETUP ---")
write("Server Channel: ")
local input = read()
local channel = tonumber(input) or 55

local modem = peripheral.find("modem") or error("No wireless modem found!")
modem.open(channel)

local function drawUI(mon, data)
    if not data then return end
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    
    -- Safe Text Scaling
    local scale = w < 40 and 0.5 or 1
    mon.setTextScale(scale)

    mon.setCursorPos(2, 1)
    mon.setTextColor(colors.yellow)
    mon.write("Energy Maintenance System")

    mon.setCursorPos(2, 3)
    mon.setTextColor(colors.white)
    mon.write("Energy: ")
    local col = (data.flow == "Charging") and colors.green or (data.flow == "OVERDRIVE" and colors.red or colors.orange)
    mon.setTextColor(col)
    mon.write(tostring(data.flow or "Stable"))

    mon.setCursorPos(2, 5)
    mon.setTextColor(colors.white)
    mon.write("Automanage CTRL Rods: ")
    mon.setBackgroundColor(data.auto and colors.green or colors.red)
    mon.write(data.auto and " [ ON ] " or " [ OFF ] ")
    mon.setBackgroundColor(colors.black)

    mon.setCursorPos(2, 7)
    mon.setTextColor(colors.white)
    mon.write("Rod Insertion: " .. tostring(data.rods or 0) .. "%")
    
    mon.setCursorPos(2, 8)
    mon.write("Reactor Status: ")
    mon.setTextColor(data.active and colors.green or colors.red)
    mon.write(data.active and "active" or "inactive")

    mon.setCursorPos(2, 9)
    mon.setTextColor(colors.white)
    mon.write("Reactor Pr: ")
    mon.setTextColor(colors.lightBlue)
    mon.write(string.format("%.1f RF/t", data.prod or 0))

    mon.setCursorPos(2, 11)
    mon.setBackgroundColor(colors.green)
    mon.setTextColor(colors.black)
    mon.write(" [ ENABLE ] ")
    mon.setCursorPos(15, 11)
    mon.setBackgroundColor(colors.red)
    mon.setTextColor(colors.white)
    mon.write(" [ DISABLE ] ")
    mon.setBackgroundColor(colors.black)

    -- Storage Bar
    local bX = w - 4
    mon.setCursorPos(bX - 4, 2)
    mon.setTextColor(colors.lightGray)
    mon.write("Storage %")
    
    local fillHeight = h - 5
    local fill = math.floor((data.percent or 0) * fillHeight)
    
    mon.setBackgroundColor(colors.gray)
    for y = 3, h-1 do
        mon.setCursorPos(bX, y) mon.write("   ")
    end
    
    mon.setBackgroundColor(colors.green)
    for i = 0, fill do
        mon.setCursorPos(bX, (h-1)-i)
        mon.write("   ")
    end
end

print("Client Active on channel " .. channel)

while true do
    local event, side, ch, reply, msg = os.pullEvent()
    
    if event == "modem_message" and type(msg) == "table" and msg.type == "DATA" then
        local names = peripheral.getNames()
        for _, n in ipairs(names) do
            if peripheral.getType(n) == "monitor" then
                pcall(drawUI, peripheral.wrap(n), msg.payload)
            end
        end
    elseif event == "monitor_touch" then
        local _, _, x, y = event, side, ch, reply
        if y == 5 then modem.transmit(channel, channel, {type="CMD", cmd="TOGGLE_AUTO"})
        elseif y == 11 and x < 14 then modem.transmit(channel, channel, {type="CMD", cmd="ON"})
        elseif y == 11 and x >= 14 then modem.transmit(channel, channel, {type="CMD", cmd="OFF"}) end
    end
end
