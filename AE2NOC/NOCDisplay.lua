-- =================================================================
-- BLOCK 1: UI INITIALIZATION
-- Sets up the monitor, buffer, and wireless modem.
-- =================================================================
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem", function(_, p) return p.isWireless() end) 
    or error("No Wireless Modem Found")

local debugLog = {
    [1422] = {lastSeen = "Never", status = "Waiting"},
    [1428] = {lastSeen = "Never", status = "Waiting"},
    [1429] = {lastSeen = "Never", status = "Waiting"}
}

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
    lastStockRefresh = now
    
    local itemDB = serverData.itemDB or {}
    local managedKeys = {}
    local craftableList = {}
    
    -- 1. Categorize items
    for key, entry in pairs(itemDB) do
        local label = entry.label or cleanName(key)
        
        if entry.target and entry.target > 0 then
            -- Only in Managed
            table.insert(managedKeys, key)
        elseif entry.isCraftable then
            -- Only in Craftable if NOT managed
            table.insert(craftableList, {key = key, label = label})
        end
    end
    
    -- 2. Sort Managed Keys (Alphabetical)
    table.sort(managedKeys, function(a, b)
        return (itemDB[a].label or a):lower() < (itemDB[b].label or b):lower()
    end)
    
    -- 3. Sort Craftable List (Alphabetical)
    table.sort(craftableList, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
    
    cachedManagedKeys = managedKeys
    cachedCraftableList = craftableList
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

local function renderDashboard()
    local jobs = serverData.activeJobs or {}
    local itemDB = serverData.itemDB or {}

    -- MANAGED STATS
    drawBox(2, 29, 3, 12, "MANAGED STATS", colors.yellow)
    local recipeCount, totalEntries = 0, 0
    for _, entry in pairs(itemDB) do
        totalEntries = totalEntries + 1
        if entry.isCraftable then recipeCount = recipeCount + 1 end
    end

    buffer.setCursorPos(4, 5); buffer.setTextColor(colors.cyan); buffer.write("Recipes: ")
    buffer.setTextColor(colors.white); buffer.write(tostring(recipeCount))
    buffer.setCursorPos(4, 6); buffer.setTextColor(colors.cyan); buffer.write("Items:   ")
    buffer.setTextColor(colors.white); buffer.write(tostring(totalEntries))
    buffer.setCursorPos(4, 9); buffer.setTextColor(colors.white); buffer.write("Jobs Done:   ".. (serverData.stats.completed or 0))
    buffer.setCursorPos(4, 11); buffer.write("Active Jobs: ".. #jobs)

    -- ACTIVE JOBS
    drawBox(31, 56, 3, 13, "ACTIVE JOBS", colors.magenta)
    for i, job in ipairs(jobs) do
        if i > 4 then break end
        local row = 4 + (i*2)
        local jName = job.label or (itemDB[job.key] and itemDB[job.key].label) or cleanName(job.key)
        buffer.setCursorPos(32, row); buffer.setTextColor(colors.white); buffer.write(tostring(jName):sub(1,16))
        
        if job.isStalled or job.status == "missing" then
            buffer.setCursorPos(32, row+1); buffer.setBackgroundColor(colors.red); buffer.write(" [ MISSING RESOURCES ] "); buffer.setBackgroundColor(colors.black)
        else
            drawJobProgressBar(32, row+1, 20, job.progress, job.target)
            buffer.setCursorPos(52, row+1); buffer.setTextColor(colors.gray); buffer.write(formatNum(job.progress or 0))
        end
    end

    -- SYSTEM CAPABILITY
    drawBox(2, 29, 13, 28, "SYSTEM CAPABILITY", colors.lightBlue)
    local cpu = serverData.cpus or {total=0, busy=0, avgCoPro=0, maxStorage=0}
    buffer.setCursorPos(4, 15); buffer.write("CraftingCPUs: "); buffer.setTextColor(colors.lime); buffer.write(tostring(cpu.total))
    buffer.setCursorPos(4, 17); buffer.setTextColor(colors.white); buffer.write("AVG Copros:   "); buffer.setTextColor(colors.yellow); buffer.write(string.format("%.1f", cpu.avgCoPro))
    buffer.setCursorPos(4, 19); buffer.write("Max Storage:  "); buffer.setTextColor(colors.cyan); buffer.write(formatValue(cpu.maxStorage or 0))

    -- CPU Usage Bar
    buffer.setCursorPos(4, 21); buffer.setTextColor(colors.gray); buffer.write("[")
    local filled = cpu.total > 0 and math.floor((cpu.busy / cpu.total) * 20) or 0
    for i=1, 20 do buffer.setTextColor(i <= filled and colors.red or colors.lime); buffer.write(i <= filled and "|" or ".") end
    buffer.write("]")
end

local function renderDebug()
    local stats = serverData.stats or { queueSize = 0, currentEntry = {} }
    local itemDB = serverData.itemDB or {}
    local entry = stats.currentEntry

    -- WINDOW 1: NETWORK STATUS
    drawBox(2, 58, 3, 10, "MODEM NETWORK STATUS", colors.yellow)
    local channels = {1422, 1428, 1429}
local labels = {
    [1422] = "Cell Sync",    -- External storage cell reader
    [1428] = "System Data",  -- Main server broadcast (CPUs, Items, Jobs)
    [1429] = "Command Bus"   -- Your UI-to-Server instructions
}
    
    for i, chan in ipairs(channels) do
        local log = debugLog[chan] or {lastSeen="Never", status="Waiting"}
        local yPos = 4 + i
        buffer.setCursorPos(4, yPos)
        buffer.setTextColor(colors.cyan); buffer.write(string.format("%-12s", labels[chan]))
        buffer.setTextColor(colors.white); buffer.write(" | Rx: ")
        
        -- Color code status
        local statCol = log.status == "Active" and colors.lime or colors.red
        buffer.setTextColor(statCol); buffer.write(string.format("%-8s", log.lastSeen))
        buffer.setTextColor(colors.gray); buffer.write(" ["..log.status.."]")
    end

    -- WINDOW 2: TRANSLATION SCHEDULER
    drawBox(2, 58, 12, 28, "TRANSLATION SCHEDULER", colors.orange)
    buffer.setCursorPos(4, 14)
    buffer.setTextColor(colors.white); buffer.write("Queue Size: ")
    buffer.setTextColor(colors.yellow); buffer.write(tostring(stats.queueSize or 0))

    if entry and entry.key then
        local dbEntry = itemDB[entry.key] or {}
        
        buffer.setCursorPos(4, 16); buffer.setTextColor(colors.gray); buffer.write("--- Current Entry ---")
        
        -- Item Display Name
        buffer.setCursorPos(4, 18); buffer.setTextColor(colors.white); buffer.write("Item:    ")
        buffer.setTextColor(colors.lime); buffer.write(tostring(dbEntry.label or "Awaiting Meta..."):sub(1, 35))
        
        -- Raw Technical Name (OldName)
        buffer.setCursorPos(4, 20); buffer.setTextColor(colors.white); buffer.write("OldName: ")
        buffer.setTextColor(colors.gray); buffer.write(tostring(entry.key):sub(1, 35))
        
        -- Write Status Logic
        local isWritten = (dbEntry.label ~= nil and dbEntry.label ~= "Awaiting Meta...")
        buffer.setCursorPos(4, 23); buffer.setTextColor(colors.white); buffer.write("Write Status: ")
        if isWritten then
            buffer.setTextColor(colors.lime); buffer.write("[COMPLETE]")
        else
            buffer.setTextColor(colors.yellow); buffer.write("[IN PROGRESS...]")
        end
    else
        buffer.setCursorPos(4, 18); buffer.setTextColor(colors.lime); buffer.write("Status:  IDLE (All items translated)")
    end
end

local function renderStockControl()
    updateStockCache()
    
    -- Determine visible range based on whether an overlay is open
    local maxVisible = (uiState.selectedLeft or uiState.selectedRight) and 13 or 18
    
    local mStart = math.max(1, math.min(managedScroll, #cachedManagedKeys - maxVisible + 1))
    local mEnd = math.min(mStart + maxVisible - 1, #cachedManagedKeys)
    local mHeader = string.format("MANAGED %d-%d/%d", mStart, mEnd, #cachedManagedKeys)

    local cStart = math.max(1, math.min(stockScroll, #cachedCraftableList - maxVisible + 1))
    local cEnd = math.min(cStart + maxVisible - 1, #cachedCraftableList)
    local cHeader = string.format("CRAFTABLE %d-%d/%d", cStart, cEnd, #cachedCraftableList)

    drawBox(2, 24, 3, 22, mHeader, colors.magenta)
    drawBox(36, 58, 3, 22, cHeader, colors.lightBlue)

    -- List Rendering
    for i = 1, maxVisible do
        -- Left: Managed
        local mKey = cachedManagedKeys[i + (mStart - 1)]
        if mKey then
            local entry = serverData.itemDB[mKey]
            buffer.setCursorPos(3, 3 + i)
            buffer.setBackgroundColor(uiState.selectedLeft == mKey and colors.gray or colors.black)
            
            local textColor = colors.white
            if entry.isCrafting then textColor = colors.yellow 
            elseif (entry.count or 0) < (entry.target or 0) then textColor = colors.red 
            else textColor = colors.lime end
            
            buffer.setTextColor(textColor)
            buffer.write(string.format("%-10s:%s/%s", tostring(entry.label or "??"):sub(1,10), formatNum(entry.count or 0), formatNum(entry.target or 0)))
        end

        -- Right: Craftable
        local cItem = cachedCraftableList[i + (cStart - 1)]
        if cItem then
            buffer.setCursorPos(37, 3 + i)
            buffer.setBackgroundColor(uiState.selectedRight == cItem.key and colors.gray or colors.black)
            buffer.setTextColor(uiState.selectedRight == cItem.key and colors.yellow or colors.white)
            buffer.write(tostring(cItem.label):sub(1,20))
        end
    end

    -- Compressed Selection Overlay
-- Inside renderStockControl()
if uiState.selectedLeft or uiState.selectedRight then
    local isL = uiState.selectedLeft ~= nil
    local x1, x2 = isL and 2 or 36, isL and 24 or 58
    local k = isL and uiState.selectedLeft or uiState.selectedRight
    local entry = serverData.itemDB[k] or {}

    -- Box moved down to start at Y=18
    drawBox(x1, x2, 18, 22, "SELECTED", colors.yellow)
    buffer.setBackgroundColor(colors.black)
    
    -- Line 19: Name (Static Label)
    buffer.setCursorPos(x1+1, 19)
    buffer.setTextColor(colors.gray)
    buffer.write("Name: ") 
    buffer.setTextColor(colors.white)
    -- Scrolling starts AFTER "Name: " (x1 + 7)
    renderScrollingText(x1+7, 19, (x2-x1)-7, entry.label or cleanName(k))
    
    -- Line 20: ID (Static Label)
    buffer.setCursorPos(x1+1, 20)
    buffer.setTextColor(colors.gray)
    buffer.write("ID: ")
    buffer.setTextColor(colors.white)
    buffer.write(k:sub(1, (x2-x1)-5))
    
    -- Line 21: Stock
    buffer.setCursorPos(x1+1, 21)
    buffer.setTextColor(colors.orange)
    buffer.write("Stock: ")
    buffer.setTextColor(colors.white)
    buffer.write(tostring(entry.count or 0))
    
    -- Line 22: Target
    buffer.setCursorPos(x1+1, 22)
    buffer.setTextColor(colors.lightBlue)
    buffer.write("Target: ")
    buffer.setTextColor(colors.white)
    buffer.write(tostring(entry.target or 0))
    end

    -- Center Controls
    local mid = 30
    buffer.setBackgroundColor(colors.gray); buffer.setTextColor(colors.white)
    buffer.setCursorPos(mid-1, 4); buffer.write("^^") -- +15
    buffer.setCursorPos(mid-1, 5); buffer.write(" ^") -- +3
    buffer.setCursorPos(mid-1, 7); buffer.write(" v") -- -3
    buffer.setCursorPos(mid-1, 8); buffer.write("vv") -- -15
    
    -- Transfer Buttons
    buffer.setBackgroundColor(colors.blue)
    buffer.setCursorPos(mid-1, 10); buffer.write("<<") -- Add to Managed
    buffer.setCursorPos(mid-1, 12); buffer.write(">>") -- Remove from Managed

    -- Plus/Minus Buttons (Standard Logic)
-- Adjustment Grid Rendering
local amounts = {"1", "10", "100", "1k"}
for i=0, 3 do
    local x = 26 + (i*2)
    -- Buttons
    buffer.setBackgroundColor(colors.green); buffer.setCursorPos(x, 17); buffer.write("+")
    buffer.setBackgroundColor(colors.red);   buffer.setCursorPos(x, 22); buffer.write("-")
    
    -- Labels (placed at 18, 19, 20, 21)
    buffer.setBackgroundColor(colors.black); buffer.setTextColor(colors.gray)
    local str = amounts[i+1]
    for charIdx = 1, #str do
        buffer.setCursorPos(x, 17 + charIdx) 
        buffer.write(str:sub(charIdx, charIdx))
    end
end
end

local function renderHistory()
    drawBox(2, 56, 3, 28, "CRAFTING HISTORY LOG", colors.orange)
    for i = 1, math.min(18, #serverData.history) do
        local e = serverData.history[i]
        buffer.setCursorPos(4, 6 + (i-1))
        buffer.setTextColor(e.status == "DONE" and colors.green or colors.red)
        buffer.write(string.format("%-14s | %-5d | %-6s | %-4s", tostring(e.label or cleanName(e.name)):sub(1,14), e.amount or 0, (e.status or "???"):sub(1,6), e.duration or "---"))
    end
    buffer.setCursorPos(40, 27); buffer.setBackgroundColor(colors.red); buffer.setTextColor(colors.white); buffer.write(" [CLEAR LOG] ")
end

local function renderStorage()
    local usedBytes = math.floor((serverData.stats.totalItems or 0) / 8)
    local totalBytes = storageData.maxBytes or 0
    drawBox(2, 29, 3, 12, "STORAGE CAPACITY", colors.cyan)
    buffer.setCursorPos(4, 5); buffer.setTextColor(colors.white); buffer.write("Bytes Usage")
    drawBar(4, 6, 17, usedBytes, totalBytes > 0 and totalBytes or 1)
    
    drawBox(2, 58, 14, 28, "CELL INVENTORY", colors.lightBlue)
    local sorted = {}
    for k in pairs(storageData.counts or {}) do table.insert(sorted, k) end
    table.sort(sorted)
    for i, label in ipairs(sorted) do
        buffer.setCursorPos(4 + (math.floor((i-1)/12)*18), 16 + ((i-1)%12))
        buffer.setTextColor(colors.white); buffer.write(label:sub(1,3).." Cell: ")
        buffer.setTextColor(colors.lime);  buffer.write("["..storageData.counts[label].."]")
    end
end

local function refreshUI()
    buffer.setVisible(false)
    buffer.setBackgroundColor(colors.black)
    buffer.clear()
    drawTabs()

    if currentTab == 1 then renderDashboard()
    elseif currentTab == 2 then renderDebug()
    elseif currentTab == 3 then renderStockControl()
    elseif currentTab == 4 then renderHistory()
    elseif currentTab == 5 then renderStorage()
    end
    buffer.setVisible(true)
end

-- =================================================================
-- BLOCK 5: INPUT & LOGIC HELPERS
-- =================================================================

local function adjustStock(itemKey, amount)
    if not itemKey or not serverData.itemDB[itemKey] then return end

    -- 1. Calculate the new final target
    local currentTarget = serverData.itemDB[itemKey].target or 0
    local newTarget = math.max(0, currentTarget + amount)

    -- 2. Update local UI immediately so it feels responsive
    serverData.itemDB[itemKey].target = newTarget

    -- 3. Transmit using the fields the Server actually checks (type and name)
    modem.transmit(1429, 1428, { 
        type = "SET_RULE", 
        name = itemKey, 
        target = newTarget 
    })
    
    -- Debug logging
    if debugLog[1429] then
        debugLog[1429].lastSeen = os.date("%H:%M:%S")
        debugLog[1429].status = "Sent SET_RULE"
    end
end

local function handleMouseClick(event, button, x, y)
    -- 1. TAB SWITCHING
    if y == 1 then
        currentTab = math.min(5, math.floor((x - 1) / 10) + 1)
        refreshUI()
        return
    end

    if currentTab == 3 then -- STOCK CONTROL
        -- SCROLLING LOGIC (Center Strip)
        if x >= 29 and x <= 31 then
            local scrollAmt = 0
            if y == 4 then scrollAmt = -15      -- ^^ (Page Up)
            elseif y == 5 then scrollAmt = -3   -- ^  (Up 3)
            elseif y == 7 then scrollAmt = 3    -- v  (Down 3)
            elseif y == 8 then scrollAmt = 15   -- vv (Page Down)
            end
            
            -- Apply scroll to the active side
            if uiState.selectedRight then
                stockScroll = math.max(1, stockScroll + scrollAmt)
            else
                managedScroll = math.max(1, managedScroll + scrollAmt)
            end
        end

        -- TRANSFER LOGIC (<< and >>)
        if x >= 29 and x <= 31 then
            if y == 10 and uiState.selectedRight then
                -- Move Craftable to Managed (Set target to 10)
                adjustStock(uiState.selectedRight, 10)
                uiState.selectedLeft = uiState.selectedRight
                uiState.selectedRight = nil
            elseif y == 12 and uiState.selectedLeft then
                -- Remove from Managed (Set target to 0)
                local currentTarget = serverData.itemDB[uiState.selectedLeft].target or 0
                adjustStock(uiState.selectedLeft, -currentTarget)
                uiState.selectedRight = uiState.selectedLeft
                uiState.selectedLeft = nil
            end
        end

        -- SELECTION LOGIC
        if y >= 4 and y <= 21 then
            if x >= 2 and x <= 24 then -- Managed Column
                local idx = (y - 3) + (managedScroll - 1)
                uiState.selectedLeft = cachedManagedKeys[idx]
                uiState.selectedRight = nil
            elseif x >= 36 and x <= 58 then -- Craftable Column
                local idx = (y - 3) + (stockScroll - 1)
                if cachedCraftableList[idx] then
                    uiState.selectedRight = cachedCraftableList[idx].key
                    uiState.selectedLeft = nil
                end
            end
        end

        -- ADJUSTMENT BUTTONS (+ / -)
        local activeKey = uiState.selectedLeft or uiState.selectedRight
        if activeKey and (y == 17 or y == 22) then
            local amounts = {1, 10, 100, 1000}
            for i = 0, 3 do
                if x == 26 + (i * 2) then
                    local change = (y == 17) and amounts[i+1] or -amounts[i+1]
                    adjustStock(activeKey, change)
                end
            end
        end
    end
    
    refreshUI()
end

-- =================================================================
-- BLOCK 6: MAIN EXECUTION LOOP
-- =================================================================

local scrollTimer = os.startTimer(0.5)
refreshUI()

while true do
    local eventData = {os.pullEvent()}
    local ev = eventData[1]
    
    if ev == "mouse_click" or ev == "monitor_touch" then
        handleMouseClick(unpack(eventData))
        
    elseif ev == "timer" and eventData[2] == scrollTimer then
        scrollPos = scrollPos + 1
        scrollTimer = os.startTimer(0.5) 
        refreshUI()
        
    elseif ev == "modem_message" then
        local p1, msg = eventData[3], eventData[5]
        if debugLog[p1] then
            debugLog[p1].lastSeen = os.date("%H:%M:%S")
            debugLog[p1].status = "Active"
        end
        if type(msg) == "table" then
            -- Storage Cell Updates
            if p1 == 1422 and msg.items then
                storageData = { maxBytes = 0, maxTypes = 0, counts = {} }
                for _, it in ipairs(msg.items) do
                    if driveSpecs[it.name] then
                        local cap = (type(driveSpecs[it.name]) == "table") and (driveSpecs[it.name][it.damage] or 0) or driveSpecs[it.name]
                        local label = it.name:match("storage_cell_(%d+k)") or "1k"
                        storageData.maxBytes = storageData.maxBytes + (cap * it.count)
                        storageData.counts[label] = (storageData.counts[label] or 0) + it.count
                    end
                end

            -- Unified Data Sync
            elseif p1 == 1428 then 
                serverData.itemDB = msg.itemDB or {}
                serverData.activeJobs = msg.activeJobs or {}
                serverData.history = msg.history or {}
                serverData.stats = msg.stats or {}
                serverData.cpus = msg.cpus or {}
                
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
