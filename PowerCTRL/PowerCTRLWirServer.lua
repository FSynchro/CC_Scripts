-- =================================================================
-- PowerCTRLWirServer.lua (Robust Version)
-- =================================================================
print("--- EMS SERVER SETUP ---")
write("Wireless Channel: ")
local input = read()
local channel = tonumber(input) or 55

local modem = peripheral.find("modem") or error("No wireless modem found!")
modem.open(channel)

local autoMode = true
local lastTotalEnergy = 0

-- --- Utility Logic ---
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

-- Custom Timeout function to replace pullEventTimeout
local function pullEventWithTimeout(timeout)
    local timer = os.startTimer(timeout)
    while true do
        local event = {os.pullEvent()}
        if event[1] == "modem_message" then
            return table.unpack(event)
        elseif event[1] == "timer" and event[2] == timer then
            return nil
        end
    end
end

local function getGridData()
    local data = { totalE = 0, totalM = 0, devices = {}, reactor = nil, rodLevel = 0, rActive = false, rProd = 0 }
    local names = peripheral.getNames()
    
    for _, name in ipairs(names) do
        local p = peripheral.wrap(name)
        if p then
            if name:find("BigReactors") then
                data.reactor = p
                local sR, vR = pcall(p.getControlRodLevel, 0)
                data.rodLevel = sR and scrubToNum(vR) or 0
                data.rActive = p.getActive()
                local sP, vP = pcall(p.getEnergyStats)
                data.rProd = (sP and type(vP) == "table") and scrubToNum(vP.energyProducedLastTick) or 0
            end
            
            local s1, v1 = pcall(p.getEnergyStored)
            local s2, v2 = pcall(p.getEnergyCapacity)
            if s1 and s2 then
                data.totalE = data.totalE + scrubToNum(v1)
                data.totalM = data.totalM + scrubToNum(v2)
                table.insert(data.devices, name)
            end
        end
    end
    data.percent = (data.totalM > 0) and (data.totalE / data.totalM) or 0
    return data
end

print("Server Online. Operating on channel: " .. channel)

while true do
    local data = getGridData()
    
    local energyFlow = (data.percent <= 0.05 and autoMode) and "OVERDRIVE" or (data.totalE > lastTotalEnergy and "Charging" or "Discharging")
    if data.totalE == lastTotalEnergy then energyFlow = "Stable" end
    lastTotalEnergy = data.totalE

    if data.reactor and autoMode then
        pcall(data.reactor.setAllControlRodLevels, calculateRodTarget(data.percent))
    end

    modem.transmit(channel, channel, {
        type = "DATA",
        payload = {
            percent = data.percent,
            prod = data.rProd,
            active = data.rActive,
            rods = data.rodLevel,
            auto = autoMode,
            flow = energyFlow
        }
    })

    -- Safe Message Handling
    local event, side, ch, reply, msg = pullEventWithTimeout(0.8)
    if msg and type(msg) == "table" and msg.type == "CMD" then
        if msg.cmd == "TOGGLE_AUTO" then autoMode = not autoMode
        elseif msg.cmd == "ON" and data.reactor then data.reactor.setActive(true)
        elseif msg.cmd == "OFF" and data.reactor then 
            autoMode = false
            data.reactor.setActive(false)
        end
    end
end
