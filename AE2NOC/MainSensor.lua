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

local stockRules = loadTable("autostock.dat")
local history = loadTable("job_history.dat")
local itemDB = loadTable("item_db.dat")
local activeJobs = {} 
local translationQueue = {}

local stats = { 
    currentItem = "Idle", 
    writeStatus = "Idle", 
    queueSize = 0, 
    managedEnabled = true,
    failCooldowns = {} 
}

print("Server v27.0 Online - Precision Mode")

-- =================================================================
-- BLOCK 4: MAIN CONTROL LOOP
-- =================================================================
while true do 
    local successI, rawItems = pcall(me.listAvailableItems)
    local currentTime = os.epoch("utc") / 1000
    
    if successI then
        -- Reset counts so items gone from AE2 show as 0
        for _, entry in pairs(itemDB) do entry.count = 0 end

        for _, it in ipairs(rawItems) do
            local key = it.name .. ":" .. (it.damage or 0)
            
            -- Initialize item in DB if it's new
            if not itemDB[key] then
                itemDB[key] = { label = it.label or "Awaiting Meta..." }
                table.insert(translationQueue, {name = it.name, damage = it.damage or 0, key = key})
            end

            -- Update itemDB state
            itemDB[key].count = it.count
            itemDB[key].isCraftable = it.isCraftable
            itemDB[key].target = stockRules[key] or 0
            itemDB[key].managed = (itemDB[key].target > 0)
        end
    end

    -- Translator Logic
    if #translationQueue > 0 then
        local nextItem = table.remove(translationQueue, 1)
        local ok, handle = pcall(me.findItem, { name = nextItem.name, damage = nextItem.damage or 0 })
        if ok and handle then
            local mOk, meta = pcall(handle.getMetadata)
            if mOk and meta and meta.displayName then
                if itemDB[nextItem.key] then itemDB[nextItem.key].label = meta.displayName end
                saveTable("item_db.dat", itemDB)
            end
        end
    end
    stats.queueSize = #translationQueue

    -- =============================================================
    -- BLOCK 6: JOB MONITORING
    -- =============================================================
    for i = #activeJobs, 1, -1 do
        local job = activeJobs[i]
        if not job.expiry then
            local ok, finished = pcall(job.handle.isFinished)
            local ok2, canceled = pcall(job.handle.isCanceled)
            local ok3, status = pcall(job.handle.status)
            
            if (ok and finished) or (ok2 and canceled) then
                local duration = currentTime - (job.startTime or currentTime)
                local actualStatus = status or "unknown"
                
                if ok3 and actualStatus == "finished" then
                    stats.completed = (stats.completed or 0) + 1
                else
                    stats.failed = (stats.failed or 0) + 1
                    job.expiry = currentTime + 30 
                    stats.failCooldowns[job.key] = job.expiry
                end

                table.insert(history, 1, { 
                    name = job.key, 
                    displayName = job.displayName or job.key, 
                    amount = job.target, 
                    status = (actualStatus == "finished") and "DONE" or "FAIL",
                    rawStatus = actualStatus,
                    duration = string.format("%.2fs", duration)
                })
                
                if #history > 50 then table.remove(history) end
                saveTable("job_history.dat", history)
                table.remove(activeJobs, i) -- Job is done/failed, remove it
            else
                -- Progress update
                if successI and itemDB[job.key] then
                    job.progress = (itemDB[job.key].count or 0) - job.startCount
                end
            end
        elseif currentTime > job.expiry then
            table.remove(activeJobs, i) -- Clean up expired failed jobs
        end
    end

    -- =============================================================
    -- BLOCK 7: AUTOCRAFT LOGIC
    -- =============================================================
    if stats.managedEnabled and successI then
        for _, it in ipairs(rawItems) do
            local key = it.name .. ":" .. (it.damage or 0)
            local target = stockRules[key] or 0
            local cooldown = stats.failCooldowns[key] or 0
            
            if target > 0 and it.count < target and it.isCraftable then
                local busy = false
                for _, j in pairs(activeJobs) do 
                    if j.key == key then busy = true break end 
                end

                if not busy and currentTime > cooldown then
                    local ok, itemHandle = pcall(me.findItem, { name = it.name, damage = it.damage or 0 })
                    if ok and itemHandle then
                        local needed = target - it.count
                        local craftOk, handle = pcall(itemHandle.craft, needed)
                        
                        if craftOk and type(handle) == "table" then
                            table.insert(activeJobs, {
                                handle = handle, 
                                key = key, 
                                id = os.epoch("utc"), 
                                displayName = (itemDB[key] and itemDB[key].label) or it.label or it.name,
                                target = needed, 
                                startCount = it.count, 
                                progress = 0,
                                startTime = currentTime
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

    local totalItemsCount = 0
    local usedTypesCount = 0
    for _, entry in pairs(itemDB) do
        if entry.count and entry.count > 0 then
            totalItemsCount = totalItemsCount + entry.count
            usedTypesCount = usedTypesCount + 1
        end
    end

    stats.totalItems = totalItemsCount
    stats.usedTypes = usedTypesCount

    modem.transmit(DATA_CHAN, DATA_CHAN, {
        type = "SERVER_SYNC", 
        itemDB = itemDB,
        activeJobs = activeJobs, 
        history = history, 
        stats = stats,
        cpus = cpuData
    })

    -- =============================================================
    -- BLOCK 9: EVENT LISTENER
    -- =============================================================
    local pulseTimer = os.startTimer(2.0)
    while true do
        local event, side, chan, replyChan, msg = os.pullEvent()
        if event == "timer" and side == pulseTimer then 
            break 
        elseif event == "modem_message" and chan == ORDER_CHAN and type(msg) == "table" then
            if msg.type == "SET_RULE" then 
                if msg.target <= 0 then 
                    stockRules[msg.name] = nil
                else 
                    stockRules[msg.name] = msg.target 
                end
                saveTable("autostock.dat", stockRules)
                -- Sync the local DB immediately for the next loop
                if itemDB[msg.name] then itemDB[msg.name].target = msg.target or 0 end
            elseif msg.type == "TOGGLE_MGMT" then 
                stats.managedEnabled = not stats.managedEnabled 
            elseif msg.type == "CLEAR_HISTORY" then 
                history = {}
                saveTable("job_history.dat", history) 
            end
        end
    end
end
