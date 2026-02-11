-- Thaumcraft Catalyst Pedestal Computer
-- Monitors the catalyst pedestal for infusion completion

local CHANNEL = 1742
local ID_FILE = "altar_id.dat"

-- State
local modem = peripheral.find("modem")
local pedestal = peripheral.wrap("top")
local altarPosition = nil
local altarId = nil
local lastCatalystItem = nil
local isInfusing = false

if not modem then
    error("No modem found! Please attach an ender modem.")
end

if not pedestal then
    error("No pedestal found above! Place this computer below the catalyst pedestal.")
end

modem.open(CHANNEL)

-- Load saved ID if exists
local function loadSavedId()
    if fs.exists(ID_FILE) then
        local file = fs.open(ID_FILE, "r")
        local data = textutils.unserialize(file.readAll())
        file.close()
        
        if data and data.altarId then
            altarId = data.altarId
            print("Loaded saved altar ID: #" .. altarId)
            return true
        end
    end
    return false
end

-- Save assigned ID
local function saveId()
    local file = fs.open(ID_FILE, "w")
    file.write(textutils.serialize({
        altarId = altarId,
        altarPosition = altarPosition
    }))
    file.close()
end

-- Get position once at startup
local function getPosition()
    print("Getting GPS position...")
    local x, y, z = gps.locate(5)
    if not x then
        error("ERROR: Cannot get GPS position! Make sure GPS is set up.")
    end
    return {
        x = math.floor(x),
        y = math.floor(y),
        z = math.floor(z)
    }
end

-- Get item on pedestal
local function getPedestalItem()
    local item = pedestal.getItemMeta(1)
    if not item then return nil end
    
    return {
        name = item.name,
        displayName = item.displayName,
        damage = item.damage or 0,
        count = item.count,
        rawName = item.rawName
    }
end

-- Register with server
local function registerAltar()
    if altarId then
        -- Re-registering with existing ID
        print("Re-registering altar #" .. altarId .. " with server...")
        modem.transmit(CHANNEL, CHANNEL, {
            type = "altar_reregister",
            data = {
                altarId = altarId,
                catalystPosition = altarPosition
            }
        })
    else
        -- New registration
        print("Registering altar with server...")
        modem.transmit(CHANNEL, CHANNEL, {
            type = "altar_register",
            data = {
                catalystPosition = altarPosition
            }
        })
    end
end

-- Monitor pedestal for changes
local function monitorPedestal()
    local currentItem = getPedestalItem()
    
    -- Check if item changed (infusion completed)
    if isInfusing and currentItem and lastCatalystItem then
        -- Compare items
        if currentItem.name ~= lastCatalystItem.name or 
           currentItem.damage ~= lastCatalystItem.damage then
            print("INFUSION COMPLETE! Item changed.")
            
            -- Notify server
            modem.transmit(CHANNEL, CHANNEL, {
                type = "infusion_complete",
                data = {
                    altarId = altarId,
                    resultItem = currentItem
                }
            })
            
            isInfusing = false
        end
    end
    
    lastCatalystItem = currentItem
end

-- Handle messages from server
local function handleMessage(msg)
    if type(msg) ~= "table" or not msg.type then return end
    
    if msg.type == "altar_id_assigned" then
        if msg.data.catalystPosition.x == altarPosition.x and
           msg.data.catalystPosition.y == altarPosition.y and
           msg.data.catalystPosition.z == altarPosition.z then
            altarId = msg.data.altarId
            
            -- Save the assigned ID
            saveId()
            
            print("")
            print("=================================")
            print("Assigned Altar ID: #" .. altarId)
            print("=================================")
            print("")
        end
    
    elseif msg.type == "infusion_started" then
        if msg.data.altarId == altarId then
            print("Infusion started on this altar")
            isInfusing = true
            lastCatalystItem = getPedestalItem()
        end
    
    elseif msg.type == "request_pedestal_scan" then
        if msg.data.catalystPosition.x == altarPosition.x and
           msg.data.catalystPosition.y == altarPosition.y and
           msg.data.catalystPosition.z == altarPosition.z then
            -- Server wants us to check for surrounding pedestals
            print("Server requested pedestal scan, waiting for turtle...")
        end
    end
end

-- Main loop
local function main()
    print("=================================")
    print("Catalyst Pedestal Computer v2.0")
    print("=================================")
    
    -- Get position once
    altarPosition = getPosition()
    print("Catalyst position: " .. textutils.serialize(altarPosition))
    
    -- Try to load saved ID
    local hasSavedId = loadSavedId()
    
    -- Check pedestal
    local item = getPedestalItem()
    if item then
        print("Current item on pedestal: " .. item.displayName)
    else
        print("No item on pedestal")
    end
    
    -- Register with server (or re-register if we have saved ID)
    registerAltar()
    if hasSavedId then
        print("Re-registering with saved ID #" .. altarId)
    else
        print("Waiting for altar ID assignment...")
    end
    
    -- Start timers
    local monitorTimer = os.startTimer(1)
    local registerTimer = os.startTimer(5)
    local keepaliveTimer = os.startTimer(10)
    
    while true do
        local event, p1, p2, p3, p4, p5 = os.pullEvent()
        
        if event == "modem_message" and p2 == CHANNEL then
            handleMessage(p4)
            
        elseif event == "timer" then
            if p1 == monitorTimer then
                -- Monitor pedestal for changes
                monitorPedestal()
                monitorTimer = os.startTimer(1)
                
            elseif p1 == registerTimer then
                -- Only retry registration if we don't have an ID yet
                if not altarId then
                    print("Retrying registration...")
                    registerAltar()
                else
                    -- We have an ID, just send keepalive
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "altar_keepalive",
                        data = {
                            altarId = altarId,
                            catalystPosition = altarPosition
                        }
                    })
                end
                registerTimer = os.startTimer(5)
                
            elseif p1 == keepaliveTimer then
                -- Send keepalive to server
                if altarId then
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "altar_keepalive",
                        data = {
                            altarId = altarId,
                            catalystPosition = altarPosition
                        }
                    })
                end
                keepaliveTimer = os.startTimer(10)
            end
        end
    end
end

main()
