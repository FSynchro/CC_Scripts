-- =================================================================
-- MainSensor.lua - Item, CPU, and Yellorium Provider
-- =================================================================
local DATA_CHANNEL = 1428
local YELLORIUM_CHANNEL = 1425
local modem = peripheral.find("modem", function(_, p) return p.isWireless() end) 
    or error("No Wireless Modem found")
local me = peripheral.find("appliedenergistics2:interface") 
    or error("No ME Interface found")

print("Main Sensor Online")

while true do
    local successItems, items = pcall(me.listAvailableItems)
    local successCPUs, cpus = pcall(me.getCraftingCPUs)
    
    if successItems and successCPUs then
        local yelloriumCount = 0
        for _, it in ipairs(items) do
            if it.name == "bigreactors:ingotyellorium" or (it.displayName and it.displayName:find("Yellorium Ingot")) then
                yelloriumCount = it.count
            end
        end

        -- Broadcast to NOC
        modem.transmit(DATA_CHANNEL, DATA_CHANNEL, {
            type = "MAIN_NET_DATA",
            items = items,
            cpus = cpus
        })

        -- Broadcast to separate Power Monitor
        modem.transmit(YELLORIUM_CHANNEL, DATA_CHANNEL, {
            type = "AE2_DATA",
            count = yelloriumCount
        })
        
        print(os.date("[%H:%M:%S]") .. " Data Sent")
    end
    sleep(2)
end
