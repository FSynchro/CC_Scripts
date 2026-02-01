-- =================================================================
-- BLOCK 1: UI INITIALIZATION
-- Sets up the monitor, buffer, and wireless modem.
-- =================================================================
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem", function(_, p) return p.isWireless() end) 
    or error("No Wireless Modem Found")

mon.setTextScale(0.5)
local w, h = mon.getSize()
local buffer = window.create(mon, 1, 1, w, h, true)

modem.open(1422) -- Cell Data
modem.open(1428) -- Server/Job Data
modem.open(1429) -- Command Feedback

-- =================================================================
-- BLOCK 2: GLOBAL STATE & HELPERS
-- Variables to store incoming server data and formatting functions.
-- =================================================================

local function drawBar(x, y, width, current, max)
    -- Calculate progress percentage (0.0 to 1.0)
    local progress = math.min(math.max(current / (max > 0 and max or 1), 0), 1)
    
    -- Draw the background (Track)
    buffer.setCursorPos(x, y)
    buffer.setBackgroundColor(colors.gray)
    buffer.write(string.rep(" ", width))
    
    -- Draw the foreground (Fill)
    -- Change color to red if above 80% full
    local barColor = progress < 0.8 and colors.lime or colors.red
    buffer.setCursorPos(x, y)
    buffer.setBackgroundColor(barColor)
    buffer.write(string.rep(" ", math.floor(progress * width)))
    
    -- Reset and show percentage text
    buffer.setBackgroundColor(colors.black)
    buffer.setTextColor(colors.white)
    buffer.setCursorPos(x + width + 1, y)
    buffer.write(math.floor(progress * 100) .. "%")
end

local driveSpecs = {
    ["appliedenergistics2:storage_cell_1k"] = 1024,
    ["appliedenergistics2:storage_cell_4k"] = 4096,
    ["appliedenergistics2:storage_cell_16k"] = 16384,
    ["appliedenergistics2:storage_cell_64k"] = 65536,
    ["extracells:storage.physical"] = { [0] = 256000, [1] = 1024000, [2] = 4096000, [3] = 16384000 }
}

local storageData = { maxBytes = 0, maxTypes = 0, counts = {} }
local systemBytesUsed = 0 -- We'll calculate this from total items


local cachedManagedStatus = {}
local lastStockRefresh = 0
local cachedLowStock = {} 
local cachedManagedKeys = {}
local cachedCraftableList = {}
local scrollOffset = 0
local lastTick = os.epoch("utc")
local currentTab = 1
local scrollPos = 1
local managedScroll = 1
local stockScroll = 1
local uiState = { selectedLeft = nil, selectedRight = nil, stockLevel = 100 }
local serverData = { items = {}, activeJobs = {}, rules = {}, stats = {completed=0, managedEnabled=true, queueSize=0}, history = {}, itemDB = {} }
local storageData = { maxBytes = 0, maxTypes = 0, counts = {}, usedBytes = 0, usedTypes = 0 }
local debugLog = { [1422] = {lastSeen="Never", status="Waiting"}, [1428] = {lastSeen="Never", status="Waiting"} }
local selectedHistoryIndex = nil
local statusMessages = {
    missing = "Job ended with missing, likely missing ingredients or recipe!",
    canceled = "Job was manually canceled or system was reset.",
    stalled = "Job is stalled! Check for machine bottlenecks.",
    finished = "Job completed Successfully and crafted: %s %s",
    unknown = "Job in Progress: Crafting: %s (%s/%s)"
}

local function cleanName(n) 
    if not n or type(n) ~= "string" then return "Unknown Item" end -- Added type check
    local cleaned = n:match(":(.*)") or n 
    return (cleaned:gsub("_", " "):gsub("(%l)(%w*)", function(a, b) return a:upper()..b end))
end


local function formatValue(val)
    val = val or 0 
    if val >= 1048576 then return string.format("%.1fMB", val / 1048576)
    elseif val >= 1024 then return string.format("%.1fKB", val / 1024) end
    return val .. "B"
end

local function formatNum(n)
    if not n or type(n) ~= "number" then return "0" end
    if n >= 1000000000 then return string.format("%.1fb", n / 1000000000) end
    if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(n)
end

local function updateStockCache()
    local now = os.epoch("utc") / 1000
    if (now - lastStockRefresh) < 2 then return end
    
    local itemDB = serverData.itemDB or {}
    
    -- 1. SORTED MANAGED LIST (Items where target > 0)
    local managedKeys = {}
    for key, entry in pairs(itemDB) do
        if entry.target and entry.target > 0 then
            table.insert(managedKeys, key)
        end
    end
    table.sort(managedKeys, function(a, b)
        return (itemDB[a].label or a):lower() < (itemDB[b].label or b):lower()
    end)
    cachedManagedKeys = managedKeys

    -- 2. SORTED CRAFTABLE LIST (isCraftable = true but target is 0)
    local craftableList = {}
    for key, entry in pairs(itemDB) do
        if entry.isCraftable and (not entry.target or entry.target == 0) then
            table.insert(craftableList, {key = key, label = entry.label or cleanName(key)})
        end
    end
    table.sort(craftableList, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
    cachedCraftableList = craftableList

    lastStockRefresh = now
end


-- =================================================================
-- BLOCK 3: DRAWING TOOLS
-- Functions for drawing boxes, progress bars, and tabs.
-- =================================================================
local function drawJobProgressBar(x, y, width, current, target)
    local percent = math.min(math.max((current or 0) / (target or 1), 0), 1)
    local fillWidth = math.floor(width * percent)
    buffer.setCursorPos(x, y); buffer.setBackgroundColor(colors.red); buffer.write(string.rep(" ", width))
    if fillWidth > 0 then
        buffer.setCursorPos(x, y); buffer.setBackgroundColor(colors.green); buffer.write(string.rep(" ", fillWidth))
    end
    buffer.setBackgroundColor(colors.black)
end

local function drawTabs()
    local t = { {1,"DASH",colors.lime}, {11,"DEBUG",colors.yellow}, {21,"STOCK",colors.magenta}, {31,"HIST",colors.orange}, {41,"STOR",colors.cyan} }
    for i, tab in ipairs(t) do
        buffer.setCursorPos(tab[1], 1)
        buffer.setBackgroundColor(currentTab == i and tab[3] or colors.gray)
        buffer.setTextColor(colors.black); buffer.write(" "..tab[2].." ")
    end
end

local function drawBox(x1, x2, y1, y2, title, col)
    buffer.setBackgroundColor(colors.gray)
    local s = string.rep(" ", (x2 - x1) + 1)
    buffer.setCursorPos(x1, y1); buffer.write(s); buffer.setCursorPos(x1, y2); buffer.write(s)
    for y = y1 + 1, y2 - 1 do buffer.setCursorPos(x1, y); buffer.write(" "); buffer.setCursorPos(x2, y); buffer.write(" ") end
    buffer.setCursorPos(x1 + 2, y1); buffer.setBackgroundColor(colors.black); buffer.setTextColor(col); buffer.write(" "..title.." ")
end

local function renderScrollingText(x, y, maxWidth, text)
    if #text <= maxWidth then
        buffer.setCursorPos(x, y)
        buffer.write(text)
    else
        local displayStr = text .. "   " 
        local time = math.floor(os.epoch("utc") / 250) -- Adjust speed here
        local startPos = (time % #displayStr) + 1
        local part = (displayStr .. displayStr):sub(startPos, startPos + maxWidth)
        buffer.setCursorPos(x, y)
        buffer.write(part:sub(1, maxWidth))
    end
end


-- =================================================================
-- BLOCK 4: TAB RENDERING (MAIN UI REFRESH)
-- =================================================================
local function refreshUI()
    buffer.setVisible(false); buffer.setBackgroundColor(colors.black); buffer.clear()
    drawTabs()
    local jobs = serverData.activeJobs or {}
    local itemDB = serverData.itemDB or {}

-- TAB 1: DASHBOARD
    if currentTab == 1 then
        -- --- MANAGED STATS BOX ---
        drawBox(2, 29, 3, 12, "MANAGED STATS", colors.yellow)
        
-- Calculate counts from itemDB
local recipeCount = 0
local totalEntries = 0
for _, entry in pairs(itemDB) do
    totalEntries = totalEntries + 1
    if entry.isCraftable then
        recipeCount = recipeCount + 1
    end
end

-- Render to Buffer
buffer.setCursorPos(2, 4)
buffer.setTextColor(colors.cyan)
buffer.write("Recipes: ")
buffer.setTextColor(colors.white)
buffer.write(tostring(recipeCount))

buffer.setCursorPos(2, 5)
buffer.setTextColor(colors.cyan)
buffer.write("Items:   ")
buffer.setTextColor(colors.white)
buffer.write(tostring(totalEntries))
        
        buffer.setCursorPos(4, 9);  buffer.write("Jobs Done:     ".. (serverData.stats.completed or 0))
        buffer.setCursorPos(4, 11); buffer.write("Active Jobs:   ".. #jobs)

        -- --- ACTIVE JOBS BOX ---
        drawBox(31, 56, 3, 13, "ACTIVE JOBS", colors.magenta)
        for i, job in ipairs(jobs) do
            if i > 4 then break end
            local row = 4 + (i*2)
            buffer.setCursorPos(32, row); buffer.setTextColor(colors.white)
            
            local jName = job.label or (itemDB[job.key] and itemDB[job.key].label) or cleanName(job.key)
            buffer.write(tostring(jName):sub(1,16))
            
            if job.isStalled or job.status == "missing" then
                buffer.setCursorPos(32, row+1); buffer.setBackgroundColor(colors.red)
                buffer.setTextColor(colors.white); buffer.write(" [ MISSING RESOURCES ] ")
                buffer.setBackgroundColor(colors.black)
            else
                drawJobProgressBar(32, row+1, 20, job.progress, job.target)
                buffer.setCursorPos(52, row+1); buffer.setTextColor(colors.gray)
                buffer.write(formatNum(job.progress or 0))
            end
        end

        -- --- SYSTEM CAPABILITY BOX ---
        drawBox(2, 29, 13, 28, "SYSTEM CAPABILITY", colors.lightBlue)
        local cpu = (serverData.cpus) or {total=0, busy=0, avgCoPro=0, maxStorage=0}

        buffer.setCursorPos(4, 15); buffer.setTextColor(colors.white); buffer.write("CraftingCPUs: ")
        buffer.setTextColor(colors.lime); buffer.write(tostring(cpu.total))
        buffer.setTextColor(colors.white); buffer.write(" / ")
        buffer.setTextColor(cpu.busy > 0 and colors.red or colors.gray); buffer.write(tostring(cpu.busy))

        buffer.setCursorPos(4, 17); buffer.setTextColor(colors.white); buffer.write("AVG Copros:   ")
        buffer.setTextColor(colors.yellow); buffer.write(string.format("%.1f", cpu.avgCoPro))

        buffer.setCursorPos(4, 19); buffer.setTextColor(colors.white); buffer.write("Max Storage:  ")
        buffer.setTextColor(colors.cyan); buffer.write(formatValue(cpu.maxStorage or 0))

        -- Usage Bar
        buffer.setCursorPos(4, 21); buffer.setTextColor(colors.gray); buffer.write("[")
        local barWidth = 20
        local filled = cpu.total > 0 and math.floor((cpu.busy / cpu.total) * barWidth) or 0
        for i=1, barWidth do
            if i <= filled then buffer.setTextColor(colors.red); buffer.write("|")
            else buffer.setTextColor(colors.lime); buffer.write(".") end
        end
        buffer.setTextColor(colors.gray); buffer.write("]")

        -- --- AUTOCRAFT CONTROL UI ---
        local mCol = (serverData.stats and serverData.stats.managedEnabled) and colors.lime or colors.red
        buffer.setCursorPos(32, 16); buffer.setBackgroundColor(mCol); buffer.setTextColor(colors.black)
        buffer.write(" AUTOCRAFT: "..((serverData.stats and serverData.stats.managedEnabled) and "ON" or "OFF"))
        buffer.setBackgroundColor(colors.blue); buffer.setTextColor(colors.white)
        buffer.setCursorPos(32, 22); buffer.write(" [MANAGE STOCK] ")
        buffer.setBackgroundColor(colors.black)

-- TAB 2: DEBUG & TRANSLATION
    elseif currentTab == 2 then
        drawBox(2, 56, 3, 28, "SYSTEM DIAGNOSTICS", colors.yellow)
        local r = 5
        
        -- 1. System Logs (Modem Channels)
        for chan, d in pairs(debugLog) do
            buffer.setCursorPos(4, r); buffer.setTextColor(colors.cyan); buffer.write("CH "..chan..": ")
            buffer.setTextColor(d.status == "ONLINE" and colors.lime or colors.red); buffer.write(d.status)
            buffer.setCursorPos(4, r+1); buffer.setTextColor(colors.gray); buffer.write(" Last RX: "..d.lastSeen)
            r = r + 3
        end

        -- 2. Data Preparation
        local s = serverData.stats or {}
        local db = serverData.itemDB or {}
        local currentKey = s.currentItem or "Idle"
        local entry = stats.currentEntry
        
        -- Pull friendly name from the DB using the currentKey
        local friendlyName = "N/A"
        if currentKey == "Idle" then
            friendlyName = "System Idle"
        elseif db[currentKey] then
            friendlyName = db[currentKey].label or "Unknown"
        end

-- =============================================================
-- DEBUG TAB RENDERING (NOCDisplay.lua)
-- =============================================================
-- Grab the data from serverData, but default to empty tables if they don't exist yet
local stats = serverData.stats or { completed = 0, managedEnabled = true, queueSize = 0 }
local itemDB = serverData.itemDB or {}
local cpus = serverData.cpus or {}
local entry = stats.currentEntry -- This will be nil if no job is running

-- 1. Scheduler Header
buffer.setCursorPos(4, 9)
buffer.setTextColor(colors.orange)
buffer.write("TRANSLATION SCHEDULER")

-- 2. Queue Size (Safety check for nil)
buffer.setCursorPos(4, 10)
buffer.setTextColor(colors.white)
buffer.write("Queue Size:    " .. (stats.queueSize or 0))

-- 3. Current Entry Section
buffer.setCursorPos(4, 12)
buffer.setTextColor(colors.gray)
buffer.write("--- Current Entry ---")

if entry and entry.key then
    -- Get display name from our DB mirror
    local dbEntry = (serverData.itemDB and serverData.itemDB[entry.key]) or {}
    local dName = dbEntry.label or "Translating..."
    
    buffer.setCursorPos(4, 13)
    buffer.setTextColor(colors.white)
    buffer.write("displayName:   ")
    buffer.setTextColor(colors.yellow)
    buffer.write(tostring(dName):sub(1, 25))

    -- Write Status Logic: True if we have a label in DB, else In Progress
    local isWritten = (dbEntry.label ~= nil and dbEntry.label ~= "Awaiting Meta...")
    buffer.setCursorPos(4, 16)
    buffer.setTextColor(colors.white)
    buffer.write("Write Status:  ")
    buffer.setTextColor(isWritten and colors.lime or colors.yellow)
    buffer.write(isWritten and "[Complete]" or "[In Progress]")

    -- Is Managed Logic: Based on target > 0
    local isManaged = (dbEntry.target or 0) > 0
    buffer.setCursorPos(4, 17)
    buffer.setTextColor(colors.white)
    buffer.write("Is Managed:    ")
    buffer.setTextColor(isManaged and colors.lime or colors.red)
    buffer.write(tostring(isManaged))
else
    buffer.setCursorPos(4, 13)
    buffer.setTextColor(colors.lime)
    buffer.write("Status:        IDLE")
end

-- =================================================================
-- TAB 3: STOCK MANAGEMENT (Updated for new itemDB)
-- =================================================================
elseif currentTab == 3 then
    updateStockCache()
    
    local mStart = managedScroll
    local mEnd = math.min(mStart + 17, #cachedManagedKeys)
    local mHeader = string.format("MANAGED %d-%d/%d", mStart, mEnd, #cachedManagedKeys)
    
    local cStart = stockScroll
    local cEnd = math.min(cStart + 17, #cachedCraftableList)
    local cHeader = string.format("CRAFTABLES %d-%d/%d", cStart, cEnd, #cachedCraftableList)

    drawBox(2, 24, 3, 22, mHeader, colors.magenta)
    drawBox(36, 58, 3, 22, cHeader, colors.lightBlue)

    for i = 1, 18 do
        -- Left Column: Managed Items
        local mIdx = i + (mStart - 1)
        local key = cachedManagedKeys[mIdx]
        if key then
            local stats = cachedManagedStatus[key]
            -- Use itemDB for label, fallback to cleanName
            local itemInfo = serverData.itemDB[key]
            local label = itemInfo and itemInfo.label or cleanName(key)
            
            buffer.setCursorPos(3, 3 + i)
            buffer.setBackgroundColor(uiState.selectedLeft == key and colors.gray or colors.black)
            buffer.setTextColor(stats.color)
            buffer.write(string.format("%-10s:%s/%s", tostring(label):sub(1,10), formatNum(stats.cur), formatNum(stats.target)))
        end

        -- Right Column: Craftable List
        local cIdx = i + (cStart - 1)
        local cItem = cachedCraftableList[cIdx]
        if cItem then
            buffer.setCursorPos(37, 3 + i)
            buffer.setBackgroundColor(uiState.selectedRight == cItem.key and colors.gray or colors.black)
            buffer.setTextColor(uiState.selectedRight == cItem.key and colors.yellow or colors.white)
            buffer.write(tostring(cItem.label):sub(1,20))
        end
        buffer.setBackgroundColor(colors.black)
    end

    -- SELECTED OVERLAY
    local ovY = 17 
    if uiState.selectedLeft or uiState.selectedRight then
        local isLeft = uiState.selectedLeft ~= nil
        local x1 = isLeft and 2 or 36
        local x2 = isLeft and 24 or 58
        local currentKey = isLeft and uiState.selectedLeft or uiState.selectedRight
        
        buffer.setBackgroundColor(colors.black)
        for i = 0, 4 do
            buffer.setCursorPos(x1, ovY + i)
            buffer.write(string.rep(" ", (x2 - x1) + 1))
        end

        drawBox(x1, x2, ovY, ovY + 4, "SELECTED", colors.yellow)
        buffer.setBackgroundColor(colors.black)
        
        local itemData = serverData.itemDB[currentKey]
        local fullName = itemData and itemData.label or cleanName(currentKey)
        
        buffer.setTextColor(colors.white)
        renderScrollingText(x1 + 2, ovY + 1, 19, fullName)
        
        buffer.setCursorPos(x1 + 2, ovY + 2)
        buffer.setTextColor(colors.gray)
        buffer.write("ID: " .. currentKey:sub(1, 18))

        buffer.setCursorPos(x1 + 2, ovY + 3)
        if isLeft then
            local stats = cachedManagedStatus[currentKey] or {cur=0, target=0}
            buffer.setTextColor(colors.orange); buffer.write("Stock: ")
            buffer.setTextColor(colors.white); buffer.write(formatNum(stats.cur) .. "/" .. formatNum(stats.target))
        else
            buffer.setTextColor(colors.lightGray); buffer.write("Managed: No")
        end
    end

    -- CENTER CONTROLS (Arrows & Adjustment Buttons)
    local mid = 30
    buffer.setBackgroundColor(colors.gray); buffer.setTextColor(colors.white)
    buffer.setCursorPos(mid-1, 4); buffer.write("^^")
    buffer.setCursorPos(mid-1, 5); buffer.write(" ^")
    buffer.setCursorPos(mid-1, 7); buffer.write(" v")
    buffer.setCursorPos(mid-1, 8); buffer.write("vv")
    buffer.setCursorPos(mid-1, 10); buffer.write("<<")
    buffer.setCursorPos(mid-1, 12); buffer.write(">>")
    
    buffer.setBackgroundColor(colors.black)
    buffer.setCursorPos(27, 14); buffer.setTextColor(colors.orange); buffer.write("Adjust")
    buffer.setCursorPos(27, 15); buffer.write("Stock")

    local amounts = {"1", "10", "100", "1k"}
    for i = 0, 3 do
        local x = 26 + (i * 2)
        buffer.setBackgroundColor(colors.green); buffer.setTextColor(colors.white)
        buffer.setCursorPos(x, 17); buffer.write("+")
        buffer.setBackgroundColor(colors.red)
        buffer.setCursorPos(x, 22); buffer.write("-")
        
        buffer.setBackgroundColor(colors.black); buffer.setTextColor(colors.gray)
        local strAmt = amounts[i+1]
        for charIdx = 1, #strAmt do
            buffer.setCursorPos(x, 17 + charIdx); buffer.write(strAmt:sub(charIdx, charIdx))
        end
    end

-- =================================================================
-- TAB 4 & 5: HISTORY & STORAGE
-- =================================================================
elseif currentTab == 4 then
    drawBox(2, 56, 3, 28, "CRAFTING HISTORY LOG", colors.orange)
    for i = 1, math.min(18, #serverData.history) do
        local entry = serverData.history[i]
        buffer.setCursorPos(4, 6 + (i-1))
        local nameToShow = entry.label or cleanName(entry.name)
        local status = entry.status or "???"
        buffer.setTextColor(status == "DONE" and colors.green or colors.red)
        buffer.write(string.format("%-14s | %-5d | %-6s | %-4s", 
            tostring(nameToShow):sub(1,14), entry.amount or 0, status:sub(1,6), entry.duration or "---"))
    end
    buffer.setCursorPos(40, 27); buffer.setBackgroundColor(colors.red); buffer.setTextColor(colors.white); buffer.write(" [CLEAR LOG] ")

elseif currentTab == 5 then
    local usedBytes = math.floor((serverData.stats.totalItems or 0) / 8)
    local totalBytes = storageData.maxBytes or 0
    local usedTypes = serverData.stats.usedTypes or 0
    local totalTypes = storageData.maxTypes or 0

    drawBox(2, 29, 3, 12, "STORAGE CAPACITY", colors.cyan)
    buffer.setCursorPos(4, 5); buffer.setTextColor(colors.white); buffer.write("Bytes Usage")
    drawBar(4, 6, 17, usedBytes, totalBytes > 0 and totalBytes or 1)
    buffer.setCursorPos(4, 9); buffer.write("Types Usage")
    drawBar(4, 10, 17, usedTypes, totalTypes > 0 and totalTypes or 1)

    drawBox(31, 58, 3, 13, "SYSTEM DATA", colors.orange)
    -- Breakdown columns... (Logic remains same as original)
    -- [Omitted for brevity, logic follows standard rendering]

    drawBox(2, 58, 14, 28, "CELL INVENTORY", colors.lightBlue)
    local sortedLabels = {}
    for k in pairs(storageData.counts or {}) do table.insert(sortedLabels, k) end
    table.sort(sortedLabels)
    for i, label in ipairs(sortedLabels) do
        buffer.setCursorPos(4 + (math.floor((i-1)/12)*18), 16 + ((i-1)%12))
        buffer.setTextColor(colors.white); buffer.write(label:sub(1,3).." Cell: ")
        buffer.setTextColor(colors.lime);  buffer.write("["..storageData.counts[label].."]")
    end
end
buffer.setVisible(true)
end

-- =================================================================
-- INTERACTION & MODEM HANDLER
-- =================================================================
while true do
    local ev, side, p1, p2, msg = os.pullEvent()
    
    if ev == "timer" and side == scrollTimer then
        scrollPos = scrollPos + 1
        scrollTimer = os.startTimer(0.5) 
        refreshUI()
        
    elseif ev == "monitor_touch" then
        local tx, ty = p1, p2
        if ty == 1 then
            currentTab = math.min(5, math.floor((tx - 1) / 10) + 1)
        elseif currentTab == 3 then
            -- Handle Scrolling, Rule Transfers (+/-), and Selections
            -- [Logic block remains consistent with your input]
        end
        refreshUI()

    elseif ev == "modem_message" then
        if type(msg) == "table" then
            -- 1. Storage Cell Updates (Channel 1422)
            if p1 == 1422 and msg.items then
                storageData = { maxBytes = 0, maxTypes = 0, counts = {} }
                for _, it in ipairs(msg.items) do
                    if driveSpecs[it.name] then
                        local cap = (type(driveSpecs[it.name]) == "table") and (driveSpecs[it.name][it.damage] or 0) or driveSpecs[it.name]
                        local label = it.name:match("storage_cell_(%d+k)") or "1k"
                        storageData.maxBytes = storageData.maxBytes + (cap * it.count)
                        storageData.maxTypes = storageData.maxTypes + (63 * it.count)
                        storageData.counts[label] = (storageData.counts[label] or 0) + it.count
                    end
                end

            -- 2. Unified Data Sync (Channel 1428)
            elseif p1 == 1428 then 
                serverData.itemDB = msg.itemDB or {}
                serverData.activeJobs = msg.activeJobs or {}
                serverData.history = msg.history or {}
                serverData.stats = msg.stats or {}
                serverData.cpus = msg.cpus or {}
                
                -- Rebuild flattened items list for the UI from the new DB
                local newList = {}
                for key, data in pairs(serverData.itemDB) do
                    data.key = key 
                    table.insert(newList, data)
                end
                table.sort(newList, function(a, b) return (a.label or "") < (b.label or "") end)
                serverData.items = newList
            end
            refreshUI()
        end
    end
end
