-- =================================================================
-- BLOCK 1: INITIALIZATION & PERIPHERALS
-- =================================================================
local DATA_CHAN, ORDER_CHAN = 1428, 1429
local modem = peripheral.find("modem", function(_, p) return p.isWireless() end) or error("No Modem")
local me = peripheral.find("appliedenergistics2:interface") or error("No AE2 Interface")

modem.open(ORDER_CHAN)

-- =================================================================
-- BLOCK 2: PERSISTENCE HELPERS
-- =================================================================
local function saveTable(file, data)
    local f = fs.open(file, "w")
    if f then f.write(textutils.serialize(data)) f.close() end
end

local function loadTable(file)
    if fs.exists(file) then
        local f = fs.open(file, "r")
        local raw = f.readAll()
        f.close()
        return textutils.unserialize(raw) or {}
    end
    return {}
end

-- =================================================================
-- BLOCK 3: STATE VARIABLES
-- =================================================================
local currentTranslation = nil
local stockRules = loadTable("autostock.dat")
local history = loadTable("job_history.dat")
local itemDB = loadTable("item_db.dat")
local activeJobs = {} 
local translationQueue = {}
local stats = { 
    completed = 0, 
    failed = 0, 
    managedEnabled = true, 
    queueSize = 0,
    failCooldowns = {}
}
local statusMessages = {
    missing = "Missing ingredients/recipe!",
    canceled = "Job canceled.",
    stalled = "Job stalled!",
    finished = "Completed: %s %s",
    unknown = "Crafting: %s (%s/%s)"
}

print("Server v28.0 Online")

local function getFriendlyStatus(entry)
    if not entry then return "" end
    if entry.isCanceled then return statusMessages.canceled end
    if entry.isFinished then 
        return string.format(statusMessages.finished, entry.count or 0, entry.label or "Item") 
    end
    
    local s = entry.jobStatus or "unknown"
    if s == "missing" then return statusMessages.missing
    elseif s == "stalled" then return statusMessages.stalled
    else
        return string.format(statusMessages.unknown, entry.label or "Item", entry.progress or 0, entry.jobTarget or 0)
    end
end

-- =================================================================
-- MAIN CONTROL LOOP
-- =================================================================
while true do 
    local successI, rawItems = pcall(me.listAvailableItems)
    local currentTime = os.epoch("utc") / 1000
    
    if successI then
        -- Reset counts
        for _, entry in pairs(itemDB) do entry.count = 0 end

        local queueLookup = {}
        for _, q in ipairs(translationQueue) do queueLookup[q.key] = true end

        for _, it in ipairs(rawItems) do
            local key = it.name .. ":" .. (it.damage or 0)
            
            if not itemDB[key] then
                itemDB[key] = { label = "Awaiting Meta...", target = 0 }
            end

            if itemDB[key].label == "Awaiting Meta..." and not queueLookup[key] then
                table.insert(translationQueue, {name = it.name, damage = it.damage or 0, key = key})
                queueLookup[key] = true 
            end

            itemDB[key].count = it.count
            itemDB[key].isCraftable = it.isCraftable
        end 
    end

    -- =============================================================
    -- BLOCK 5: TRANSLATOR LOGIC (BATCH MODE)
    -- =============================================================
    local batchSize = 15
    local processedThisCycle = 0

    while #translationQueue > 0 and processedThisCycle < batchSize do
        local nextItem = translationQueue[1]
        currentTranslation = nextItem 
        
        local ok, handle = pcall(me.findItem, { name = nextItem.name, damage = nextItem.damage or 0 })
        if ok and handle then
            local mOk, meta = pcall(handle.getMetadata)
            if mOk and meta and meta.displayName then
                if itemDB[nextItem.key] then itemDB[nextItem.key].label = meta.displayName end
                table.remove(translationQueue, 1)
                processedThisCycle = processedThisCycle + 1
            else
                table.insert(translationQueue, table.remove(translationQueue, 1))
                processedThisCycle = processedThisCycle + 1
            end
        else
            table.remove(translationQueue, 1)
        end
    end

    if processedThisCycle > 0 then saveTable("item_db.dat", itemDB) end
    stats.queueSize = #translationQueue
    stats.currentEntry = currentTranslation

    -- =============================================================
    -- BLOCK 6: JOB MONITORING
    -- =============================================================
    for _, it in pairs(itemDB) do
        it.isCrafting = false
        it.jobStatus = nil
        it.isFinished = nil
        it.isCanceled = nil
    end

    for i = #activeJobs, 1, -1 do
        local job = activeJobs[i]
        local ok, finished = pcall(job.handle.isFinished)
        local ok2, canceled = pcall(job.handle.isCanceled)
        local ok3, status = pcall(job.handle.status)
        
        if itemDB[job.key] then
            itemDB[job.key].isCrafting = true
            itemDB[job.key].jobStatus = status or "running"
            itemDB[job.key].isFinished = finished
            itemDB[job.key].isCanceled = canceled
            itemDB[job.key].progress = job.progress or 0
            itemDB[job.key].jobTarget = job.target or 0
            itemDB[job.key].friendlyStatus = getFriendlyStatus(itemDB[job.key])
        end

        if (ok and finished) or (ok2 and canceled) then
            -- History logic can be added here
            table.remove(activeJobs, i)
        else
            if successI and itemDB[job.key] then
                job.progress = itemDB[job.key].count - job.startCount
            end
        end
    end

    -- =============================================================
    -- BLOCK 7: AUTOCRAFT LOGIC (CENTRALIZED)
    -- =============================================================
    if stats.managedEnabled and successI then
        for key, it in pairs(itemDB) do
            local target = it.target or 0
            local cooldown = stats.failCooldowns[key] or 0
            
            if target > 0 and it.count < target and it.isCraftable then
                local busy = false
                for _, j in pairs(activeJobs) do if j.key == key then busy = true break end end

                if not busy and currentTime > cooldown then
                    local name, damage = key:match("([^:]+):([^:]+)")
                    local ok, itemHandle = pcall(me.findItem, { name = name, damage = tonumber(damage) })
                    
                    if ok and itemHandle then
                        local needed = target - it.count
                        local craftOk, handle = pcall(itemHandle.craft, needed)
                        
                        if craftOk and type(handle) == "table" then
                            table.insert(activeJobs, {
                                handle = handle, key = key, id = os.epoch("utc"), 
                                displayName = it.label or name, target = needed, 
                                startCount = it.count, progress = 0, startTime = currentTime
                            })
                        else
                            stats.failCooldowns[key] = currentTime + 10
                        end
                    end
                end
            end
        end
    end

    -- =============================================================
    -- BLOCK 8: NETWORK & CPUS
    -- =============================================================
    local cpus = me.getCraftingCPUs()
    local cpuData = { total = #cpus, busy = 0, totalCoPro = 0, maxStorage = 0, avgCoPro = 0 }
    for _, cpu in ipairs(cpus) do
        if cpu.busy then cpuData.busy = cpuData.busy + 1 end
        cpuData.totalCoPro = cpuData.totalCoPro + (cpu.coprocessors or 0)
        if (cpu.storage or 0) > cpuData.maxStorage then cpuData.maxStorage = cpu.storage end
    end
    if cpuData.total > 0 then cpuData.avgCoPro = cpuData.totalCoPro / cpuData.total end

    modem.transmit(DATA_CHAN, DATA_CHAN, {
        type = "SERVER_SYNC", 
        itemDB = itemDB,
        activeJobs = activeJobs, 
        history = history, 
        stats = stats,
        cpus = cpuData
    })

    -- =============================================================
    -- BLOCK 9: EVENT LISTENER (FLATTENED)
    -- =============================================================
    local pulseTimer = os.startTimer(2.0)
    -- No nested while loop here anymore
    local event, side, chan, replyChan, msg = os.pullEvent()
    
    if event == "modem_message" and chan == ORDER_CHAN and type(msg) == "table" then
        if msg.type == "SET_RULE" and itemDB[msg.name] then 
            itemDB[msg.name].target = math.max(0, tonumber(msg.target) or 0)
            saveTable("item_db.dat", itemDB)
        elseif msg.type == "TOGGLE_MGMT" then 
            stats.managedEnabled = not stats.managedEnabled
        elseif msg.type == "CLEAR_HISTORY" then 
            history = {}
            saveTable("job_history.dat", history) 
        end
    end
end
