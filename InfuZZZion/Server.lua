-- Thaumcraft Infusion Automation Server v3.0
-- Manages recipes, turtle coordination, and infusion tracking
-- Uses catalyst pedestal computers instead of scanning

local CHANNEL = 1742
local DATABASE_FILE = "itemdb.dat"

-- State
local recipes = {}
local activeInfusions = {}
local turtles = {}
local altars = {} -- Now registered by catalyst pedestal computers
local inputChest = nil
local chestPosition = nil
local meInterfacePosition = nil
local serverPosition = nil
local errorMode = false
local errorMessage = ""
local nextTurtleId = 1
local nextAltarId = 1
local setupComplete = false
local altarLastSeen = {} -- Track last keepalive from altars
local turtleLastSeen = {} -- Track last keepalive from turtles
local KEEPALIVE_TIMEOUT = 30000 -- 30 seconds in milliseconds

-- Modem setup
local modem = peripheral.find("modem")
if not modem then
    error("No modem found! Please attach an ender modem on top.")
end
modem.open(CHANNEL)

-- Wrap peripherals
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
            -- Restore nextAltarId
            nextAltarId = #altars + 1
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

-- Send message to all clients
local function broadcast(msgType, data)
    modem.transmit(CHANNEL, CHANNEL, {
        type = msgType,
        data = data,
        timestamp = os.epoch("utc")
    })
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
end

-- Check for offline components
local function checkKeepalives()
    local now = os.epoch("utc")
    local errors = {}
    
    -- Check altars
    for _, altar in ipairs(altars) do
        if altarLastSeen[altar.id] then
            if now - altarLastSeen[altar.id] > KEEPALIVE_TIMEOUT then
                table.insert(errors, "Altar #" .. altar.id .. " offline!")
                print("WARNING: Altar #" .. altar.id .. " not responding")
            end
        end
    end
    
    -- Check turtles
    for _, turtle in ipairs(turtles) do
        if turtleLastSeen[turtle.id] then
            if now - turtleLastSeen[turtle.id] > KEEPALIVE_TIMEOUT then
                table.insert(errors, "Turtle #" .. turtle.id .. " offline!")
                print("WARNING: Turtle #" .. turtle.id .. " not responding")
            end
        end
    end
    
    -- Update error mode if components are offline
    if #errors > 0 then
        errorMode = true
        errorMessage = table.concat(errors, ", ")
        broadcast("error_mode", {message = errorMessage})
    end
end

-- Request turtle to scan pedestals around altar
local function requestPedestalScan(altarId)
    local altar = nil
    for _, a in ipairs(altars) do
        if a.id == altarId then
            altar = a
            break
        end
    end
    
    if not altar then return end
    
    -- Assign to first available turtle
    if #turtles > 0 then
        print("Requesting pedestal scan for altar #" .. altarId)
        
        modem.transmit(turtles[1].computerId, CHANNEL, {
            type = "scan_pedestals",
            data = {
                altarId = altarId,
                catalystPosition = altar.catalyst
            }
        })
        
        updateTurtleStatus(turtles[1].id, "scanning", "scanning pedestals")
    end
end

-- Register altar from catalyst pedestal computer
local function registerAltar(catalystPos, isReregister, existingId)
    local altarId = existingId or nextAltarId
    
    -- Check if altar already exists at this position
    local found = false
    for _, altar in ipairs(altars) do
        if altar.catalyst.x == catalystPos.x and 
           altar.catalyst.y == catalystPos.y and 
           altar.catalyst.z == catalystPos.z then
            -- Update existing altar
            altar.id = altarId
            found = true
            print("Re-registered altar #" .. altarId .. " at " .. textutils.serialize(catalystPos))
            
            -- Track keepalive
            altarLastSeen[altarId] = os.epoch("utc")
            
            -- Send ID assignment
            modem.transmit(CHANNEL, CHANNEL, {
                type = "altar_id_assigned",
                data = {
                    catalystPosition = catalystPos,
                    altarId = altarId
                }
            })
            return
        end
    end
    
    -- New altar registration
    if not found then
        if not isReregister then
            nextAltarId = nextAltarId + 1
        end
        
        local altar = {
            id = altarId,
            catalyst = catalystPos,
            pedestals = {}, -- Will be filled by turtle during setup
            busy = false,
            currentRecipe = nil,
            pedestalsScanned = false
        }
        
        table.insert(altars, altar)
        
        -- Sort by distance from server (closer = higher priority)
        if serverPosition then
            table.sort(altars, function(a, b)
                local distA = math.abs(a.catalyst.x - serverPosition.x) + 
                             math.abs(a.catalyst.y - serverPosition.y) + 
                             math.abs(a.catalyst.z - serverPosition.z)
                local distB = math.abs(b.catalyst.x - serverPosition.x) + 
                             math.abs(b.catalyst.y - serverPosition.y) + 
                             math.abs(b.catalyst.z - serverPosition.z)
                return distA < distB
            end)
        end
        
        print("Registered NEW altar #" .. altarId .. " at " .. textutils.serialize(catalystPos))
        saveDatabase()
        
        -- Track keepalive
        altarLastSeen[altarId] = os.epoch("utc")
        
        -- Send ID assignment
        modem.transmit(CHANNEL, CHANNEL, {
            type = "altar_id_assigned",
            data = {
                catalystPosition = catalystPos,
                altarId = altarId
            }
        })
        
        broadcast("altar_registered", {
            altarId = altarId,
            totalAltars = #altars
        })
        
        -- Request turtle to scan pedestals if we have turtles
        if #turtles > 0 and not altar.pedestalsScanned then
            requestPedestalScan(altarId)
        end
    end
end

-- Handle turtle registration
local function registerTurtle(computerId, position, isReregister, existingId)
    local turtleId = existingId or nextTurtleId
    
    if not isReregister then
        nextTurtleId = nextTurtleId + 1
    end
    
    -- Check if turtle already exists (re-registration)
    local found = false
    for _, turtle in ipairs(turtles) do
        if turtle.id == turtleId then
            -- Update existing turtle
            turtle.computerId = computerId
            turtle.position = position
            turtle.status = "idle"
            turtle.statusDetail = "waiting"
            found = true
            print("Re-registered turtle #" .. turtleId .. " (Computer " .. computerId .. ")")
            break
        end
    end
    
    -- Add new turtle if not found
    if not found then
        table.insert(turtles, {
            id = turtleId,
            computerId = computerId,
            position = position,
            status = "idle",
            statusDetail = "waiting",
            tasks = {}
        })
        print("Registered NEW turtle #" .. turtleId .. " (Computer " .. computerId .. ")")
    end
    
    -- Track keepalive
    turtleLastSeen[turtleId] = os.epoch("utc")
    
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
    
    -- If we have altars that need pedestal scanning, start
    for _, altar in ipairs(altars) do
        if not altar.pedestalsScanned then
            requestPedestalScan(altar.id)
            break
        end
    end
end

-- Handle pedestal scan results
local function handlePedestalScanResults(altarId, pedestalPositions)
    for _, altar in ipairs(altars) do
        if altar.id == altarId then
            altar.pedestals = pedestalPositions
            altar.pedestalsScanned = true
            print("Altar #" .. altarId .. " pedestals scanned: " .. #pedestalPositions .. " pedestals")
            saveDatabase()
            
            -- Check if all altars are scanned
            local allScanned = true
            for _, a in ipairs(altars) do
                if not a.pedestalsScanned then
                    allScanned = false
                    break
                end
            end
            
            if allScanned and #altars > 0 then
                completeSetup()
            end
            
            break
        end
    end
end

-- Complete setup
local function completeSetup()
    if setupComplete then return end
    
    setupComplete = true
    print("")
    print("=================================")
    print("Setup Complete!")
    print("=================================")
    print("Altars ready: " .. #altars)
    print("System ready for infusion!")
    print("")
    
    broadcast("setup_complete", {
        altarCount = #altars
    })
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
local function addRecipe(catalyst, ingredients)
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

-- Assign tasks to turtles for infusion
local function startInfusion(recipeId, recipe, altarIdx)
    print("Starting infusion for recipe #" .. recipeId .. " on altar #" .. altarIdx)
    
    local altar = altars[altarIdx]
    
    -- Check if altar has pedestals scanned
    if not altar.pedestalsScanned or #altar.pedestals == 0 then
        print("ERROR: Altar #" .. altarIdx .. " pedestals not scanned yet!")
        return
    end
    
    altar.busy = true
    altar.currentRecipe = recipeId
    
    local infusion = {
        recipeId = recipeId,
        altarId = altar.id,
        startTime = os.epoch("utc"),
        status = "placing_items"
    }
    
    activeInfusions[altar.id] = infusion
    
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
    
    -- Notify altar computer
    broadcast("infusion_started", {
        recipeId = recipeId,
        altarId = altar.id,
        startTime = infusion.startTime
    })
end

-- Handle infusion completion
local function completeInfusion(altarId, resultItem)
    local infusion = activeInfusions[altarId]
    if not infusion then return end
    
    local recipe = recipes[infusion.recipeId]
    local duration = (os.epoch("utc") - infusion.startTime) / 1000
    
    recipe.completedCount = recipe.completedCount + 1
    recipe.totalTime = recipe.totalTime + duration
    recipe.averageTime = recipe.totalTime / recipe.completedCount
    
    print("Infusion complete! Duration: " .. duration .. "s, Average: " .. recipe.averageTime .. "s")
    print("Result: " .. resultItem.displayName)
    
    -- Find altar
    local altar = nil
    for _, a in ipairs(altars) do
        if a.id == altarId then
            altar = a
            break
        end
    end
    
    if not altar then return end
    
    -- Assign result retrieval and pedestal clearing
    if turtles[1] then
        -- Retrieve catalyst (which is now the result)
        table.insert(turtles[1].tasks, {
            type = "retrieve_result",
            position = altar.catalyst,
            meInterfacePosition = meInterfacePosition
        })
        
        -- Clear all pedestals
        for _, pedestalPos in ipairs(altar.pedestals) do
            table.insert(turtles[1].tasks, {
                type = "clear_pedestal",
                position = pedestalPos,
                meInterfacePosition = meInterfacePosition
            })
        end
        
        updateTurtleStatus(turtles[1].id, "working", "clearing altar")
        
        modem.transmit(turtles[1].computerId, CHANNEL, {
            type = "turtle_tasks",
            data = {
                turtleId = turtles[1].id,
                tasks = turtles[1].tasks
            }
        })
    end
    
    altar.busy = false
    altar.currentRecipe = nil
    activeInfusions[altarId] = nil
    
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
        local computerId = msg.data.computerId or sender
        registerTurtle(computerId, msg.data.position, false, nil)
    
    elseif msg.type == "turtle_reregister" then
        local computerId = msg.data.computerId or sender
        registerTurtle(computerId, msg.data.position, true, msg.data.turtleId)
    
    elseif msg.type == "altar_register" then
        registerAltar(msg.data.catalystPosition, false, nil)
    
    elseif msg.type == "altar_reregister" then
        registerAltar(msg.data.catalystPosition, true, msg.data.altarId)
    
    elseif msg.type == "pedestals_scanned" then
        handlePedestalScanResults(msg.data.altarId, msg.data.pedestalPositions)
    
    elseif msg.type == "add_recipe" then
        addRecipe(msg.data.catalyst, msg.data.ingredients)
    
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
    
    elseif msg.type == "infusion_complete" then
        completeInfusion(msg.data.altarId, msg.data.resultItem)
    
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
    
    elseif msg.type == "altar_keepalive" then
        if msg.data.altarId then
            altarLastSeen[msg.data.altarId] = os.epoch("utc")
        end
    
    elseif msg.type == "turtle_keepalive" then
        if msg.data.turtleId then
            turtleLastSeen[msg.data.turtleId] = os.epoch("utc")
        end
    end
end

-- Main loop
local function main()
    print("=================================")
    print("Thaumcraft Infusion Server v3.0")
    print("=================================")
    
    -- Get server position
    serverPosition = getServerPosition()
    if not serverPosition then
        print("WARNING: Running without GPS")
    else
        print("Server position: " .. textutils.serialize(serverPosition))
    end
    
    -- Set peripheral positions based on server position
    if serverPosition then
        chestPosition = {
            x = serverPosition.x + 1,
            y = serverPosition.y,
            z = serverPosition.z
        }
        -- ME Interface should be connected to chest (adjust as needed)
        meInterfacePosition = chestPosition
        print("Chest position: " .. textutils.serialize(chestPosition))
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
    print("Waiting for catalyst pedestal computers and turtles to register...")
    
    -- Main event loop
    local checkTimer = os.startTimer(2)
    local keepaliveTimer = os.startTimer(10)
    
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message, replyChannel)
            
        elseif event == "timer" then
            if side == checkTimer then
                -- Check for recipe matches (only after setup is complete)
                if setupComplete and not errorMode and #turtles >= 1 and #altars > 0 then
                    local recipeId, recipe = findMatchingRecipe()
                    if recipeId then
                        -- Find available altar
                        for altarIdx, altar in ipairs(altars) do
                            if not altar.busy and altar.pedestalsScanned then
                                startInfusion(recipeId, recipe, altarIdx)
                                break
                            end
                        end
                    end
                end
                
                checkTimer = os.startTimer(2)
                
            elseif side == keepaliveTimer then
                -- Check keepalives
                checkKeepalives()
                keepaliveTimer = os.startTimer(10)
            end
        end
    end
end

main()
