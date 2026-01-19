-- =================================================================
-- CONFIGURATION & UTILS
-- =================================================================
local function scrubToNum(val)
    if type(val) == "number" then return val end
    if type(val) == "string" then
        local cleaned = val:gsub("[^%d%.%-]", "")
        return tonumber(cleaned) or 0
    end
    if type(val) == "table" then return val.amount or val.energy or 0 end
    return 0
end

local function calculateRodTarget(storagePercent)
    if storagePercent >= 0.80 then return 100 end
    if storagePercent <= 0.05 then return 0 end
    if storagePercent <= 0.20 then return 10 end
    local minS, maxS = 0.20, 0.80
    local minR, maxR = 10, 100
    return math.floor((storagePercent - minS) * (maxR - minR) / (maxS - minS) + minR)
end

-- =================================================================
-- UI DRAWING (FOR CLIENT)
-- =================================================================
local function drawUI(mon, data)
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    mon.setTextScale(w < 40 and 0.5 or 1)

    -- Header
    mon.setCursorPos(2, 1)
    mon.setTextColor(colors.yellow)
    mon.write("Energy Maintenance System")

    -- Energy Status
    mon.setCursorPos(2, 3)
    mon.setTextColor(colors.white)
    mon.write("Energy: ")
    local col = (data.flow == "Charging") and colors.green or (data.flow == "OVERDRIVE" and colors.red or colors.orange)
    mon.setTextColor(col)
    mon.write(data.flow or "Stable")

    -- Automanage Toggle
    mon.setCursorPos(2, 5)
    mon.setTextColor(colors.white)
    mon.write("Automanage CTRL Rods: ")
    mon.setBackgroundColor(data.auto and colors.green or colors.red)
    mon.write(data.auto and " [ ON ] " or " [ OFF ] ")
    mon.setBackgroundColor(colors.black)

    -- Reactor Info
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
    mon.write(string.format("%.1f RF/t", data.prod or 0))

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

    -- Battery/Storage
    local bX, bW = w - 4, 3
    mon.setCursorPos(bX - 4, 2)
    mon.setTextColor(colors.lightGray)
    mon.write("Storage %")
    
    local fill = math.floor(data.percent * (h - 5))
    mon.setBackgroundColor(colors.gray)
    for y = 3, h-1 do
        mon.setCursorPos(bX, y) mon.write(" ")
        mon.setCursorPos(bX+bW, y) mon.write(" ")
    end
    mon.setBackgroundColor(colors.green)
    for i = 0, fill do
        mon.setCursorPos(bX+1, (h-1)-i)
        mon.write(" ")
    end
end

-- =================================================================
-- MAIN LOGIC
-- =================================================================
term.clear()
term.setCursorPos(1,1)
print("--- EMS SYSTEM SETUP ---")
print("1. Server (At Reactor)")
print("2. Client (At Monitor)")
write("Select Mode: ")
local mode = read()
write("Wireless Channel: ")
local channel = tonumber(read())

local modem = peripheral.find("modem") or error("No wireless modem found!")
modem.open(channel)

if mode == "1" then
    -- SERVER MODE
    local autoMode = true
    local lastE = 0
    print("Server running on channel " .. channel)
    
    while true do
        local grid = {totalE = 0, totalM = 0, rProd = 0, rods = 0, active = false, reactor = nil}
        for _, name in ipairs(peripheral.getNames()) do
            local p = peripheral.wrap(name)
            if name:find("BigReactors") then
                grid.reactor = p
                grid.rods = scrubToNum(p.getControlRodLevel(0))
                grid.active = p.getActive()
                local s, stats = pcall(p.getEnergyStats)
                grid.rProd = s and stats.energyProducedLastTick or 0
            end
            local s1, v1 = pcall(p.getEnergyStored)
            local s2, v2 = pcall(p.getEnergyCapacity)
            if s1 and s2 then
                grid.totalE = grid.totalE + scrubToNum(v1)
                grid.totalM = grid.totalM + scrubToNum(v2)
            end
        end
        
        local percent = (grid.totalM > 0) and (grid.totalE / grid.totalM) or 0
        local flow = (percent <= 0.05 and autoMode) and "OVERDRIVE" or (grid.totalE > lastE and "Charging" or "Discharging")
        lastE = grid.totalE

        if grid.reactor and autoMode then
            grid.reactor.setAllControlRodLevels(calculateRodTarget(percent))
        end

        -- Broadcast
        modem.transmit(channel, channel, {
            type="DATA", 
            payload={percent=percent, prod=grid.rProd, active=grid.active, rods=grid.rods, auto=autoMode, flow=flow}
        })

        -- Listen for commands
        local ev, sd, ch, rep, msg = os.pullEventTimeout("modem_message", 0.8)
        if msg and msg.type == "CMD" then
            if msg.cmd == "TOGGLE_AUTO" then autoMode = not autoMode
            elseif msg.cmd == "ON" and grid.reactor then grid.reactor.setActive(true)
            elseif msg.cmd == "OFF" and grid.reactor then 
                autoMode = false
                grid.reactor.setActive(false)
            end
        end
    end

else
    -- CLIENT MODE
    print("Client waiting for data on channel " .. channel)
    while true do
        local ev, sd, ch, rep, msg = os.pullEvent()
        if ev == "modem_message" and msg.type == "DATA" then
            for _, n in ipairs(peripheral.getNames()) do
                if peripheral.getType(n) == "monitor" then drawUI(peripheral.wrap(n), msg.payload) end
            end
        elseif ev == "monitor_touch" then
            local _, _, x, y = ev, sd, ch, rep
            if y == 5 then modem.transmit(channel, channel, {type="CMD", cmd="TOGGLE_AUTO"})
            elseif y == 11 and x < 14 then modem.transmit(channel, channel, {type="CMD", cmd="ON"})
            elseif y == 11 and x >= 14 then modem.transmit(channel, channel, {type="CMD", cmd="OFF"}) end
        end
    end
end
