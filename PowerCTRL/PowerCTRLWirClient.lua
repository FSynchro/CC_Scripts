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
    
    -- Left Info Panel
    mon.setTextColor(colors.yellow)
    mon.setCursorPos(2, 1)
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

    -- Rod Text with AutoManaged tag
    mon.setCursorPos(2, 7)
    mon.setTextColor(colors.white)
    local rodTag = data.auto and " [AutoManaged]" or ""
    mon.write("Rod Insertion: " .. data.rods .. "%" .. rodTag)
    
    mon.setCursorPos(2, 8)
    mon.write("Reactor Status: ")
    mon.setTextColor(data.active and colors.green or colors.red)
    mon.write(data.active and "active" or "inactive")

    mon.setCursorPos(2, 9)
    mon.setTextColor(colors.white)
    mon.write("Reactor Pr: " .. string.format("%.1f RF/t", data.prod))

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

    -------------------------------------------------------
    -- DYNAMIC BARS (Right Side)
    -------------------------------------------------------
    local barH = h - 4
    local startY = 3
    
    -- 1. BATTERY (Far Right)
    local bX = w - 4
    local bPercent = data.percent
    local bFill = math.floor(bPercent * barH)
    
    -- Draw Battery Background (Gray)
    mon.setBackgroundColor(colors.gray)
    for y = startY, startY + barH - 1 do
        mon.setCursorPos(bX, y) mon.write("   ")
    end
    -- Draw Battery Fill (Green)
    mon.setBackgroundColor(colors.green)
    for y = 0, bFill - 1 do
        mon.setCursorPos(bX, (startY + barH - 1) - y)
        mon.write("   ")
    end
    -- Draw Battery % inside
    mon.setCursorPos(bX, startY + (barH / 2))
    mon.setTextColor(colors.white)
    mon.setBackgroundColor(bPercent > 0.5 and colors.green or colors.gray)
    mon.write(math.floor(bPercent * 100))

    -- 2. CONTROL RODS (To the left of Battery)
    local rX = w - 9
    local rPercent = data.rods / 100
    local rFill = math.floor(rPercent * barH)

    -- Draw Rod Background (Yellow)
    mon.setBackgroundColor(colors.yellow)
    for y = startY, startY + barH - 1 do
        mon.setCursorPos(rX, y) mon.write("   ")
    end
    -- Draw Rod Fill (Black - filling from TOP down)
    mon.setBackgroundColor(colors.black)
    for y = 0, rFill - 1 do
        mon.setCursorPos(rX, startY + y)
        mon.write("   ")
    end
    -- Draw Rod % inside
    mon.setCursorPos(rX, startY + (barH / 2))
    mon.setTextColor(colors.white)
    mon.setBackgroundColor(rPercent > 0.5 and colors.black or colors.yellow)
    mon.write(data.rods)

    mon.setBackgroundColor(colors.black)
end

local function sendCmd(c)
    modem.transmit(channel, channel, {type = "CMD", cmd = c})
end

-- Main Event Loop
while true do
    local ev, side, x, y, msg = os.pullEvent()
    
    if ev == "modem_message" and msg and msg.type == "DATA" then
        lastData = msg
        for _, n in ipairs(peripheral.getNames()) do
            if peripheral.getType(n) == "monitor" then drawUI(peripheral.wrap(n), lastData) end
        end
    
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
                lastData.auto = false
                sendCmd("OFF")
            end
        end
        -- Immediate redraw for reactivity
        for _, n in ipairs(peripheral.getNames()) do
            if peripheral.getType(n) == "monitor" then drawUI(peripheral.wrap(n), lastData) end
        end
    end
end
