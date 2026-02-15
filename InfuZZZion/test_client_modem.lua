-- SIMPLE MODEM TEST
-- Run this on the CLIENT computer to test if messages are being sent

local CHANNEL = 1742
local modem = peripheral.find("modem")

if not modem then
    print("ERROR: No modem found!")
    print("Please attach an ender modem or wireless modem")
    return
end

print("Found modem!")
modem.open(CHANNEL)
print("Opened channel " .. CHANNEL)

print("")
print("=================================")
print("MODEM TEST")
print("=================================")
print("This will send a test message")
print("every time you press a key")
print("")
print("Check the SERVER console to see")
print("if it receives the messages")
print("=================================")
print("")
print("Press any key to send test message...")
print("Press Q to quit")

while true do
    local event, key = os.pullEvent("key")
    
    if key == keys.q then
        print("Quitting...")
        break
    end
    
    print("Sending test message...")
    modem.transmit(CHANNEL, CHANNEL, {
        type = "TEST_MESSAGE",
        data = {
            message = "Hello from client!",
            timestamp = os.epoch("utc")
        }
    })
    print("Message sent!")
end
