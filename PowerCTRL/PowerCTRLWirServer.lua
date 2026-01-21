-- =================================================================
-- PowerCTRLWirServer.lua (Main Controller) 
-- =================================================================
local channel = 4335 -- Hardcoded as requested
local updateRate = 5 

term.clear()
term.setCursorPos(1,1)
print("--- EMS SERVER ACTIVE ---")
print("Channel: " .. channel)

local modem = peripheral.find("modem", function(n, p) return p.isWireless() end)
if not modem then error("Wireless Modem NOT found!") end
modem.open(channel)

local autoMode, lastTotalEnergy, energyFlow = true, 0, "Stable"

local function scrubToNum(val)
    if type(val) == "number" then return val end
    if type(val) == "string" then return tonumber(val:gsub("[^%d%.%-]", "")) or 0 end
    return (type(val) == "table" and (val.amount or val.energy)) or 0
end

local function calculateRodTarget(p)
    if p >= 0.80 then return 100 elseif p <= 0.05 then return 0 end
    if p <= 0.20 then return 10 end
    return math.floor((p - 0.20) * (100 - 10) / (0.80 - 0.20) + 10)
end

while true do
    local data = { totalE = 0, totalM = 0, rodLevel = 0, rActive = false, rProd = 0 }
    local reactor = nil

    -- Scan peripherals once per loop
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if name:find("BigReactors") then
            reactor = p
            data.rActive = p.getActive()
            data.rodLevel = scrubToNum(p.getControlRodLevel(0))
            local s, v = pcall(p.getEnergyStats)
            data.rProd = (s and type(v) == "table") and (v.energyProducedLastTick or 0) or 0
        end
        local s1, v1 = pcall(p.getEnergyStored)
        local s2, v2 = pcall(p.getEnergyCapacity)
        if s1 and s2 then
            data.totalE = data.totalE + scrubToNum(v1)
            data.totalM = data.totalM + scrubToNum(v2)
        end
    end

    local percent = (data.totalM > 0) and (data.totalE / data.totalM) or 0
    local diff = data.totalE - lastTotalEnergy
    energyFlow = (percent <= 0.05 and autoMode) and "OVERDRIVE" or (diff > 10 and "Charging" or (diff < -10 and "Discharging" or "Stable"))
    if data.totalE <= 0 then energyFlow = "Empty" end
    lastTotalEnergy = data.totalE

    if reactor and autoMode then reactor.setAllControlRodLevels(calculateRodTarget(percent)) end

    -- Broadcast DATA
    modem.transmit(channel, channel, {
        type = "DATA", percent = percent, active = data.rActive,
        rods = data.rodLevel, prod = data.rProd, flow = energyFlow, auto = autoMode
    })
    print("[" .. os.date("%H:%M:%S") .. "] Data Sent to Ch: " .. channel)

    -- Efficient Listener (Doesn't lag server)
    local timer = os.startTimer(updateRate)
    while true do
        local ev, side, ch, rep, msg = os.pullEvent()
        if ev == "modem_message" and ch == channel and type(msg) == "table" and msg.type == "CMD" then
            print("CMD Received: " .. tostring(msg.cmd))
            if msg.cmd == "TOGGLE_AUTO" then autoMode = not autoMode
            elseif msg.cmd == "ON" and reactor then reactor.setActive(true)
            elseif msg.cmd == "OFF" and reactor then autoMode = false; reactor.setActive(false) end
            break 
        elseif ev == "timer" and side == timer then break end
    end
end
