-- Find the specific wireless modem name
local wirelessModem
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
        wirelessModem = peripheral.wrap(name)
        break
    end
end

if not wirelessModem then error("No Wireless Modem found!") end

-- FIX: Retry loop for the ME Interface
local me = nil
print("Searching for AE2 Interface...")
while not me do
    me = peripheral.find("appliedenergistics2:interface")
    if not me then
        print("Error: No ME Interface found! Retrying in 5s...")
        sleep(5)
    end
end
print("Connected to AE2!")

local CHANNEL = 1422

local driveSpecs = {
    ["appliedenergistics2:storage_cell_1k"]   = 1024,
    ["appliedenergistics2:storage_cell_4k"]   = 4096,
    ["appliedenergistics2:storage_cell_16k"]  = 16384,
    ["appliedenergistics2:storage_cell_64k"]  = 65536,
    ["extracells:storage.physical"] = { [0] = 256000, [1] = 1024000, [2] = 4096000, [3] = 16384000 }
}

while true do
    -- Wrap inside a pcall (protected call) to prevent crashing if the network is modified
    local status, items = pcall(me.listAvailableItems)
    
    if status and items then
        local data = { maxBytes = 0, maxTypes = 0, counts = {} }
        
        for _, it in ipairs(items) do
            if driveSpecs[it.name] then
                local capacity = 0
                local label = ""
                
                if type(driveSpecs[it.name]) == "table" then
                    capacity = driveSpecs[it.name][it.damage] or 0
                    label = math.floor(capacity/1024) .. "k"
                else
                    capacity = driveSpecs[it.name]
                    label = it.name:match("storage_cell_(%d+k)") or "1k"
                end
                
                data.maxBytes = data.maxBytes + (capacity * it.count)
                data.maxTypes = data.maxTypes + (63 * it.count)
                data.counts[label] = (data.counts[label] or 0) + it.count
            end
        end
        
        wirelessModem.transmit(CHANNEL, CHANNEL, data)
        print("Update Sent: " .. data.maxBytes .. " Bytes | " .. data.maxTypes .. " Types")
    else
        print("Error reading ME Network. Is the Interface connected?")
    end
    
    sleep(6) -- 6 second update interval
end
