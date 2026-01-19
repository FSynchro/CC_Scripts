-- CORE SERVER (Place at Reactor)
print("Enter Wireless Channel (e.g. 100):")
local channel = tonumber(read())
local modem = peripheral.find("modem") or error("No modem!")
modem.open(channel)

local autoMode = true
local lastEnergy = 0

-- [Logic from previous Grid Scanner goes here - Using the scrubToNum functions]
-- (Assuming the getGridData() and calculateRodTarget() functions are here)

print("Server Online. Operating on channel: " .. channel)

while true do
    local data = getGridData() -- Same function as before
    
    -- Reactor Logic
    if data.reactor and autoMode then
        data.reactor.setAllControlRodLevels(calculateRodTarget(data.percent))
    end

    -- Broadcast to Client
    local packet = {
        percent = data.percent,
        prod = data.rProd,
        active = data.rActive,
        rods = data.rodLevel,
        auto = autoMode,
        devices = #data.devices
    }
    modem.transmit(channel, channel, {type="DATA", payload=packet})

    -- Listen for Commands
    local event, side, ch, reply, msg = os.pullEventTimeout("modem_message", 0.5)
    if msg and type(msg) == "table" and msg.type == "CMD" then
        if msg.cmd == "TOGGLE_AUTO" then autoMode = not autoMode
        elseif msg.cmd == "OFF" then 
            autoMode = false
            data.reactor.setActive(false)
        elseif msg.cmd == "ON" then
            data.reactor.setActive(true)
        end
    end
    sleep(0.5)
end
