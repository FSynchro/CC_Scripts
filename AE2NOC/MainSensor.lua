-- =================================================================
-- BLOCK 1: INITIALIZATION & PERIPHERALS
-- Sets up modems, AE2 interface, and networking channels.
-- =================================================================
local DATA_CHAN, ORDER_CHAN = 1428, 1429
local modem = peripheral.find("modem", function(_, p) return p.isWireless() end) or error("No Modem")
local me = peripheral.find("appliedenergistics2:interface") or error("No AE2 Interface")

modem.open(ORDER_CHAN)

-- =================================================================
-- BLOCK 2: PERSISTENCE HELPERS
-- Saves and loads .dat files so data survives a server reboot.
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
-- Loads databases and initializes the translation queue.
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

print("Server v27.0 Online")

local function getFriendlyStatus(entry)
    if not entry then return "" end
    if entry.isCanceled then return statusMessages.canceled end
    -- If it's finished, show the "Completed" message
    if entry.isFinished then 
        return string.format(statusMessages.finished, entry.count or 0, entry.label or "Item") 
    end
    
    -- Map AE2 raw status to our friendly messages
    local s = entry.jobStatus or "unknown"
    if s == "missing" then return statusMessages.missing
    elseif s == "stalled" then return statusMessages.stalled
    elseif s == "running" or s == "unknown" then
        -- Format: Crafting: Stone (10/64)
        return string.format(statusMessages.unknown, entry.label or "Item", entry.progress or 0, entry.jobTarget or 0)
    end
    return s
end

-- =================================================================
-- BLOCK 4: MAIN CONTROL LOOP
-- =================================================================
while true do 
    local successI, rawItems = pcall(me.listAvailableItems)
    local currentTime = os.epoch("utc") / 1000
    
    if successI then
        -- Reset counts so items gone from AE2 show as 0
        for _, entry in pairs(itemDB) do entry.count = 0 end

        -- NEW: Create a quick lookup map of what's already in the queue
        local queueLookup = {}
        for _, q in ipairs(translationQueue) do 
            queueLookup[q.key] = true 
        end

        for _, it in ipairs(rawItems) do
            local key = it.name .. ":" .. (it.damage or 0)
            
            -- 1. Initialize item in DB
            if not itemDB[key] then
                itemDB[key] = { label = "Awaiting Meta...", target = 0 }
            end

            -- 2. RECOVERY LOGIC
            if itemDB[key].label == "Awaiting Meta..." and not queueLookup[key] then
                table.insert(translationQueue, {name = it.name, damage = it.damage or 0, key = key})
                queueLookup[key] = true 
            end

            -- Update itemDB state
            itemDB[key].count = it.count
            itemDB[key].isCraftable = it.isCraftable
            
            -- Update live data
            itemDB[key].count = it.count
            itemDB[key].isCraftable = it.isCraftable
        end
            -- (The Autocraft Logic below this stays the same...)

            -- Autocraft Logic
            if stats.managedEnabled then
                local target = itemDB[key].target
                local cooldown = stats.failCooldowns[key] or 0
                
                if target > 0 and it.count < target and it.isCraftable then
                    local busy = false
                    for _, j in pairs(activeJobs) do if j.key == key then busy = true break end end

                    if not busy and currentTime > cooldown then
                        local ok, itemHandle = pcall(me.findItem, { name = it.name, damage = it.damage or 0 })
                        if ok and itemHandle then
                            local needed = target - it.count
                            local craftOk, handle = pcall(itemHandle.craft, needed)
                            if craftOk and type(handle) == "table" then
                                table.insert(activeJobs, {
                                    handle = handle, key = key, id = os.epoch("utc"), 
                                    displayName = itemDB[key].label, target = needed, 
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
    end

-- =============================================================
-- Translator Logic (BATCH MODE - MUCH FASTER)
-- =============================================================
local batchSize = 15 -- How many items to translate per loop
local processedThisCycle = 0

while #translationQueue > 0 and processedThisCycle < batchSize do
    local nextItem = translationQueue[1]
    currentTranslation = nextItem 
    
    local ok, handle = pcall(me.findItem, { name = nextItem.name, damage = nextItem.damage or 0 })
    if ok and handle then
        local mOk, meta = pcall(handle.getMetadata)
        if mOk and meta and meta.displayName then
            if itemDB[nextItem.key] then 
                itemDB[nextItem.key].label = meta.displayName 
            end
            table.remove(translationQueue, 1)
            processedThisCycle = processedThisCycle + 1
        else
            -- If metadata fails, move it to the end of the queue so it doesn't block others
            table.insert(translationQueue, table.remove(translationQueue, 1))
            processedThisCycle = processedThisCycle + 1
        end
    else
        -- Item might have been removed from AE2, skip it
        table.remove(translationQueue, 1)
    end
end

-- Save only once after the batch is done to prevent disk lag
if processedThisCycle > 0 then
    saveTable("item_db.dat", itemDB)
end

stats.queueSize = #translationQueue
stats.currentEntry = currentTranslation

-- =============================================================
-- BLOCK 6: JOB MONITORING (Updated)
-- =============================================================
stats.failCooldowns = stats.failCooldowns or {} 
local currentTime = os.epoch("utc") / 1000

-- Clear previous status from itemDB so old jobs don't "stick" to items
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
    
    -- Sync this job data back to the itemDB so the Stock Tab sees it
    if itemDB[job.key] then
        itemDB[job.key].isCrafting = true
        itemDB[job.key].jobStatus = status or "running"
        itemDB[job.key].isFinished = finished
        itemDB[job.key].isCanceled = canceled
        itemDB[job.key].progress = job.progress or 0
        itemDB[job.key].jobTarget = job.target or 0
        -- Add the friendly text so the Display doesn't have to calculate it
        itemDB[job.key].friendlyStatus = getFriendlyStatus(itemDB[job.key])
    end

    if (ok and finished) or (ok2 and canceled) then
        -- ... (Keep your existing history-saving logic here) ...
        if status == "finished" then table.remove(activeJobs, i) end
    else
        -- Progress update
        if successI and itemDB[job.key] then
            job.progress = itemDB[job.key].count - job.startCount
        end
    end
end


-- =============================================================
-- BLOCK 7: AUTOCRAFT LOGIC (Centralized)
-- =============================================================
if stats.managedEnabled and successI then
    for key, it in pairs(itemDB) do
        local target = it.target or 0
        local cooldown = stats.failCooldowns[key] or 0
        
        -- Logic: Must have a target AND be below it AND be craftable
        if target > 0 and it.count < target and it.isCraftable then
            
            -- Check if we are already working on this
            local busy = false
            for _, j in pairs(activeJobs) do 
                if j.key == key then busy = true break end 
            end

            if not busy and currentTime > cooldown then
                -- Reconstruct AE2 search table from our key
                local name, damage = key:match("([^:]+):([^:]+)")
                local ok, itemHandle = pcall(me.findItem, { name = name, damage = tonumber(damage) })
                
                if ok and itemHandle then
                    local needed = target - it.count
                    local craftOk, handle = pcall(itemHandle.craft, needed)
                    
                    if craftOk and type(handle) == "table" then
                        table.insert(activeJobs, {
                            handle = handle, 
                            key = key, 
                            id = os.epoch("utc"), 
                            displayName = it.label or name,
                            target = needed, 
                            startCount = it.count, 
                            progress = 0,
                            startTime = currentTime
                        })
                    else
                        -- If AE2 fails to start the job (e.g., no CPUs), cool down for 10s
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

    local totalItemsCount = 0
    local usedTypesCount = 0
    if successI and rawItems then
        usedTypesCount = #rawItems
        for _, it in ipairs(rawItems) do
            totalItemsCount = totalItemsCount + it.count
        end
    end

    modem.transmit(DATA_CHAN, DATA_CHAN, {
        type = "SERVER_SYNC", 
        itemDB = itemDB,
        activeJobs = activeJobs, 
        history = history, 
        stats = stats,
        cpus = cpuData,
        totalItems = totalItemsCount,
        usedTypes = usedTypesCount
    })

    -- =============================================================
    -- BLOCK 9: EVENT LISTENER
    -- =============================================================
    local pulseTimer = os.startTimer(2.0)
    while true do
        local event, side, chan, replyChan, msg = os.pullEvent()
        
        if event == "timer" and side == pulseTimer then 
            break -- Breaks Block 9 loop to refresh Block 4
            
        elseif event == "modem_message" and chan == ORDER_CHAN and type(msg) == "table" then
            if msg.type == "SET_RULE" then 
                if itemDB[msg.name] then
                    itemDB[msg.name].target = math.max(0, tonumber(msg.target) or 0)
                    saveTable("item_db.dat", itemDB)
                    print("Updated Target: " .. msg.name)
                end
            elseif msg.type == "TOGGLE_MGMT" then 
                stats.managedEnabled = not stats.managedEnabled
            elseif msg.type == "CLEAR_HISTORY" then 
                history = {}
                saveTable("job_history.dat", history) 
            end
        end 
    end -- End of Block 9 While
end -- End of Block 4 While
