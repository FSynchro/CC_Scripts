-- =================================================================
-- PowerCTRLWirServer.lua (Optimized Edition)
-- =================================================================
term.clear()
term.setCursorPos(1,1)
print("--- EMS SERVER SETUP ---")
write("Wireless Channel: ")
local channel = tonumber(read()) or 48

local modem
for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if peripheral.getType(name) == "modem" and p.isWireless() then 
        modem = p 
    end
end

if not modem then error("Wireless Modem NOT found!") end
modem.open(channel)

-- State Variables
local autoMode = true
local lastTotalEnergy = 0
local energyFlow = "Stable"
local updateInterval = 5 -- Seconds between updates

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

while true do
    local data = { totalE = 0, totalM = 0, rodLevel = 0, rActive = false, rProd = 0 }
    local reactor = nil

    -- 1. Scan Peripherals
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        -- Identify Reactor
        if name:find("BigReactors") or name:find("br_reactor") then
            reactor = p
            data.rActive = p.getActive()
            data.rodLevel = scrubToNum(p.getControlRodLevel(0))
            local sP, vP = pcall(p.getEnergyStats)
            data.rProd = (sP and type(vP) == "table") and (vP.energyProducedLastTick or 0) or 0
        end

        -- Identify Energy Storage (Capacitors, Cells, etc.)
        local s1, v1 = pcall(p.getEnergyStored)
        local s2, v2 = pcall(p.getEnergyCapacity)
        if s1 and s2 then
            data.totalE = data.totalE + scrubToNum(v1)
            data.totalM = data.totalM + scrubToNum(v2)
        end
    end

    -- 2. Calculations
    local percent = (data.totalM > 0) and (data.totalE / data.totalM) or 0
    
    if percent <= 0.05 and autoMode then
        energyFlow = "OVERDRIVE"
    else
        local diff = data.totalE - lastTotalEnergy
        if diff > 100 then energyFlow = "Charging"
        elseif diff < -100 then energyFlow = "Discharging"
        else energyFlow = "Stable" end
    end
    if data.totalE <= 0 and energyFlow ~= "OVERDRIVE" then energyFlow = "Empty" end
    lastTotalEnergy = data.totalE

    -- 3. Apply Automation
    if reactor and autoMode then
        reactor.setAllControlRodLevels(calculateRodTarget(percent))
    end

    -- 4. Broadcast Data
    modem.transmit(channel, channel, {
        type = "DATA",
        percent = percent,
        active = data.rActive,
        rods = data.rodLevel,
        prod = data.rProd,
        flow = energyFlow,
        auto = autoMode
    })

    -- 5. Command Listener / Delay
    -- This waits for a command OR for the 5-second timer to expire
    local timer = os.startTimer(updateInterval)
    while true do
        local ev, side, ch, rep, msg = os.pullEvent()
        if ev == "modem_message" and msg and msg.type == "CMD" then
            if msg.cmd == "TOGGLE_AUTO" then autoMode = not autoMode
            elseif msg.cmd == "ON" and reactor then reactor.setActive(true)
            elseif msg.cmd == "OFF" and reactor then 
                autoMode = false
                reactor.setActive(false)
            end
            break -- Command received, refresh loop immediately to apply changes
        elseif ev == "timer" and side == timer then
            break -- 5 seconds passed, refresh normally
        end
    end
end
