-- Thaumcraft Infusion Automation Server v3.3
-- UPDATED: Chest/ME position discovered by turtle scan, not hardcoded

local CHANNEL = 1742
local DATABASE_FILE = "itemdb.dat"

-- State
local recipes = {}
local activeInfusions = {}
local turtles = {}
local altars = {}
local inputChest = nil
local chestPosition = nil        -- Set once turtle reports chest_found
local meInterfacePosition = nil  -- Set once turtle reports chest_found
local serverPosition = nil
local errorMode = false
local errorMessage = ""
local nextTurtleId = 1
local nextAltarId = 1
local setupComplete = false
local altarLastSeen = {}
local turtleLastSeen = {}
local KEEPALIVE_TIMEOUT = 60000
local pendingRestartAltarId = nil
local restartTimer = nil

-- Modem setup
local modem = peripheral.find("modem")
if not modem then
    error("No modem found!")
end
modem.open(CHANNEL)

inputChest = peripheral.wrap("right")

-- ============================================================
-- GPS
-- ============================================================

local function getServerPosition()
    print("Getting server GPS position...")
    local x, y, z = gps.locate(5)
    if not x then
        print("WARNING: Could not get GPS position")
        return nil
    end
    return {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
end

-- ============================================================
-- DATABASE
-- ============================================================

local function saveDatabase()
    local file = fs.open(DATABASE_FILE, "w")
    file.write(textutils.serialize({
        recipes = recipes,
        altars = altars,
        chestPosition = chestPosition,
        meInterfacePosition = meInterfacePosition
    }))
    file.close()
end

local function loadDatabase()
    if fs.exists(DATABASE_FILE) then
        local file = fs.open(DATABASE_FILE, "r")
        local data = textutils.unserialize(file.readAll())
        file.close()

        if data then
            recipes = data.recipes or {}
            altars = data.altars or {}
            nextAltarId = #altars + 1
            -- Restore chest/ME positions if previously discovered
            if data.chestPosition then
                chestPosition = data.chestPosition
                meInterfacePosition = data.meInterfacePosition
                print("Restored chest position: " .. textutils.serialize(chestPosition))
                print("Restored ME position:    " .. textutils.serialize(meInterfacePosition))
            end
            -- Restore setupComplete: true if all altars are confirmed
            local allConfirmed = #altars > 0
            for _, a in ipairs(altars) do
                if not a.layoutConfirmed then allConfirmed = false break end
            end
            if allConfirmed then
                setupComplete = true
                print("Setup already complete (" .. #altars .. " altars confirmed)")
            end
        end
    end
end

-- ============================================================
-- UTILITIES
-- ============================================================

local function itemsMatch(item1, item2, matchNBT, matchDMG)
    if item1.name ~= item2.name then return false end
    if matchDMG and item1.damage ~= item2.damage then return false end
    if matchNBT and item1.nbt ~= item2.nbt then return false end
    return true
end

local function broadcast(msgType, data)
    modem.transmit(CHANNEL, CHANNEL, {
        type = msgType,
        data = data,
        timestamp = os.epoch("utc")
    })
end

local function updateTurtleStatus(turtleId, status, statusDetail)
    for _, t in ipairs(turtles) do
        if t.id == turtleId then
            t.status = status
            t.statusDetail = statusDetail
            break
        end
    end
end

-- ============================================================
-- KEEPALIVE CHECKS
-- ============================================================

local function checkKeepalives()
    local now = os.epoch("utc")

    for _, altar in ipairs(altars) do
        if altarLastSeen[altar.id] then
            local offline = now - altarLastSeen[altar.id] > KEEPALIVE_TIMEOUT
            if offline ~= altar.offline then
                altar.offline = offline
                if offline then
                    print("WARNING: Altar #" .. altar.id .. " not responding (last seen " ..
                          math.floor((now - altarLastSeen[altar.id]) / 1000) .. "s ago)")
                else
                    print("Altar #" .. altar.id .. " back online")
                end
            end
        end
    end

    for _, t in ipairs(turtles) do
        if turtleLastSeen[t.id] then
            local offline = now - turtleLastSeen[t.id] > KEEPALIVE_TIMEOUT
            if offline ~= t.offline then
                t.offline = offline
                if offline then
                    print("WARNING: Turtle #" .. t.id .. " not responding (last seen " ..
                          math.floor((now - turtleLastSeen[t.id]) / 1000) .. "s ago)")
                else
                    print("Turtle #" .. t.id .. " back online")
                end
            end
        end
    end

    -- Broadcast updated status so client can show offline indicators
    broadcast("status_update", {
        recipes = recipes,
        turtles = turtles,
        altars = altars,
        activeInfusions = activeInfusions,
        errorMode = errorMode,
        errorMessage = errorMessage,
        setupComplete = setupComplete
    })
end

-- ============================================================
-- PEDESTAL SCANNING
-- ============================================================

local function requestPedestalScan(altarId)
    local altar = nil
    for _, a in ipairs(altars) do
        if a.id == altarId then altar = a break end
    end
    if not altar then return end

    if #turtles == 0 then
        print("WARNING: No turtles available for pedestal scan")
        return
    end

    local t = turtles[1]

    print("=================================")
    print("Requesting pedestal scan for altar #" .. altarId)
    print("Using turtle #" .. t.id)
    print("=================================")

    modem.transmit(CHANNEL, CHANNEL, {
        type = "scan_pedestals",
        data = {
            turtleId = t.id,
            altarId = altarId,
            catalystPosition = altar.catalyst,
            assignedRows = {-3, -2, -1, 0, 1, 2, 3}
        }
    })

    updateTurtleStatus(t.id, "scanning", "scanning all pedestals")
end

-- ============================================================
-- ALTAR REGISTRATION
-- ============================================================

local function registerAltar(catalystPos, isReregister, existingId)
    local altarId = existingId or nextAltarId

    for _, altar in ipairs(altars) do
        if altar.catalyst.x == catalystPos.x and
           altar.catalyst.y == catalystPos.y and
           altar.catalyst.z == catalystPos.z then
            altar.id = altarId
            altarLastSeen[altarId] = os.epoch("utc")

            modem.transmit(CHANNEL, CHANNEL, {
                type = "altar_id_assigned",
                data = {catalystPosition = catalystPos, altarId = altarId}
            })

            if not altar.layoutConfirmed and #turtles > 0 then
                print("Altar #" .. altarId .. " needs confirmation, triggering scan...")
                requestPedestalScan(altarId)
            end
            return
        end
    end

    -- New altar
    if not isReregister then nextAltarId = nextAltarId + 1 end

    local altar = {
        id = altarId,
        catalyst = catalystPos,
        pedestals = {},
        stabilizers = {},
        busy = false,
        currentRecipe = nil,
        pedestalsScanned = false,
        layoutConfirmed = false
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
        data = {catalystPosition = catalystPos, altarId = altarId}
    })

    broadcast("altar_registered", {altarId = altarId, totalAltars = #altars})

    if #turtles > 0 then
        requestPedestalScan(altarId)
    else
        print("Waiting for turtles...")
    end
end

-- ============================================================
-- TURTLE REGISTRATION
-- ============================================================

local function registerTurtle(computerId, position, isReregister, existingId)
    local turtleId = existingId or nextTurtleId

    local found = false
    for _, t in ipairs(turtles) do
        if t.id == turtleId or (not isReregister and t.computerId == computerId) then
            t.computerId = computerId
            t.position = position
            t.status = "idle"
            t.statusDetail = "waiting"
            turtleId = t.id
            found = true
            print("Re-registered turtle #" .. turtleId)
            break
        end
    end

    if not found then
        if not isReregister then nextTurtleId = nextTurtleId + 1 end
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

    -- Build the response. If we already know chest/ME positions (from a
    -- previous turtle's chest_found report or from the saved database),
    -- send them so the turtle can skip the discovery scan.
    -- Otherwise send serverPosition so the turtle can find the chest itself.
    local responseData = {
        computerId = computerId,
        assignedId = turtleId,
    }

    -- Always send serverPosition so turtle can set its no-fly zone
    if serverPosition then
        responseData.serverPosition = serverPosition
    end

    if chestPosition then
        responseData.chestPosition = chestPosition
        responseData.meInterfacePosition = meInterfacePosition
        print("Sending known chest/ME positions to turtle #" .. turtleId)
    elseif serverPosition then
        print("Sending serverPosition to turtle #" .. turtleId .. " for chest discovery")
    else
        print("WARNING: No serverPosition or chestPosition available for turtle #" .. turtleId)
    end

    modem.transmit(CHANNEL, CHANNEL, {
        type = "turtle_id_assigned",
        data = responseData
    })

    broadcast("turtle_registered", {turtleId = turtleId, totalTurtles = #turtles})

    -- Trigger scans for unconfirmed altars (only if chest is known)
    if chestPosition then
        for _, altar in ipairs(altars) do
            if not altar.layoutConfirmed then
                print("Found altar #" .. altar.id .. " needing confirmation, triggering scan...")
                requestPedestalScan(altar.id)
                break
            end
        end
    else
        print("Chest not yet found; altar scans will trigger after chest_found.")
    end
end

-- ============================================================
-- SETUP COMPLETION
-- ============================================================

local function completeSetup()
    if setupComplete then return end
    setupComplete = true
    print("")
    print("=================================")
    print("Setup Complete!")
    print("Altars ready: " .. #altars)
    print("=================================")
    broadcast("setup_complete", {altarCount = #altars})
end

-- ============================================================
-- SCAN RESULTS
-- ============================================================

local function handlePedestalScanResults(altarId, pedestalPositions, stabilizerPositions, turtleId)
    for _, altar in ipairs(altars) do
        if altar.id == altarId then
            altar.pedestals = pedestalPositions or {}
            altar.stabilizers = stabilizerPositions or {}

            print("Altar #" .. altarId .. " scan results:")
            print("  Pedestals: " .. #altar.pedestals)
            print("  Stabilizers: " .. #altar.stabilizers)

            -- Sort pedestals in Thaumcraft infusion order:
            -- Cardinals first (N, S, W, E), then diagonals (NE, SW, SE, NW),
            -- then anything further out by distance.
            -- Within each ring, N=south(-Z), S=north(+Z), W=west(-X), E=east(+X)
            -- (Minecraft Z: negative = north, positive = south)
            local function pedestalOrder(pos, catalyst)
                local dx = pos.x - catalyst.x
                local dz = pos.z - catalyst.z
                local dist = math.abs(dx) + math.abs(dz)
                -- Flat if/elseif chain — no nested blocks
                if     dx == 0 and dz  < 0 then return dist * 100 + 1  -- North
                elseif dx == 0 and dz  > 0 then return dist * 100 + 2  -- South
                elseif dz == 0 and dx  < 0 then return dist * 100 + 3  -- West
                elseif dz == 0 and dx  > 0 then return dist * 100 + 4  -- East
                elseif dx  > 0 and dz  < 0 then return dist * 100 + 5  -- NE
                elseif dx  < 0 and dz  > 0 then return dist * 100 + 6  -- SW
                elseif dx  > 0 and dz  > 0 then return dist * 100 + 7  -- SE
                elseif dx  < 0 and dz  < 0 then return dist * 100 + 8  -- NW
                else                             return dist * 100 + 9
                end
            end
            table.sort(altar.pedestals, function(a, b)
                return pedestalOrder(a, altar.catalyst) < pedestalOrder(b, altar.catalyst)
            end)

            altar.pedestalsScanned = true

            broadcast("altar_layout", {
                altarId = altarId,
                pedestals = altar.pedestals,
                stabilizers = altar.stabilizers
            })

            saveDatabase()
            updateTurtleStatus(turtleId, "idle", "waiting")
            break
        end
    end
end

-- ============================================================
-- ALTAR CONFIRMATION
-- ============================================================

local function confirmAltarLayout(altarId)
    for _, altar in ipairs(altars) do
        if altar.id == altarId then
            altar.layoutConfirmed = true
            print("Altar #" .. altarId .. " layout CONFIRMED!")
            saveDatabase()
            broadcast("altar_confirmed", {altarId = altarId})

            local allConfirmed = true
            for _, a in ipairs(altars) do
                if not a.layoutConfirmed then allConfirmed = false break end
            end
            if allConfirmed and #altars > 0 then completeSetup() end
            break
        end
    end
end

-- ============================================================
-- RECIPE MANAGEMENT
-- ============================================================

local function recipeExists(catalyst, ingredients)
    for _, recipe in ipairs(recipes) do
        if not itemsMatch(catalyst.item, recipe.catalyst.item, true, true) then
        elseif catalyst.matchNBT ~= recipe.catalyst.matchNBT or
               catalyst.matchDMG ~= recipe.catalyst.matchDMG then
        elseif #ingredients ~= #recipe.ingredients then
        else
            local allFound = true
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
                if not found then allFound = false break end
            end
            if allFound then return true end
        end
    end
    return false
end

local function addRecipe(catalyst, ingredients)
    if recipeExists(catalyst, ingredients) then
        modem.transmit(CHANNEL, CHANNEL, {
            type = "add_recipe_nack",
            data = {reason = "Duplicate recipe"}
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
        data = {recipeId = #recipes, recipe = recipe}
    })

    broadcast("recipe_added", {recipeId = #recipes, recipe = recipe})
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
        for _, chestItem in ipairs(chestItems) do
            if itemsMatch(chestItem, recipe.catalyst.item, recipe.catalyst.matchNBT, recipe.catalyst.matchDMG) then
                catalystFound = true
                break
            end
        end

        if catalystFound then
            local ingredientsFound = {}
            local matched = true

            for _, ingredient in ipairs(recipe.ingredients) do
                local found = false
                for _, chestItem in ipairs(chestItems) do
                    local alreadyUsed = false
                    for _, usedItem in ipairs(ingredientsFound) do
                        if usedItem.slot == chestItem.slot then alreadyUsed = true break end
                    end
                    if not alreadyUsed and
                       itemsMatch(chestItem, ingredient.item, ingredient.matchNBT, ingredient.matchDMG) then
                        table.insert(ingredientsFound, chestItem)
                        found = true
                        break
                    end
                end
                if not found then matched = false break end
            end

            if matched then return recipeId, recipe end
        end
    end

    return nil
end

-- ============================================================
-- INFUSION
-- ============================================================

local function startInfusion(recipeId, recipe, altarIdx)
    print("Starting infusion for recipe #" .. recipeId .. " on altar #" .. altarIdx)

    local altar = altars[altarIdx]

    if not altar.layoutConfirmed then
        print("ERROR: Altar #" .. altarIdx .. " layout not confirmed!")
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

    -- Clear any leftover tasks from previous runs
    for _, t in ipairs(turtles) do
        t.tasks = {}
    end

    -- Turtle 1 gets the catalyst. Ingredients are distributed round-robin
    -- across ALL turtles starting from turtle 1, so every turtle gets work.
    -- Each turtle gets a flat list of tasks; it processes them sequentially,
    -- going home between each one.
    local turtleIdx = 1

    -- Catalyst first, on turtle 1.
    -- altar.catalyst is the computer position (y=68); the catalyst pedestal
    -- sits one block above it (y=69), so we pass y+1 as the drop target.
    if turtles[1] then
        table.insert(turtles[1].tasks, {
            type = "place_catalyst",
            item = recipe.catalyst,
            position = { x = altar.catalyst.x, y = altar.catalyst.y + 1, z = altar.catalyst.z },
            altarCatalyst = altar.catalyst,
            chestPosition = chestPosition
        })
    end

    -- Ingredients distributed round-robin across all turtles
    for i, ingredient in ipairs(recipe.ingredients) do
        if i > #altar.pedestals then
            print("WARNING: More ingredients (" .. #recipe.ingredients .. ") than pedestals (" .. #altar.pedestals .. ")!")
            break
        end

        local t = turtles[turtleIdx]
        if t then
            table.insert(t.tasks, {
                type = "place_ingredient",
                item = ingredient,
                position = altar.pedestals[i],
                altarCatalyst = altar.catalyst,
                chestPosition = chestPosition
            })
        end

        turtleIdx = turtleIdx + 1
        if turtleIdx > #turtles then turtleIdx = 1 end
    end

    -- Dispatch each turtle that has tasks, staggered 10 ticks (0.5s) apart
    -- so they don't all rush to the chest simultaneously.
    local dispatchDelay = 0
    for _, t in ipairs(turtles) do
        if #t.tasks > 0 then
            print("Dispatching " .. #t.tasks .. " task(s) to turtle #" .. t.id ..
                  " (delay=" .. dispatchDelay .. " ticks)")
            modem.transmit(CHANNEL, CHANNEL, {
                type = "turtle_tasks",
                data = {
                    turtleId = t.id,
                    tasks = t.tasks,
                    startDelay = dispatchDelay
                }
            })
            updateTurtleStatus(t.id, "working", "placing items")
            dispatchDelay = dispatchDelay + 10
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
        if a.id == altarId then altar = a; break end
    end
    if not altar then return end

    -- Clear all turtle task queues before assigning retrieval/clear work
    for _, t in ipairs(turtles) do
        t.tasks = {}
    end

    -- Turtle 1 retrieves the result from the catalyst pedestal (one above the computer)
    if turtles[1] then
        table.insert(turtles[1].tasks, {
            type = "retrieve_result",
            position = { x = altar.catalyst.x, y = altar.catalyst.y + 1, z = altar.catalyst.z },
            meInterfacePosition = meInterfacePosition
        })
    end

    -- Distribute pedestal clearing round-robin across all turtles
    local turtleIdx = 1
    for _, pedestalPos in ipairs(altar.pedestals) do
        local t = turtles[turtleIdx]
        if t then
            table.insert(t.tasks, {
                type = "clear_pedestal",
                position = pedestalPos,
                altarCatalyst = altar.catalyst,
                meInterfacePosition = meInterfacePosition
            })
        end
        turtleIdx = turtleIdx + 1
        if turtleIdx > #turtles then turtleIdx = 1 end
    end

    -- Dispatch with stagger
    local dispatchDelay = 0
    for _, t in ipairs(turtles) do
        if #t.tasks > 0 then
            print("Dispatching " .. #t.tasks .. " clear task(s) to turtle #" .. t.id)
            modem.transmit(CHANNEL, CHANNEL, {
                type = "turtle_tasks",
                data = {
                    turtleId = t.id,
                    tasks = t.tasks,
                    startDelay = dispatchDelay
                }
            })
            updateTurtleStatus(t.id, "working", "clearing altar")
            dispatchDelay = dispatchDelay + 10
        end
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

-- ============================================================
-- MESSAGE HANDLING
-- ============================================================

local function handleMessage(msg, sender)
    if type(msg) ~= "table" or not msg.type then return end

    if msg.type == "turtle_register" then
        -- Accept both "computerId" and "computerID" (turtle sends capital ID)
        local cid = msg.data.computerId or msg.data.computerID or sender
        registerTurtle(cid, msg.data.position, false, nil)

    elseif msg.type == "turtle_reregister" then
        local cid = msg.data.computerId or msg.data.computerID or sender
        registerTurtle(cid, msg.data.position, true, msg.data.turtleId)

    elseif msg.type == "altar_register" then
        registerAltar(msg.data.catalystPosition, false, nil)

    elseif msg.type == "altar_reregister" then
        registerAltar(msg.data.catalystPosition, true, msg.data.altarId)

    -- NEW: Turtle reports the chest it found by scanning around the server
    elseif msg.type == "chest_found" then
        chestPosition = msg.data.chestPosition
        meInterfacePosition = msg.data.meInterfacePosition

        print("=================================")
        print("Chest found by turtle #" .. (msg.data.turtleId or "?"))
        print("Chest: " .. textutils.serialize(chestPosition))
        print("ME:    " .. textutils.serialize(meInterfacePosition))
        print("=================================")

        saveDatabase()

        -- Now that we know where the chest is, trigger any pending altar scans
        for _, altar in ipairs(altars) do
            if not altar.layoutConfirmed then
                print("Triggering pending scan for altar #" .. altar.id)
                requestPedestalScan(altar.id)
                break
            end
        end

        broadcast("chest_located", {
            chestPosition = chestPosition,
            meInterfacePosition = meInterfacePosition
        })

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
        for _, altar in ipairs(altars) do
            if altar.id == msg.data.altarId then
                altar.pedestals = {}
                altar.stabilizers = {}
                altar.pedestalsScanned = false
                altar.layoutConfirmed = false
                saveDatabase()
                broadcast("altar_layout_cleared", {altarId = altar.id})
                requestPedestalScan(msg.data.altarId)
                break
            end
        end

    elseif msg.type == "add_recipe" then
        addRecipe(msg.data.catalyst, msg.data.ingredients)

    elseif msg.type == "turtle_task_complete" then
        for _, t in ipairs(turtles) do
            if t.id == msg.data.turtleId then
                turtleLastSeen[t.id] = os.epoch("utc")  -- task_complete proves turtle is alive
                t.offline = false
                if #t.tasks > 0 then table.remove(t.tasks, 1) end
                if #t.tasks == 0 then updateTurtleStatus(t.id, "idle", "waiting") end
                break
            end
        end

    elseif msg.type == "restart_infusion" then
        local altarId = msg.data.altarId
        print("Restart infusion requested for altar #" .. tostring(altarId))

        -- Abort any active infusion on this altar
        if altarId and activeInfusions[altarId] then
            activeInfusions[altarId] = nil
            for _, altar in ipairs(altars) do
                if altar.id == altarId then
                    altar.busy = false
                    altar.currentRecipe = nil
                    break
                end
            end
        end

        -- Tell all turtles to abort and return items
        for _, t in ipairs(turtles) do
            t.tasks = {}
            modem.transmit(CHANNEL, CHANNEL, {
                type = "abort_and_return",
                data = { turtleId = t.id, chestPosition = chestPosition }
            })
        end

        -- Schedule a retry after turtles have had time to return
        pendingRestartAltarId = altarId
        restartTimer = os.startTimer(15)
        broadcast("infusion_restarting", { altarId = altarId })
        print("All turtles told to abort. Will retry infusion in 15s.")

    elseif msg.type == "turtle_status_update" then
        updateTurtleStatus(msg.data.turtleId, msg.data.status, msg.data.statusDetail)

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
            broadcast("chest_contents", {items = itemList})
        end

    elseif msg.type == "altar_keepalive" then
        if msg.data.altarId then
            altarLastSeen[msg.data.altarId] = os.epoch("utc")
        end

    elseif msg.type == "infusion_complete" then
        -- Also refresh altar keepalive — the altar is clearly alive if it
        -- just reported completion
        if msg.data.altarId then
            altarLastSeen[msg.data.altarId] = os.epoch("utc")
        end
        completeInfusion(msg.data.altarId, msg.data.resultItem)

    elseif msg.type == "turtle_keepalive" then
        if msg.data.turtleId then
            turtleLastSeen[msg.data.turtleId] = os.epoch("utc")
        end
    end
end

-- ============================================================
-- MAIN LOOP
-- ============================================================

local function main()
    print("=================================")
    print("Thaumcraft Infusion Server v3.3")
    print("=================================")

    serverPosition = getServerPosition()
    if serverPosition then
        print("Server position: " .. textutils.serialize(serverPosition))
    else
        print("WARNING: Running without GPS")
    end

    loadDatabase()
    print("Loaded " .. #recipes .. " recipes and " .. #altars .. " altars")

    if chestPosition then
        print("Chest/ME positions already known from database.")
    else
        print("Chest position not yet known - will be discovered by first turtle.")
    end

    if not inputChest then
        print("ERROR: No input chest on RIGHT side")
        errorMode = true
        errorMessage = "Input chest not found"
    end

    print("\nServer ready! Listening on channel " .. CHANNEL)

    local checkTimer = os.startTimer(2)
    local keepaliveTimer = os.startTimer(10)

    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()

        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message, replyChannel)

        elseif event == "timer" then
            if side == checkTimer then
                if setupComplete and not errorMode and chestPosition and
                   #turtles >= 1 and #altars > 0 then
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

            elseif restartTimer and side == restartTimer then
                restartTimer = nil
                -- Check all turtles are idle before retrying
                local allIdle = true
                for _, t in ipairs(turtles) do
                    if t.status ~= "idle" then allIdle = false break end
                end
                if allIdle and pendingRestartAltarId then
                    print("All turtles idle, retrying infusion on altar #" .. pendingRestartAltarId)
                    local recipeId, recipe = findMatchingRecipe()
                    if recipeId then
                        for altarIdx, altar in ipairs(altars) do
                            if altar.id == pendingRestartAltarId and altar.layoutConfirmed and not altar.busy then
                                startInfusion(recipeId, recipe, altarIdx)
                                break
                            end
                        end
                    else
                        print("No matching recipe found for restart, items may be missing from chest")
                        broadcast("status_update", {
                            recipes = recipes, turtles = turtles, altars = altars,
                            activeInfusions = activeInfusions, errorMode = errorMode,
                            errorMessage = errorMessage, setupComplete = setupComplete
                        })
                    end
                else
                    print("Turtles still busy after restart wait, extending timer 10s")
                    restartTimer = os.startTimer(10)
                end
                pendingRestartAltarId = nil
            end
        end
    end
end

main()
