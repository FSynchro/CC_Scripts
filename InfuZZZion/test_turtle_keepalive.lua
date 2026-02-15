-- SIMPLE TURTLE KEEPALIVE TEST
-- Run this on a TURTLE to test if it keeps sending keepalives

local CHANNEL = 1742
local modem = peripheral.find("modem")

if not modem then
    print("ERROR: No modem found!")
    print("Please attach an ender modem")
    return
end

print("Found modem!")
modem.open(CHANNEL)
print("Opened channel " .. CHANNEL)

print("")
print("=================================")
print("TURTLE KEEPALIVE TEST")
print("=================================")
print("This will send a keepalive every 5 seconds")
print("Check SERVER console to verify")
print("Press Ctrl+T to stop")
print("=================================")
print("")

local keepaliveTimer = os.startTimer(5)
local count = 0

while true do
    local event, param = os.pullEvent()
    
    if event == "timer" and param == keepaliveTimer then
        count = count + 1
        print("Sending keepalive #" .. count .. "...")
        
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_keepalive",
            data = {
                turtleId = 3,  -- Adjust if needed
                timestamp = os.epoch("utc")
            }
        })
        
        print("Keepalive sent!")
        
        -- Restart timer
        keepaliveTimer = os.startTimer(5)
    end
end
