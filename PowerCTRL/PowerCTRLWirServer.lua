-- =================================================================
-- PowerCTRLWirServer.lua
-- =================================================================
print("--- EMS SERVER SETUP ---")
write("Wireless Channel: ")
local channel = tonumber(read())

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

local function getGridData()
    local data = { totalE = 0, totalM = 0, devices = {}, reactor = nil, rodLevel = 0, rActive = false, rProd = 0 }
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if name:find("BigReactors") then
            data.reactor = p
            data.rodLevel = scrubToNum(p.getControlRodLevel(0))
            data.rActive = p.getActive()
            local sP, vP = pcall(p.getEnergyStats)
            data.rProd = (sP and type(vP) == "table") and vP.energyProducedLastTick or 0
        end
        local s1, v1 = pcall(p.getEnergyStored)
        local s2, v2 = pcall(p.getEnergyCapacity)
        if s1 and s2 then
            data.totalE = data.totalE + scrubToNum(v1)
            data.totalM = data.totalM + scrubToNum(v2)
            table.insert(data.devices, name)
        end
    end
    data.percent = (data.totalM > 0) and (data.totalE / data.totalM) or 0
    return data
end

print("Server Online. Listening/Broadcasting...")

while true do
    local data = getGridData()
    
    -- Energy Flow & Overdrive Logic
    local energyFlow = (data.percent <= 0.05 and autoMode) and "OVERDRIVE" or (data.totalE > lastTotalEnergy and "Charging" or "Discharging")
    lastTotalEnergy = data.totalE

    -- Apply Auto-Control
    if data.reactor and autoMode then
        data.reactor.setAllControlRodLevels(calculateRodTarget(data.percent))
    end

    -- Broadcast to Clients
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

    -- Listen for incoming Commands from Client
    local event, side, ch, reply, msg = os.pullEventTimeout("modem_message", 0.8)
    if msg and type(msg) == "table" and msg.type == "CMD" then
        if msg.cmd == "TOGGLE_AUTO" then autoMode = not autoMode
        elseif msg.cmd == "ON" and data.reactor then data.reactor.setActive(true)
        elseif msg.cmd == "OFF" and data.reactor then 
            autoMode = false
            data.reactor.setActive(false)
        end
    end
end
