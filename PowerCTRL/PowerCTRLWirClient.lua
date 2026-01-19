-- =================================================================
-- PowerCTRLWirClient.lua (Dual Modem Edition)
-- =================================================================
term.clear()
term.setCursorPos(1,1)
print("--- EMS CLIENT SETUP ---")
write("Server Channel: ")
local channel = tonumber(read()) or 48

local wirelessModem
for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if peripheral.getType(name) == "modem" and p.isWireless() then
        wirelessModem = p
    end
end

if not wirelessModem then error("Wireless Modem NOT found!") end
wirelessModem.open(channel)

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
    mon.write(" ("..d.flow..")")
    
    mon.setCursorPos(1,4)
    mon.setTextColor(colors.lightBlue)
    mon.write("Gen: "..math.floor(d.prod).." RF/t")
    
    mon.setCursorPos(1,6)
    mon.setBackgroundColor(colors.green)
    mon.setTextColor(colors.black)
    mon.write(" [ON] ")
    mon.setCursorPos(8,6)
    mon.setBackgroundColor(colors.red)
    mon.setTextColor(colors.white)
    mon.write(" [OFF] ")
    mon.setBackgroundColor(colors.black)
end

print("Wireless Link Active on: "..channel)

while true do
    local ev, side, ch, rep, msg = os.pullEvent()
    
    if ev == "modem_message" and msg.type == "DATA" then
        -- Draw to any monitor found on the Wired network
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "monitor" then
                draw(peripheral.wrap(name), msg)
            end
        end
    
    elseif ev == "monitor_touch" then
        local _, mSide, x, y = ev, side, ch, rep
        if x < 7 then 
            wirelessModem.transmit(channel, channel, {type="CMD", cmd="ON"})
        else 
            wirelessModem.transmit(channel, channel, {type="CMD", cmd="OFF"})
        end
    end
end
