-- =================================================================
-- CellSensor.lua - Storage Capacity Provider
-- =================================================================
local CHANNEL = 1422
local modem = peripheral.find("modem", function(_, p) return p.isWireless() end) 
    or error("No Wireless Modem found")
local me = peripheral.find("appliedenergistics2:interface") 
    or error("No ME Interface found")

print("Cell Sensor Online - Channel " .. CHANNEL)

while true do
    local status, items = pcall(me.listAvailableItems)
    if status and items then
        modem.transmit(CHANNEL, CHANNEL, {
            type = "CELL_DATA",
            items = items
        })
        print(os.date("[%H:%M:%S]") .. " Cell list sent")
    end
    sleep(2)
end
