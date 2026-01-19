-- REMOTE CLIENT (Place at Monitor)
print("Enter Server Channel:")
local channel = tonumber(read())
local modem = peripheral.find("modem") or error("No modem!")
modem.open(channel)

local function sendCmd(cmd)
    modem.transmit(channel, channel, {type="CMD", cmd=cmd})
end

-- 

while true do
    local event, side, ch, reply, msg = os.pullEvent()
    
    -- Handle Clicks
    if event == "monitor_touch" then
        local _, _, x, y = event, side, ch, reply
        if y == 5 then sendCmd("TOGGLE_AUTO")
        elseif y == 11 and x < 14 then sendCmd("ON")
        elseif y == 11 and x >= 14 then sendCmd("OFF") end
    
    -- Handle Data from Server
    elseif event == "modem_message" and msg.type == "DATA" then
        local data = msg.payload
        -- Use the same drawUI(monitor, data) logic here
        for _, n in ipairs(peripheral.getNames()) do
            if peripheral.getType(n) == "monitor" then
                drawUI(peripheral.wrap(n), data)
            end
        end
    end
end
