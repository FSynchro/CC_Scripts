-- =================================================================
-- PowerCTRLWirClient.lua
-- =================================================================
term.clear()
term.setCursorPos(1,1)
print("--- EMS CLIENT SETUP ---")
write("Server Channel: ")
local channel = tonumber(read()) or 50

local modem = peripheral.find("modem") or error("No wireless modem found!")
modem.open(channel)

local function draw(mon, d)
    mon.setBackgroundColor(colors.black)
    mon.clear()
    mon.setCursorPos(1,1)
    mon.setTextColor(colors.yellow)
    mon.write("Reactor: ")
    mon.setTextColor(d.active and colors.green or colors.red)
    mon.write(d.active and "ON" or "OFF")
    
    mon.setCursorPos(1,2)
    mon.setTextColor(colors.white)
    mon.write("Storage: "..math.floor(d.percent * 100).."%")
    
    mon.setCursorPos(1,3)
    mon.write("Flow: "..d.flow)
    
    mon.setCursorPos(1,5)
    mon.setBackgroundColor(colors.green)
    mon.setTextColor(colors.black)
    mon.write(" [ON] ")
    mon.setCursorPos(8,5)
    mon.setBackgroundColor(colors.red)
    mon.setTextColor(colors.white)
    mon.write(" [OFF] ")
    mon.setBackgroundColor(colors.black)
end

print("Client Listening on: "..channel)

while true do
    local ev, side, ch, rep, msg = os.pullEvent()
    
    if ev == "modem_message" and type(msg) == "table" and msg.type == "DATA" then
        -- Find all monitors and draw to them
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "monitor" then
                draw(peripheral.wrap(name), msg)
            end
        end
    
    elseif ev == "monitor_touch" then
        local _, mSide, x, y = ev, side, ch, rep
        if x < 7 then 
            modem.transmit(channel, channel, {type="CMD", cmd="ON"})
        else 
            modem.transmit(channel, channel, {type="CMD", cmd="OFF"})
        end
    end
end
