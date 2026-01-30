-- =================================================================
-- MainSensor.lua - Item & CPU Data Provider
-- =================================================================
local CHANNEL = 1428
local modem = peripheral.find("modem", function(_, p) return p.isWireless() end) 
    or error("No Wireless Modem found")
local me = peripheral.find("appliedenergistics2:interface") 
    or error("No ME Interface found")

print("Main Sensor Online - Channel " .. CHANNEL)

while true do
    local successItems, items = pcall(me.listAvailableItems)
    local successCPUs, cpus = pcall(me.getCraftingCPUs)
    
    if successItems and successCPUs then
        modem.transmit(CHANNEL, CHANNEL, {
            type = "MAIN_NET_DATA",
            items = items,
            cpus = cpus
        })
        print(os.date("[%H:%M:%S]") .. " Data Sent")
    else
        print("Error reading ME Network")
    end
    sleep(2)
end
