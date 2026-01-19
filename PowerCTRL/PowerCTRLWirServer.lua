-- =================================================================
-- PowerCTRLWirServer.lua
-- =================================================================
local channel = 50 -- Match your channel
local modem = peripheral.find("modem") or error("No modem")
modem.open(channel)

local lastE = 0

print("Server Running on channel: "..channel)

while true do
    local totalE, totalM, rProd, rActive, rRods = 0, 0, 0, false, 0
    local reactor = nil

    -- 1. Scan Peripherals
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        -- Check for Energy
        local s1, v1 = pcall(p.getEnergyStored)
        local s2, v2 = pcall(p.getEnergyCapacity)
        if s1 and s2 then
            totalE = totalE + v1
            totalM = totalM + v2
        end
        -- Check for Reactor
        if name:find("BigReactors") then
            reactor = p
            rActive = p.getActive()
            rRods = p.getControlRodLevel(0)
            local s3, v3 = pcall(p.getEnergyStats)
            rProd = s3 and v3.energyProducedLastTick or 0
        end
    end

    local pct = (totalM > 0) and (totalE / totalM) or 0
    local flow = (totalE > lastE) and "Charging" or "Discharging"
    lastE = totalE

    -- 2. Send ONLY raw data (No peripheral objects!)
    local packet = {
        type = "DATA",
        percent = pct,
        active = rActive,
        rods = rRods,
        prod = rProd,
        flow = flow
    }
    
    modem.transmit(channel, channel, packet)

    -- 3. Simple Command Listener
    local ev, side, ch, rep, msg = os.pullEventTimeout("modem_message", 0.5)
    if msg and msg.type == "CMD" and reactor then
        if msg.cmd == "ON" then reactor.setActive(true)
        elseif msg.cmd == "OFF" then reactor.setActive(false) end
    end
end
