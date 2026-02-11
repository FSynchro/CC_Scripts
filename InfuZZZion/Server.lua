-- Thaumcraft Infusion Automation Server
-- Manages recipes, turtle coordination, and infusion tracking

local CHANNEL = 1742
local DATABASE_FILE = "itemdb.dat"

-- State
local recipes = {}
local activeInfusions = {}
local turtles = {}
local gloveTurtle = nil
local altars = {}
local inputChest = nil
local chestPosition = nil
local meInterfacePosition = nil
local serverPosition = nil
local currentRecipe = nil
local errorMode = false
local errorMessage = ""
local nextTurtleId = 1
local pendingMessages = {} -- For ACK/NACK system
local setupComplete = false
local potentialAltarBlocks = {} -- Relative positions of mana infused steel blocks
local scannerEnergy = 100      -- starting energy
local SCAN_COST = 1700
local ENERGY_REGEN = 10        -- per second
local ENERGY_CAPACITY = 200    -- max energy
local MIN_ENERGY_TO_SCAN = 1700
local MIN_ENERGY_AFTER_SCAN = 80





-- Modem setup
local modem = peripheral.find("modem")
if not modem then
    error("No modem found! Please attach an ender modem on top.")
end
modem.open(CHANNEL)

-- Scanner setup (Plethora block scanner on left)
local scanner = peripheral.wrap("left")
local scanComplete = false

-- Wrap input chest (to the right)
inputChest = peripheral.wrap("right")

-- Get server GPS position
local function getServerPosition()
    print("Getting server GPS position...")
    local x, y, z = gps.locate(5)
    if not x then
        print("WARNING: Could not get GPS position")
        return nil
    end
    return {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
end

-- Scan for chest and ME interface using block scanner (EXPENSIVE - only run once!)
local function scanForPeripherals()
    if scanComplete then
        print("Scan already complete, using cached results")
        return chestPosition ~= nil and meInterfacePosition ~= nil
    end
    
    if not scanner or not scanner.scan then
        print("ERROR: No block scanner found on left side!")
        return false
    end
    
print("Scanner energy: " .. scannerEnergy)
print("Scanning for blocks (costs " .. SCAN_COST .. " energy)...")

-- Perform scan immediately
local blocks = scanner.scan()
scanComplete = true

-- Deduct energy (can go negative)
scannerEnergy = scannerEnergy - SCAN_COST
-- Count discovered blocks
local manaBlocks = 0
local pedestals = 0
local meInterfaces = 0
local chests = 0

for _, block in ipairs(blocks) do
    -- Mana infused metal (Thermal Foundation storage block, meta 8)
    if block.name == "thermalfoundation:storage" and block.metadata == 8 then
        manaBlocks = manaBlocks + 1
    end

    -- Thaumcraft pedestals (adjust name if your modpack uses a variant)
    if block.name and block.name:find("pedestal") then
        pedestals = pedestals + 1
    end

    -- ME Interface
    if block.name and block.name:find("interface") then
        meInterfaces = meInterfaces + 1
    end

    -- Chests
    if block.name and block.name:find("chest") then
        chests = chests + 1
    end
end

print(
    "Scan complete! Energy now: " .. scannerEnergy ..
    " | Found " .. manaBlocks .. " mana blocks, " ..
    pedestals .. " pedestals, " ..
    meInterfaces .. " ME interfaces, " ..
    chests .. " chests"
)

print("Waiting for energy recovery...")


-- Recover until at least MIN_ENERGY_AFTER_SCAN
while scannerEnergy < MIN_ENERGY_AFTER_SCAN do
    sleep(1)
    scannerEnergy = scannerEnergy + ENERGY_REGEN

    -- Cap at max capacity
    if scannerEnergy > ENERGY_CAPACITY then
        scannerEnergy = ENERGY_CAPACITY
    end

    print("Energy recovering: " .. scannerEnergy .. " / " .. MIN_ENERGY_AFTER_SCAN)
end

print("Energy recovered! Processing scan results...")


    
    local chestFound = false
    local meFound = false
    local altarBlockCount = 0
    
    -- Filter blocks
    for _, block in ipairs(blocks) do
        -- Look for chest (should be at relative position right of server)
        if block.name and block.name:find("chest") and block.x == 1 and block.y == 0 and block.z == 0 then
            chestPosition = {
                x = serverPosition.x + block.x,
                y = serverPosition.y + block.y,
                z = serverPosition.z + block.z
            }
            chestFound = true
            print("Found chest at: " .. textutils.serialize(chestPosition))
        end
        
        -- Look for ME Interface
        if block.name and block.name:find("interface") then
            meInterfacePosition = {
                x = serverPosition.x + block.x,
                y = serverPosition.y + block.y,
                z = serverPosition.z + block.z
            }
            meFound = true
            print("Found ME Interface at: " .. textutils.serialize(meInterfacePosition))
        end
        
        -- Look for mana infused steel blocks (thermalfoundation:storage damage 8)
        if block.name == "thermalfoundation:storage" and block.metadata == 8 then
            -- Store relative position
            table.insert(potentialAltarBlocks, {
                x = block.x,
                y = block.y,
                z = block.z
            })
            altarBlockCount = altarBlockCount + 1
        end
    end
    
    print("Found " .. altarBlockCount .. " potential altar blocks (mana infused steel)")
    
    if not chestFound then
        print("ERROR: Chest not found! Make sure it's on the RIGHT side of server.")
    end
    
    if not meFound then
        print("ERROR: ME Interface not found! Make sure it's connected to the chest.")
    end
    
    return chestFound and meFound
end

-- Save database
local function saveDatabase()
    local file = fs.open(DATABASE_FILE, "w")
    file.write(textutils.serialize({
        recipes = recipes,
        altars = altars
    }))
    file.close()
end

-- Load database
local function loadDatabase()
    if fs.exists(DATABASE_FILE) then
        local file = fs.open(DATABASE_FILE, "r")
        local data = textutils.unserialize(file.readAll())
        file.close()
        
        if data then
            recipes = data.recipes or {}
            altars = data.altars or {}
        end
    end
end

-- Compare items with NBT/DMG matching
local function itemsMatch(item1, item2, matchNBT, matchDMG)
    if item1.name ~= item2.name then
        return false
    end
    
    if matchDMG and item1.damage ~= item2.damage then
        return false
    end
    
    if matchNBT and item1.nbt ~= item2.nbt then
        return false
    end
    
    return true
end

-- Send message with ACK expectation
local function sendWithAck(msgType, data, targetId)
    local msgId = os.epoch("utc")
    
    pendingMessages[msgId] = {
        type = msgType,
        data = data,
        targetId = targetId,
        retries = 0,
        maxRetries = 3,
        lastSent = os.epoch("utc")
    }
    
modem.transmit(targetId, CHANNEL, {
    type = msgType,
    data = data,
    msgId = msgId,
    timestamp = os.epoch("utc")
})

    
    return msgId
end

-- Send message to all clients
local function broadcast(msgType, data)
    modem.transmit(CHANNEL, CHANNEL, {
        type = msgType,
        data = data,
        timestamp = os.epoch("utc")
    })
end

-- Handle ACK
local function handleAck(msgId, success, reason)
    if pendingMessages[msgId] then
        if success then
            print("ACK received for message " .. msgId)
            pendingMessages[msgId] = nil
        else
            print("NACK received for message " .. msgId .. ": " .. (reason or "unknown"))
            pendingMessages[msgId] = nil
        end
    end
end

-- Retry pending messages
local function retryPendingMessages()
    local now = os.epoch("utc")
    
    for msgId, msg in pairs(pendingMessages) do
        if now - msg.lastSent > 2000 then -- 2 second timeout
            if msg.retries < msg.maxRetries then
                msg.retries = msg.retries + 1
                msg.lastSent = now
                
                modem.transmit(CHANNEL, CHANNEL, {
                    type = msg.type,
                    data = msg.data,
                    msgId = msgId,
                    timestamp = now
                })
                
                print("Retrying message " .. msgId .. " (attempt " .. msg.retries .. ")")
            else
                print("Message " .. msgId .. " failed after " .. msg.maxRetries .. " retries")
                pendingMessages[msgId] = nil
            end
        end
    end
end

-- Start setup cycle - send turtles to verify altar block positions
local function startSetupCycle()
    if setupComplete then return end
    
    print("")
    print("=================================")
    print("Starting Setup Cycle")
    print("=================================")
    print("Potential altar blocks: " .. #potentialAltarBlocks)
    print("Available turtles: " .. #turtles)
    
    -- Distribute altar blocks to turtles
    local blocksPerTurtle = math.ceil(#potentialAltarBlocks / #turtles)
    local blockIdx = 1
    
    for turtleIdx, turtle in ipairs(turtles) do
        local blocksToCheck = {}
        
        for i = 1, blocksPerTurtle do
            if blockIdx <= #potentialAltarBlocks then
                local relBlock = potentialAltarBlocks[blockIdx]
                -- Convert relative to absolute GPS coordinates
                local absBlock = {
                    x = serverPosition.x + relBlock.x,
                    y = serverPosition.y + relBlock.y,
                    z = serverPosition.z + relBlock.z
                }
                table.insert(blocksToCheck, absBlock)
                blockIdx = blockIdx + 1
            end
        end
        
        if #blocksToCheck > 0 then
            print("Turtle #" .. turtle.id .. " checking " .. #blocksToCheck .. " blocks")
            
            modem.transmit(turtle.computerId, CHANNEL, {
                type = "setup_verify_blocks",
                data = {
                    turtleId = turtle.id,
                    blocks = blocksToCheck
                }
            })
        end
    end
end

-- Complete setup cycle
local function completeSetupCycle()
    setupComplete = true
    print("")
    print("=================================")
    print("Setup Cycle Complete!")
    print("=================================")
    print("Altars found: " .. #altars)
    print("System ready for infusion!")
    print("")
    
    broadcast("setup_complete", {
        altarCount = #altars
    })
end

-- Handle altar discovery response
local function registerAltar(catalystPos, pedestalPositions, reportedBy)
    -- Check if altar already exists
    for _, altar in ipairs(altars) do
        if altar.catalyst.x == catalystPos.x and 
           altar.catalyst.y == catalystPos.y and 
           altar.catalyst.z == catalystPos.z then
            print("Altar already registered at this position")
            return
        end
    end
    
    local altar = {
        catalyst = catalystPos,
        pedestals = pedestalPositions,
        busy = false,
        currentRecipe = nil
    }
    
    table.insert(altars, altar)
    
    -- Sort by distance from server (closer = higher priority)
    table.sort(altars, function(a, b)
        local distA = math.abs(a.catalyst.x - serverPosition.x) + 
                     math.abs(a.catalyst.y - serverPosition.y) + 
                     math.abs(a.catalyst.z - serverPosition.z)
        local distB = math.abs(b.catalyst.x - serverPosition.x) + 
                     math.abs(b.catalyst.y - serverPosition.y) + 
                     math.abs(b.catalyst.z - serverPosition.z)
        return distA < distB
    end)
    
    print("Registered altar #" .. #altars .. " at " .. textutils.serialize(catalystPos) .. " (reported by turtle #" .. reportedBy .. ")")
    saveDatabase()
    
    broadcast("altar_registered", {
        altarId = #altars,
        totalAltars = #altars
    })
end

-- Handle turtle registration
local function registerTurtle(computerId, position, isGloveTurtle)
    local turtleId = nextTurtleId
    nextTurtleId = nextTurtleId + 1
    
    if isGloveTurtle then
        gloveTurtle = {
            id = turtleId,
            computerId = computerId,
            position = position,
            status = "idle",
            statusDetail = "waiting",
            tasks = {}
        }
        print("Registered glove turtle: #" .. turtleId .. " (Computer " .. computerId .. ")")
    else
        table.insert(turtles, {
            id = turtleId,
            computerId = computerId,
            position = position,
            status = "idle",
            statusDetail = "waiting",
            tasks = {}
        })
        print("Registered turtle #" .. turtleId .. " (Computer " .. computerId .. ")")
    end
    
    -- Send assigned ID back to turtle
    modem.transmit(computerId, CHANNEL, {
        type = "turtle_id_assigned",
        data = {
            computerId = computerId,
            assignedId = turtleId,
            chestPosition = chestPosition,
            meInterfacePosition = meInterfacePosition
        }
    })
    
    broadcast("turtle_registered", {
        turtleId = turtleId,
        totalTurtles = #turtles
    })
    
    -- If we have turtles and potential altar blocks, start setup cycle
    if #turtles > 0 and #potentialAltarBlocks > 0 and not setupComplete then
        startSetupCycle()
    end
end


-- Check if recipe already exists
local function recipeExists(catalyst, ingredients)
    for _, recipe in ipairs(recipes) do
        local match = true

        -- Check catalyst match
        if not itemsMatch(catalyst.item, recipe.catalyst.item, true, true) then
            match = false
        end

        if match and (catalyst.matchNBT ~= recipe.catalyst.matchNBT or 
                      catalyst.matchDMG ~= recipe.catalyst.matchDMG) then
            match = false
        end

        -- Check ingredient count
        if match and #ingredients ~= #recipe.ingredients then
            match = false
        end

        -- Check all ingredients match (order doesn't matter)
        if match then
            for _, ing1 in ipairs(ingredients) do
                local found = false
                for _, ing2 in ipairs(recipe.ingredients) do
                    if itemsMatch(ing1.item, ing2.item, true, true) and
                       ing1.matchNBT == ing2.matchNBT and
                       ing1.matchDMG == ing2.matchDMG then
                        found = true
                        break
                    end
                end
                if not found then
                    match = false
                    break
                end
            end
        end

        if match then
            return true
        end
    end

    return false
end



-- Add recipe
local function addRecipe(catalyst, ingredients, senderId)
    -- Check for duplicate
    if recipeExists(catalyst, ingredients) then
        modem.transmit(CHANNEL, CHANNEL, {
            type = "add_recipe_nack",
            data = {
                reason = "Duplicate recipe"
            }
        })
        return
    end
    
    local recipe = {
        catalyst = catalyst,
        ingredients = ingredients,
        output = nil,
        completedCount = 0,
        averageTime = 0,
        totalTime = 0
    }
    
    table.insert(recipes, recipe)
    saveDatabase()
    
    modem.transmit(CHANNEL, CHANNEL, {
        type = "add_recipe_ack",
        data = {
            recipeId = #recipes,
            recipe = recipe
        }
    })
    
    broadcast("recipe_added", {
        recipeId = #recipes,
        recipe = recipe
    })
    
    print("Added recipe #" .. #recipes)
end

-- Check if chest contents match a recipe
local function findMatchingRecipe()
    if not inputChest then return nil end
    
    local items = inputChest.list()
    if not items then return nil end
    
    local chestItems = {}
    for slot, item in pairs(items) do
        table.insert(chestItems, {
            slot = slot,
            name = item.name,
            count = item.count,
            damage = item.damage or 0,
            nbt = ""
        })
    end
    
    -- Try to match each recipe
    for recipeId, recipe in ipairs(recipes) do
        local catalystFound = false
        local ingredientsFound = {}
        local matched = true
        
        -- Check catalyst
        for _, chestItem in ipairs(chestItems) do
            if itemsMatch(chestItem, recipe.catalyst.item, recipe.catalyst.matchNBT, recipe.catalyst.matchDMG) then
                catalystFound = true
                break
            end
        end
        
        if catalystFound then
            -- Check ingredients
            for _, ingredient in ipairs(recipe.ingredients) do
                local found = false
                for _, chestItem in ipairs(chestItems) do
                    local alreadyUsed = false
                    for _, usedItem in ipairs(ingredientsFound) do
                        if usedItem.slot == chestItem.slot then
                            alreadyUsed = true
                            break
                        end
                    end
                    
                    if not alreadyUsed and itemsMatch(chestItem, ingredient.item, ingredient.matchNBT, ingredient.matchDMG) then
                        table.insert(ingredientsFound, chestItem)
                        found = true
                        break
                    end
                end
                
                if not found then
                    matched = false
                    break
                end
            end
            
            if matched then
                return recipeId, recipe
            end
        end
    end
    
    return nil
end

-- Update turtle status
local function updateTurtleStatus(turtleId, status, statusDetail)
    for _, turtle in ipairs(turtles) do
        if turtle.id == turtleId then
            turtle.status = status
            turtle.statusDetail = statusDetail
            break
        end
    end
    
    if gloveTurtle and gloveTurtle.id == turtleId then
        gloveTurtle.status = status
        gloveTurtle.statusDetail = statusDetail
    end
end

-- Assign tasks to turtles for infusion
local function startInfusion(recipeId, recipe, altarIdx)
    print("Starting infusion for recipe #" .. recipeId .. " on altar #" .. altarIdx)
    
    local altar = altars[altarIdx]
    altar.busy = true
    altar.currentRecipe = recipeId
    
    local infusion = {
        recipeId = recipeId,
        altarIdx = altarIdx,
        startTime = os.epoch("utc"),
        status = "placing_items"
    }
    
    activeInfusions[altarIdx] = infusion
    
    -- Assign catalyst to first turtle
    if turtles[1] then
        table.insert(turtles[1].tasks, {
            type = "place_catalyst",
            item = recipe.catalyst,
            position = altar.catalyst,
            chestPosition = chestPosition
        })
        updateTurtleStatus(turtles[1].id, "working", "placing catalyst")
    end
    
    -- Assign ingredients round-robin
    local turtleIdx = 2
    for i, ingredient in ipairs(recipe.ingredients) do
        if i > #altar.pedestals then
            print("WARNING: More ingredients than pedestals!")
            break
        end
        
        local turtle = turtles[turtleIdx] or turtles[1]
        if turtle then
            table.insert(turtle.tasks, {
                type = "place_ingredient",
                item = ingredient,
                position = altar.pedestals[i],
                chestPosition = chestPosition
            })
            updateTurtleStatus(turtle.id, "working", "placing ingredients")
            
            turtleIdx = turtleIdx + 1
            if turtleIdx > #turtles then
                turtleIdx = 1
            end
        end
    end
    
    -- Send tasks to turtles
    for _, turtle in ipairs(turtles) do
        if #turtle.tasks > 0 then
            modem.transmit(turtle.computerId, CHANNEL, {
                type = "turtle_tasks",
                data = {
                    turtleId = turtle.id,
                    tasks = turtle.tasks
                }
            })
        end
    end
    
    broadcast("infusion_started", {
        recipeId = recipeId,
        altarIdx = altarIdx,
        startTime = infusion.startTime
    })
end

-- Monitor infusion progress
local function monitorInfusions()
    for altarIdx, infusion in pairs(activeInfusions) do
        local elapsed = (os.epoch("utc") - infusion.startTime) / 1000
        local recipe = recipes[infusion.recipeId]
        
        -- Check if all turtles are done placing items
        local allDone = true
        for _, turtle in ipairs(turtles) do
            if turtle.status ~= "idle" then
                allDone = false
                break
            end
        end
        
        if allDone and infusion.status == "placing_items" then
            infusion.status = "infusing"
            print("All items placed, infusion in progress...")
            broadcast("infusion_status", {
                altarIdx = altarIdx,
                status = "infusing",
                elapsed = elapsed
            })
        end
        
        -- Timeout check
        if recipe.averageTime > 0 and elapsed > recipe.averageTime * 3 then
            print("DISASTER DETECTED! Infusion taking too long!")
            errorMode = true
            errorMessage = "Infusion timeout on altar #" .. altarIdx
            
            broadcast("disaster_abort", {
                altarIdx = altarIdx
            })
            
            broadcast("error_mode", {
                message = errorMessage
            })
        end
    end
end

-- Handle infusion completion
local function completeInfusion(altarIdx)
    local infusion = activeInfusions[altarIdx]
    if not infusion then return end
    
    local recipe = recipes[infusion.recipeId]
    local duration = (os.epoch("utc") - infusion.startTime) / 1000
    
    recipe.completedCount = recipe.completedCount + 1
    recipe.totalTime = recipe.totalTime + duration
    recipe.averageTime = recipe.totalTime / recipe.completedCount
    
    print("Infusion complete! Duration: " .. duration .. "s, Average: " .. recipe.averageTime .. "s")
    
    -- Assign result retrieval
    if turtles[1] then
        table.insert(turtles[1].tasks, {
            type = "retrieve_result",
            position = altars[altarIdx].catalyst,
            meInterfacePosition = meInterfacePosition
        })
        updateTurtleStatus(turtles[1].id, "working", "retrieving result")
        
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_tasks",
            data = {
                turtleId = turtles[1].id,
                tasks = turtles[1].tasks
            }
        })
    end
    
    altars[altarIdx].busy = false
    altars[altarIdx].currentRecipe = nil
    activeInfusions[altarIdx] = nil
    
    saveDatabase()
    
    broadcast("infusion_complete", {
        recipeId = infusion.recipeId,
        duration = duration,
        completedCount = recipe.completedCount,
        averageTime = recipe.averageTime
    })
end

-- Handle messages from network
local function handleMessage(msg, sender)
    if type(msg) ~= "table" or not msg.type then return end
    
    if msg.type == "turtle_register" then
        registerTurtle(sender, msg.data.position, msg.data.isGloveTurtle or false)
    
    elseif msg.type == "setup_verification_complete" then
        -- Turtle finished checking its assigned blocks
        local foundAltars = msg.data.foundAltars or 0
        print("Turtle #" .. msg.data.turtleId .. " setup complete, found " .. foundAltars .. " altars")
        
        -- Check if all turtles finished setup
        local allDone = true
        for _, turtle in ipairs(turtles) do
            if turtle.status ~= "idle" then
                allDone = false
                break
            end
        end
        
        if allDone and not setupComplete then
            completeSetupCycle()
        end
    
    elseif msg.type == "altar_found" then
        registerAltar(msg.data.catalystPos, msg.data.pedestalPositions, msg.data.turtleId)
    
    elseif msg.type == "add_recipe" then
        addRecipe(msg.data.catalyst, msg.data.ingredients, sender)
    
    elseif msg.type == "turtle_task_complete" then
        for _, turtle in ipairs(turtles) do
            if turtle.id == msg.data.turtleId then
                if #turtle.tasks > 0 then
                    table.remove(turtle.tasks, 1)
                end
                if #turtle.tasks == 0 then
                    updateTurtleStatus(turtle.id, "idle", "waiting")
                end
                break
            end
        end
    
    elseif msg.type == "turtle_status_update" then
        updateTurtleStatus(msg.data.turtleId, msg.data.status, msg.data.statusDetail)
    
    elseif msg.type == "infusion_detected" then
        completeInfusion(msg.data.altarIdx)
    
    elseif msg.type == "request_status" then
        broadcast("status_update", {
            recipes = recipes,
            turtles = turtles,
            altars = altars,
            activeInfusions = activeInfusions,
            errorMode = errorMode,
            errorMessage = errorMessage,
            setupComplete = setupComplete
        })
    
    elseif msg.type == "clear_error" then
        errorMode = false
        errorMessage = ""
        broadcast("error_cleared", {})
    
    elseif msg.type == "request_chest_contents" then
        if inputChest then
            local items = inputChest.list()
            local itemList = {}
            
            for slot, item in pairs(items) do
                table.insert(itemList, {
                    slot = slot,
                    name = item.name,
                    displayName = item.name,
                    count = item.count,
                    damage = item.damage or 0,
                    nbt = ""
                })
            end
            
            broadcast("chest_contents", {
                items = itemList
            })
        end
    
    elseif msg.type == "ack" or msg.type == "nack" then
        handleAck(msg.data.msgId, msg.type == "ack", msg.data.reason)
    end
end

-- Main loop
local function main()
    print("=================================")
    print("Thaumcraft Infusion Server v2.0")
    print("=================================")
    
    -- Get server position
    serverPosition = getServerPosition()
    if not serverPosition then
        print("WARNING: Running without GPS")
    else
        print("Server position: " .. textutils.serialize(serverPosition))
    end
    
    -- Scan for peripherals (EXPENSIVE - only runs once at startup!)
    print("")
    print("NOTE: Block scan is expensive (1700 energy)")
    print("Scan only runs once at startup")
    print("To rescan (e.g., after adding altars), restart the server")
    print("")
    
    if serverPosition and scanForPeripherals() then
        print("Peripheral setup complete!")
    else
        print("WARNING: Could not complete peripheral scan")
    end
    
    -- Load database
    loadDatabase()
    print("Loaded " .. #recipes .. " recipes and " .. #altars .. " altars from database")
    
    if not inputChest then
        print("ERROR: No input chest found on RIGHT side")
        errorMode = true
        errorMessage = "Input chest not found on RIGHT side of server"
    end
    
    print("\nServer ready! Listening on channel " .. CHANNEL)
    print("Waiting for turtles to register...")
    
    -- Main event loop
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message, replyChannel)
        elseif event == "timer" then
            -- Retry pending messages
            retryPendingMessages()
            
            -- Check for recipe matches (only after setup is complete)
            if setupComplete and not errorMode and #turtles >= 1 and #altars > 0 then
                local recipeId, recipe = findMatchingRecipe()
                if recipeId then
                    for altarIdx, altar in ipairs(altars) do
                        if not altar.busy then
                            startInfusion(recipeId, recipe, altarIdx)
                            break
                        end
                    end
                end
            end
            
            -- Monitor active infusions
            monitorInfusions()
        end
        
        if event == "timer" or event == "modem_message" then
            os.startTimer(1)
        end
    end
end

os.startTimer(1)
main()
