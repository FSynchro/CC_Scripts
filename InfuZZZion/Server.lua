-- Thaumcraft Infusion Automation Server v3.2
-- UPDATED: Single turtle scanning, layout confirmation required before infusions

local CHANNEL = 1742
local DATABASE_FILE = "itemdb.dat"

-- State
local recipes = {}
local activeInfusions = {}
local turtles = {}
local altars = {}
local inputChest = nil
local chestPosition = nil
local meInterfacePosition = nil
local serverPosition = nil
local errorMode = false
local errorMessage = ""
local nextTurtleId = 1
local nextAltarId = 1
local setupComplete = false
local altarLastSeen = {}
local turtleLastSeen = {}
local KEEPALIVE_TIMEOUT = 30000

-- Modem setup
local modem = peripheral.find("modem")
if not modem then
    error("No modem found!")
end
modem.open(CHANNEL)

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
            nextAltarId = #altars + 1
        end
    end
end

-- Compare items
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

-- Broadcast
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

-- Check keepalives
local function checkKeepalives()
    local now = os.epoch("utc")
    local errors = {}
    
    for _, altar in ipairs(altars) do
        if altarLastSeen[altar.id] then
            if now - altarLastSeen[altar.id] > KEEPALIVE_TIMEOUT then
                table.insert(errors, "Altar #" .. altar.id .. " offline!")
                print("WARNING: Altar #" .. altar.id .. " not responding")
            end
        end
    end
    
    for _, turtle in ipairs(turtles) do
        if turtleLastSeen[turtle.id] then
            if now - turtleLastSeen[turtle.id] > KEEPALIVE_TIMEOUT then
                table.insert(errors, "Turtle #" .. turtle.id .. " offline!")
                print("WARNING: Turtle #" .. turtle.id .. " not responding")
            end
        end
    end
    
    if #errors > 0 then
        errorMode = true
        errorMessage = table.concat(errors, ", ")
        broadcast("error_mode", {message = errorMessage})
    end
end

-- UPDATED: Use ONLY the first turtle for scanning
local function requestPedestalScan(altarId)
    local altar = nil
    for _, a in ipairs(altars) do
        if a.id == altarId then
            altar = a
            break
        end
    end
    
    if not altar then return end
    
    if #turtles == 0 then 
        print("WARNING: No turtles available for pedestal scan")
        return 
    end
    
    -- CHANGED: Only use the FIRST turtle
    local turtle = turtles[1]
    
    print("=================================")
    print("Requesting pedestal scan for altar #" .. altarId)
    print("Using turtle #" .. turtle.id .. " (single turtle mode)")
    print("=================================")
    
    -- Assign ALL rows to the one turtle (full 7x7 scan)
    local allRows = {-3, -2, -1, 0, 1, 2, 3}
    
    print("Turtle #" .. turtle.id .. " will scan all rows: " .. textutils.serialize(allRows))
    
    modem.transmit(CHANNEL, CHANNEL, {
        type = "scan_pedestals",
        data = {
            turtleId = turtle.id,
            altarId = altarId,
            catalystPosition = altar.catalyst,
            assignedRows = allRows  -- All 7 rows
        }
    })
    
    updateTurtleStatus(turtle.id, "scanning", "scanning all pedestals")
end

-- Register altar
local function registerAltar(catalystPos, isReregister, existingId)
    local altarId = existingId or nextAltarId
    
    local found = false
    local existingAltar = nil
    for _, altar in ipairs(altars) do
        if altar.catalyst.x == catalystPos.x and 
           altar.catalyst.y == catalystPos.y and 
           altar.catalyst.z == catalystPos.z then
            altar.id = altarId
            found = true
            existingAltar = altar
            print("Re-registered altar #" .. altarId)
            
            altarLastSeen[altarId] = os.epoch("utc")
            
            modem.transmit(CHANNEL, CHANNEL, {
                type = "altar_id_assigned",
                data = {
                    catalystPosition = catalystPos,
                    altarId = altarId
                }
            })
            break
        end
    end
    
    if found and existingAltar then
        if not existingAltar.layoutConfirmed and #turtles > 0 then
            print("Altar #" .. altarId .. " needs confirmation, triggering scan...")
            requestPedestalScan(altarId)
        end
        return
    end
    
    if not found then
        if not isReregister then
            nextAltarId = nextAltarId + 1
        end
        
        local altar = {
            id = altarId,
            catalyst = catalystPos,
            pedestals = {},
            stabilizers = {},
            busy = false,
            currentRecipe = nil,
            pedestalsScanned = false,
            layoutConfirmed = false  -- NEW: Must be confirmed before infusions
        }
        
        table.insert(altars, altar)
        
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
        
        print("Registered NEW altar #" .. altarId)
        saveDatabase()
        
        altarLastSeen[altarId] = os.epoch("utc")
        
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
        
        if #turtles > 0 then
            print("New altar registered, triggering scan...")
            requestPedestalScan(altarId)
        else
            print("Waiting for turtles...")
        end
    end
end

-- Register turtle
local function registerTurtle(computerId, position, isReregister, existingId)
    local turtleId = existingId or nextTurtleId
    
    local found = false
    for _, turtle in ipairs(turtles) do
        if turtle.id == turtleId or (not isReregister and turtle.computerId == computerId) then
            turtle.computerId = computerId
            turtle.position = position
            turtle.status = "idle"
            turtle.statusDetail = "waiting"
            turtleId = turtle.id
            found = true
            print("Re-registered turtle #" .. turtleId)
            break
        end
    end
    
    if not found then
        if not isReregister then
            nextTurtleId = nextTurtleId + 1
        end
        
        table.insert(turtles, {
            id = turtleId,
            computerId = computerId,
            position = position,
            status = "idle",
            statusDetail = "waiting",
            tasks = {}
        })
        print("Registered NEW turtle #" .. turtleId)
    end
    
    turtleLastSeen[turtleId] = os.epoch("utc")
    
    modem.transmit(CHANNEL, CHANNEL, {
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
    
    -- Trigger scans for unconfirmed altars
    print("Checking for altars needing confirmation...")
    for _, altar in ipairs(altars) do
        if not altar.layoutConfirmed then
            print("Found altar #" .. altar.id .. " needing confirmation, triggering scan...")
            requestPedestalScan(altar.id)
            break  -- Only one at a time
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
    print("=================================")
    
    broadcast("setup_complete", {
        altarCount = #altars
    })
end

-- Handle scan results
local function handlePedestalScanResults(altarId, pedestalPositions, stabilizerPositions, turtleId)
    for _, altar in ipairs(altars) do
        if altar.id == altarId then
            if not altar.pedestals then
                altar.pedestals = {}
            end
            if not altar.stabilizers then
                altar.stabilizers = {}
            end
            
            -- Replace (not merge) with new scan results
            altar.pedestals = pedestalPositions or {}
            altar.stabilizers = stabilizerPositions or {}
            
            print("Altar #" .. altarId .. " scan results:")
            print("  Pedestals: " .. #altar.pedestals)
            print("  Stabilizers: " .. #altar.stabilizers)
            
            -- Sort pedestals by distance
            table.sort(altar.pedestals, function(a, b)
                local distA = math.abs(a.x - altar.catalyst.x) + math.abs(a.z - altar.catalyst.z)
                local distB = math.abs(b.x - altar.catalyst.x) + math.abs(b.z - altar.catalyst.z)
                return distA < distB
            end)
            
            altar.pedestalsScanned = true
            -- Don't auto-confirm, wait for manual confirmation
            
            print("Altar #" .. altarId .. " scan complete (awaiting confirmation)")
            
            -- Send layout to catalyst computer for saving
            broadcast("altar_layout", {
                altarId = altarId,
                pedestals = altar.pedestals,
                stabilizers = altar.stabilizers
            })
            
            saveDatabase()
            
            -- Mark turtle as idle
            updateTurtleStatus(turtleId, "idle", "waiting")
            
            break
        end
    end
end

-- NEW: Confirm altar layout
local function confirmAltarLayout(altarId)
    for _, altar in ipairs(altars) do
        if altar.id == altarId then
            altar.layoutConfirmed = true
            print("Altar #" .. altarId .. " layout CONFIRMED!")
            
            saveDatabase()
            
            broadcast("altar_confirmed", {
                altarId = altarId
            })
            
            -- Check if all altars confirmed
            local allConfirmed = true
            for _, a in ipairs(altars) do
                if not a.layoutConfirmed then
                    allConfirmed = false
                    break
                end
            end
            
            if allConfirmed and #altars > 0 then
                completeSetup()
            end
            
            break
        end
    end
end

-- Recipe management (unchanged)
local function recipeExists(catalyst, ingredients)
    for _, recipe in ipairs(recipes) do
        local match = true
        
        if not itemsMatch(catalyst.item, recipe.catalyst.item, true, true) then
            match = false
        end
        
        if match and (catalyst.matchNBT ~= recipe.catalyst.matchNBT or 
                      catalyst.matchDMG ~= recipe.catalyst.matchDMG) then
            match = false
        end
        
        if match and #ingredients ~= #recipe.ingredients then
            match = false
        end
        
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

local function addRecipe(catalyst, ingredients)
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
    
    for recipeId, recipe in ipairs(recipes) do
        local catalystFound = false
        local ingredientsFound = {}
        local matched = true
        
        for _, chestItem in ipairs(chestItems) do
            if itemsMatch(chestItem, recipe.catalyst.item, recipe.catalyst.matchNBT, recipe.catalyst.matchDMG) then
                catalystFound = true
                break
            end
        end
        
        if catalystFound then
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

local function startInfusion(recipeId, recipe, altarIdx)
    print("Starting infusion for recipe #" .. recipeId .. " on altar #" .. altarIdx)
    
    local altar = altars[altarIdx]
    
    -- CRITICAL: Check if layout is confirmed
    if not altar.layoutConfirmed then
        print("ERROR: Altar #" .. altarIdx .. " layout not confirmed yet!")
        return
    end
    
    if not altar.pedestalsScanned or #altar.pedestals == 0 then
        print("ERROR: Altar #" .. altarIdx .. " pedestals not scanned!")
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
    
    if turtles[1] then
        table.insert(turtles[1].tasks, {
            type = "place_catalyst",
            item = recipe.catalyst,
            position = altar.catalyst,
            chestPosition = chestPosition
        })
        updateTurtleStatus(turtles[1].id, "working", "placing catalyst")
    end
    
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
        altarId = altar.id,
        startTime = infusion.startTime
    })
end

local function completeInfusion(altarId, resultItem)
    local infusion = activeInfusions[altarId]
    if not infusion then return end
    
    local recipe = recipes[infusion.recipeId]
    local duration = (os.epoch("utc") - infusion.startTime) / 1000
    
    recipe.completedCount = recipe.completedCount + 1
    recipe.totalTime = recipe.totalTime + duration
    recipe.averageTime = recipe.totalTime / recipe.completedCount
    
    print("Infusion complete! Duration: " .. duration .. "s")
    
    local altar = nil
    for _, a in ipairs(altars) do
        if a.id == altarId then
            altar = a
            break
        end
    end
    
    if not altar then return end
    
    if turtles[1] then
        table.insert(turtles[1].tasks, {
            type = "retrieve_result",
            position = altar.catalyst,
            meInterfacePosition = meInterfacePosition
        })
        
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

-- Handle messages
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
        handlePedestalScanResults(
            msg.data.altarId, 
            msg.data.pedestalPositions, 
            msg.data.stabilizerPositions or {},
            msg.data.turtleId
        )
    
    elseif msg.type == "confirm_altar_layout" then
        confirmAltarLayout(msg.data.altarId)
    
    elseif msg.type == "rescan_altar" then
        print("Manual rescan requested for altar #" .. msg.data.altarId)
        requestPedestalScan(msg.data.altarId)
    
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
    print("Thaumcraft Infusion Server v3.2")
    print("=================================")
    
    serverPosition = getServerPosition()
    if not serverPosition then
        print("WARNING: Running without GPS")
    else
        print("Server position: " .. textutils.serialize(serverPosition))
    end
    
    if serverPosition then
        chestPosition = {
            x = serverPosition.x + 1,
            y = serverPosition.y,
            z = serverPosition.z
        }
        meInterfacePosition = chestPosition
        print("Chest position: " .. textutils.serialize(chestPosition))
    end
    
    loadDatabase()
    print("Loaded " .. #recipes .. " recipes and " .. #altars .. " altars")
    
    if not inputChest then
        print("ERROR: No input chest on RIGHT side")
        errorMode = true
        errorMessage = "Input chest not found"
    end
    
    print("\nServer ready! Listening on channel " .. CHANNEL)
    print("SINGLE TURTLE MODE: Only first turtle will scan")
    
    local checkTimer = os.startTimer(2)
    local keepaliveTimer = os.startTimer(10)
    
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message, replyChannel)
            
        elseif event == "timer" then
            if side == checkTimer then
                -- CRITICAL: Only start infusions on CONFIRMED altars
                if setupComplete and not errorMode and #turtles >= 1 and #altars > 0 then
                    local recipeId, recipe = findMatchingRecipe()
                    if recipeId then
                        for altarIdx, altar in ipairs(altars) do
                            if not altar.busy and altar.layoutConfirmed then
                                startInfusion(recipeId, recipe, altarIdx)
                                break
                            end
                        end
                    end
                end
                
                checkTimer = os.startTimer(2)
                
            elseif side == keepaliveTimer then
                checkKeepalives()
                keepaliveTimer = os.startTimer(10)
            end
        end
    end
end

main()
