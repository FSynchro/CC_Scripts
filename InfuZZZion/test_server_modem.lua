-- SIMPLE SERVER TEST
-- Run this on the SERVER computer to test if it receives messages

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
print("SERVER LISTENING")
print("=================================")
print("Waiting for messages from client...")
print("Press Ctrl+T to stop")
print("=================================")
print("")

while true do
    local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
    
    if channel == CHANNEL then
        print("")
        print("MESSAGE RECEIVED!")
        print("Type: " .. tostring(message.type))
        if message.data then
            print("Data: " .. textutils.serialize(message.data))
        end
        print("")
    end
end
