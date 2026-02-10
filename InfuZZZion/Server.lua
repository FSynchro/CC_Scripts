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
local currentRecipe = nil
local errorMode = false
local errorMessage = ""

-- Modem setup
local modem = peripheral.find("modem")
if not modem then
    error("No modem found! Please attach an ender modem on top.")
end
modem.open(CHANNEL)

-- Wrap peripherals
local function findPeripherals()
    local errors = {}
    
    -- Find input chest (to the right)
    inputChest = peripheral.wrap("right")
    if not inputChest or not inputChest.list then
        table.insert(errors, "Input chest not found on RIGHT side")
    end
    
    -- ME Interface is on the opposite side of the chest
    -- We don't need to wrap it - turtles will interact with it directly
    -- Just verify the setup info is correct
    print("Setup: [Computer] <- [Chest] -> [ME Interface]")
    print("Chest should be on RIGHT of computer")
    print("ME Interface should be on opposite side of chest")
    
    return errors
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

-- Send message to all clients
local function broadcast(msgType, data)
    modem.transmit(CHANNEL, CHANNEL, {
        type = msgType,
        data = data,
        timestamp = os.epoch("utc")
    })
end

-- Handle turtle registration
local function registerTurtle(turtleId, position, isGloveTurtle)
    if isGloveTurtle then
        gloveTurtle = {
            id = "Glove" .. turtleId,
            position = position,
            status = "idle",
            tasks = {}
        }
        print("Registered glove turtle: " .. gloveTurtle.id)
    else
        table.insert(turtles, {
            id = #turtles + 1,
            computerId = turtleId,
            position = position,
            status = "idle",
            tasks = {}
        })
        print("Registered turtle #" .. #turtles .. " (ID: " .. turtleId .. ")")
    end
    
    broadcast("turtle_registered", {
        turtleId = isGloveTurtle and gloveTurtle.id or #turtles,
        totalTurtles = #turtles
    })
end

-- Discover altars by finding catalyst pedestals
local function discoverAltars()
    print("Requesting altar discovery from turtles...")
    broadcast("discover_altars", {})
end

-- Handle altar discovery response
local function registerAltar(catalystPos, pedestalPositions)
    local altar = {
        catalyst = catalystPos,
        pedestals = pedestalPositions,
        busy = false,
        currentRecipe = nil
    }
    
    table.insert(altars, altar)
    
    -- Sort by distance from server (closer = higher priority)
    table.sort(altars, function(a, b)
        local distA = math.abs(a.catalyst.x) + math.abs(a.catalyst.y) + math.abs(a.catalyst.z)
        local distB = math.abs(b.catalyst.x) + math.abs(b.catalyst.y) + math.abs(b.catalyst.z)
        return distA < distB
    end)
    
    print("Registered altar #" .. #altars .. " at " .. textutils.serialize(catalystPos))
    saveDatabase()
end

-- Add recipe
local function addRecipe(catalyst, ingredients)
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
    
    -- Convert to item list
    local chestItems = {}
    for slot, item in pairs(items) do
        local detail = inputChest.getItemDetail(slot)
        table.insert(chestItems, {
            slot = slot,
            name = detail.name,
            count = detail.count,
            damage = detail.damage or 0,
            nbt = detail.nbt or ""
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
            
            -- Found a match!
            if matched then
                return recipeId, recipe
            end
        end
    end
    
    return nil
end

-- Assign tasks to turtles for infusion
local function startInfusion(recipeId, recipe, altar)
    print("Starting infusion for recipe #" .. recipeId .. " on altar #" .. altar)
    
    altar.busy = true
    altar.currentRecipe = recipeId
    
    local infusion = {
        recipeId = recipeId,
        altar = altar,
        startTime = os.epoch("utc"),
        status = "placing_items"
    }
    
    activeInfusions[altar] = infusion
    
    -- Assign catalyst to first turtle (or any available)
    local catalystTurtle = turtles[1]
    if catalystTurtle then
        table.insert(catalystTurtle.tasks, {
            type = "place_catalyst",
            item = recipe.catalyst,
            position = altars[altar].catalyst
        })
        catalystTurtle.status = "working"
    end
    
    -- Assign ingredients to turtles 2 and 3 (round-robin)
    local ingredientTurtles = {turtles[2], turtles[3]}
    local currentTurtleIdx = 1
    
    for i, ingredient in ipairs(recipe.ingredients) do
        local turtle = ingredientTurtles[currentTurtleIdx]
        if turtle then
            local pedestalIdx = i
            table.insert(turtle.tasks, {
                type = "place_ingredient",
                item = ingredient,
                position = altars[altar].pedestals[pedestalIdx]
            })
            turtle.status = "working"
            
            currentTurtleIdx = currentTurtleIdx + 1
            if currentTurtleIdx > #ingredientTurtles then
                currentTurtleIdx = 1
            end
        end
    end
    
    -- If more ingredients than turtle 2 and 3 can handle, assign to turtle 1
    if #recipe.ingredients > 6 then -- Each turtle handles ~3 items
        for i = 7, #recipe.ingredients do
            if catalystTurtle then
                local pedestalIdx = i
                table.insert(catalystTurtle.tasks, {
                    type = "place_ingredient",
                    item = recipe.ingredients[i],
                    position = altars[altar].pedestals[pedestalIdx]
                })
            end
        end
    end
    
    -- Send tasks to turtles
    for _, turtle in ipairs(turtles) do
        if #turtle.tasks > 0 then
            broadcast("turtle_tasks", {
                turtleId = turtle.id,
                tasks = turtle.tasks
            })
        end
    end
    
    broadcast("infusion_started", {
        recipeId = recipeId,
        altar = altar,
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
                altar = altarIdx,
                status = "infusing",
                elapsed = elapsed
            })
        end
        
        -- Disaster recovery check
        if recipe.averageTime > 0 and elapsed > recipe.averageTime * 3 then
            print("DISASTER DETECTED! Infusion taking too long!")
            errorMode = true
            errorMessage = "Infusion timeout - 3x expected time exceeded"
            
            -- Tell turtles to abort and retrieve items
            broadcast("disaster_abort", {
                altar = altarIdx
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
    
    -- Update recipe statistics
    recipe.completedCount = recipe.completedCount + 1
    recipe.totalTime = recipe.totalTime + duration
    recipe.averageTime = recipe.totalTime / recipe.completedCount
    
    print("Infusion complete! Duration: " .. duration .. "s")
    print("Average time: " .. recipe.averageTime .. "s")
    
    -- Tell turtle to retrieve result
    local catalystTurtle = turtles[1]
    if catalystTurtle then
        table.insert(catalystTurtle.tasks, {
            type = "retrieve_result",
            position = altars[altarIdx].catalyst
        })
        catalystTurtle.status = "working"
        
        broadcast("turtle_tasks", {
            turtleId = catalystTurtle.id,
            tasks = catalystTurtle.tasks
        })
    end
    
    -- Mark altar as free
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
        
    elseif msg.type == "altar_found" then
        registerAltar(msg.data.catalystPos, msg.data.pedestalPositions)
        
    elseif msg.type == "add_recipe" then
        addRecipe(msg.data.catalyst, msg.data.ingredients)
        
    elseif msg.type == "turtle_task_complete" then
        -- Mark task as complete
        for _, turtle in ipairs(turtles) do
            if turtle.id == msg.data.turtleId then
                table.remove(turtle.tasks, 1)
                if #turtle.tasks == 0 then
                    turtle.status = "idle"
                end
                break
            end
        end
        
    elseif msg.type == "turtle_returned" then
        -- Turtle returned to home position
        
    elseif msg.type == "infusion_detected" then
        -- Catalyst pedestal item changed
        completeInfusion(msg.data.altarIdx)
        
    elseif msg.type == "request_status" then
        -- Client requesting status update
        broadcast("status_update", {
            recipes = recipes,
            turtles = turtles,
            altars = altars,
            activeInfusions = activeInfusions,
            errorMode = errorMode,
            errorMessage = errorMessage
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
                local detail = inputChest.getItemDetail(slot)
                table.insert(itemList, {
                    slot = slot,
                    name = detail.name,
                    displayName = detail.displayName,
                    count = detail.count,
                    damage = detail.damage or 0,
                    nbt = detail.nbt or ""
                })
            end
            
            broadcast("chest_contents", {
                items = itemList
            })
        end
    end
end

-- Main loop
local function main()
    print("Thaumcraft Infusion Server Starting...")
    
    -- Load database
    loadDatabase()
    print("Loaded " .. #recipes .. " recipes from database")
    
    -- Find peripherals
    local errors = findPeripherals()
    if #errors > 0 then
        for _, err in ipairs(errors) do
            print("ERROR: " .. err)
        end
        errorMode = true
        errorMessage = table.concat(errors, "; ")
    end
    
    print("Server ready! Listening on channel " .. CHANNEL)
    
    -- Main event loop
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message, replyChannel)
        elseif event == "timer" then
            -- Check for recipe matches
            if not errorMode and #turtles >= 1 then
                local recipeId, recipe = findMatchingRecipe()
                if recipeId then
                    -- Find available altar
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
        
        -- Set timer for next check
        if event == "timer" or event == "modem_message" then
            os.startTimer(1)
        end
    end
end

-- Start initial timer
os.startTimer(1)

-- Run main loop
main()
