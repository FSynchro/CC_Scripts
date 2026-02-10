-- Thaumcraft Infusion Client v2.0
-- Monitor interface for recipe programming and status viewing

local CHANNEL = 1742

-- State
local monitor = peripheral.find("monitor")
local modem = peripheral.find("modem")
local currentTab = "status" -- "status", "programming", or "recipes"
local chestContents = {}
local selectedItems = {} -- {slot = {type = "catalyst"|"ingredient", matchNBT = bool, matchDMG = bool}}
local selectionMode = nil -- "catalyst" or "ingredient" (toggleable)
local recipes = {}
local turtles = {}
local altars = {}
local activeInfusions = {}
local errorMode = false
local errorMessage = ""
local scrollOffset = 0
local statusMessage = ""
local statusMessageTime = 0

if not monitor then
    error("No monitor found!")
end

if not modem then
    error("No modem found! Please attach an ender modem.")
end

modem.open(CHANNEL)

-- Monitor dimensions
local width, height = monitor.getSize()
monitor.setTextScale(0.5) -- Smaller text
width, height = monitor.getSize() -- Refresh size after scaling

-- Colors
local COLOR_BG = colors.black
local COLOR_TEXT = colors.white
local COLOR_HEADER = colors.lightBlue
local COLOR_BUTTON = colors.gray
local COLOR_BUTTON_ACTIVE = colors.lightBlue
local COLOR_CATALYST = colors.yellow
local COLOR_INGREDIENT = colors.lime
local COLOR_ERROR = colors.red
local COLOR_SUCCESS = colors.green

-- Clear monitor
local function clearMonitor()
    monitor.setBackgroundColor(COLOR_BG)
    monitor.clear()
end

-- Draw text
local function drawText(x, y, text, bgColor, textColor)
    monitor.setCursorPos(x, y)
    monitor.setBackgroundColor(bgColor or COLOR_BG)
    monitor.setTextColor(textColor or COLOR_TEXT)
    monitor.write(text)
end

-- Draw button
local function drawButton(x, y, w, text, bgColor, textColor)
    monitor.setBackgroundColor(bgColor or COLOR_BUTTON)
    for i = 0, w - 1 do
        monitor.setCursorPos(x + i, y)
        monitor.write(" ")
    end
    
    local textX = x + math.floor((w - #text) / 2)
    drawText(textX, y, text, bgColor, textColor)
end

-- Draw tabs
local function drawTabs()
    local tabWidth = math.floor(width / 3)
    
    -- Status tab
    local statusColor = currentTab == "status" and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
    drawButton(1, 1, tabWidth, "Status", statusColor, COLOR_TEXT)
    
    -- Programming tab
    local progColor = currentTab == "programming" and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
    drawButton(tabWidth + 1, 1, tabWidth, "Program", progColor, COLOR_TEXT)
    
    -- Recipes tab
    local recipeColor = currentTab == "recipes" and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
    drawButton(tabWidth * 2 + 1, 1, width - (tabWidth * 2), "Recipes", recipeColor, COLOR_TEXT)
end

-- Draw status message
local function drawStatusMessage()
    if statusMessage ~= "" and (os.epoch("utc") - statusMessageTime) < 3000 then
        local msgColor = statusMessage:find("ERROR") and COLOR_ERROR or COLOR_SUCCESS
        drawText(1, height, statusMessage:sub(1, width), COLOR_BG, msgColor)
    end
end

-- Show status message
local function showStatus(msg)
    statusMessage = msg
    statusMessageTime = os.epoch("utc")
end

-- Draw status tab
local function drawStatusTab()
    local y = 3
    
    if errorMode then
        drawText(1, y, "ERROR MODE", COLOR_BG, COLOR_ERROR)
        y = y + 1
        
        -- Word wrap error message
        local words = {}
        for word in errorMessage:gmatch("%S+") do
            table.insert(words, word)
        end
        
        local line = ""
        for _, word in ipairs(words) do
            if #line + #word + 1 <= width then
                line = line .. (line == "" and "" or " ") .. word
            else
                drawText(1, y, line, COLOR_BG, COLOR_ERROR)
                y = y + 1
                line = word
            end
        end
        if line ~= "" then
            drawText(1, y, line, COLOR_BG, COLOR_ERROR)
            y = y + 1
        end
        
        y = y + 1
        drawButton(1, y, width, "RESET ERROR", COLOR_ERROR, COLOR_TEXT)
        return
    end
    
    drawText(1, y, "Recipes: " .. #recipes, COLOR_BG, COLOR_HEADER)
    drawText(width - 15, y, "Turtles: " .. #turtles, COLOR_BG, COLOR_HEADER)
    y = y + 1
    
    drawText(1, y, "Altars: " .. #altars, COLOR_BG, COLOR_HEADER)
    
    local infusionCount = 0
    for _ in pairs(activeInfusions) do
        infusionCount = infusionCount + 1
    end
    drawText(width - 15, y, "Active: " .. infusionCount, COLOR_BG, COLOR_HEADER)
    y = y + 2
    
    -- Show turtle status
    if #turtles > 0 then
        drawText(1, y, "Turtle Status:", COLOR_BG, COLOR_HEADER)
        y = y + 1
        
        for _, turtle in ipairs(turtles) do
            local status = "T#" .. turtle.id .. ": " .. turtle.status
            if turtle.statusDetail and turtle.statusDetail ~= "" then
                status = status .. " (" .. turtle.statusDetail .. ")"
            end
            
            local statusColor = turtle.status == "idle" and colors.gray or COLOR_SUCCESS
            drawText(1, y, status:sub(1, width), COLOR_BG, statusColor)
            y = y + 1
            
            if y >= height - 1 then break end
        end
        
        y = y + 1
    end
    
    -- Show active infusions
    if infusionCount > 0 then
        drawText(1, y, "Active Infusions:", COLOR_BG, COLOR_HEADER)
        y = y + 1
        
        for altarIdx, infusion in pairs(activeInfusions) do
            local recipe = recipes[infusion.recipeId]
            if recipe then
                local catalystName = recipe.catalyst.item.displayName or recipe.catalyst.item.name
                local displayText = "Altar #" .. altarIdx .. ": " .. catalystName:sub(1, width - 15)
                drawText(1, y, displayText, COLOR_BG, COLOR_TEXT)
                y = y + 1
                
                -- Progress bar
                local elapsed = (os.epoch("utc") - infusion.startTime) / 1000
                local expected = recipe.averageTime > 0 and recipe.averageTime or 60
                local progress = math.min(elapsed / expected, 1)
                local barWidth = width - 2
                local fillWidth = math.floor(barWidth * progress)
                
                monitor.setCursorPos(1, y)
                monitor.setBackgroundColor(COLOR_BUTTON)
                monitor.write("[")
                monitor.setBackgroundColor(colors.green)
                monitor.write(string.rep("=", fillWidth))
                monitor.setBackgroundColor(COLOR_BUTTON)
                monitor.write(string.rep(" ", barWidth - fillWidth))
                monitor.write("]")
                
                y = y + 1
                
                if y >= height - 1 then break end
            end
        end
    end
end

-- Draw programming tab
local function drawProgrammingTab()
    local y = 3
    
    drawText(1, y, "Chest Items:", COLOR_BG, COLOR_HEADER)
    y = y + 1
    
    if #chestContents == 0 then
        drawText(1, y, "No items in chest", COLOR_BG, colors.gray)
        y = y + 2
        drawButton(1, y, width, "Refresh", COLOR_BUTTON, COLOR_TEXT)
        return
    end
    
    -- Draw item list
    local maxVisible = height - y - 3
    for i = 1, math.min(#chestContents, maxVisible) do
        local item = chestContents[i]
        local selection = selectedItems[item.slot]
        
        -- Item name
        local displayName = (item.displayName or item.name):sub(1, width - 12)
        local itemColor = COLOR_TEXT
        local itemBg = COLOR_BG
        
        if selection then
            if selection.type == "catalyst" then
                itemBg = COLOR_CATALYST
            elseif selection.type == "ingredient" then
                itemBg = COLOR_INGREDIENT
            end
        end
        
        -- Build suffix for NBT/DMG flags
        local suffix = ""
        if selection then
            if not selection.matchNBT and not selection.matchDMG then
                suffix = " !NBTDMG"
            elseif not selection.matchNBT then
                suffix = " !NBT"
            elseif not selection.matchDMG then
                suffix = " !DMG"
            end
        end
        
        drawText(1, y, displayName .. suffix, itemBg, itemColor)
        y = y + 1
    end
    
    -- Draw buttons
    y = height - 2
    
    -- Selection mode buttons
    local catColor = selectionMode == "catalyst" and COLOR_CATALYST or COLOR_BUTTON
    local ingColor = selectionMode == "ingredient" and COLOR_INGREDIENT or COLOR_BUTTON
    
    drawButton(1, y, math.floor(width / 3), "Catalyst", catColor, COLOR_TEXT)
    drawButton(math.floor(width / 3) + 1, y, math.floor(width / 3), "Ingredient", ingColor, COLOR_TEXT)
    drawButton(math.floor(width / 3) * 2 + 1, y, width - math.floor(width / 3) * 2, "NBT/DMG", COLOR_BUTTON, COLOR_TEXT)
    
    y = height - 1
    
    -- Count selections
    local catalystCount = 0
    local ingredientCount = 0
    for _, sel in pairs(selectedItems) do
        if sel.type == "catalyst" then
            catalystCount = catalystCount + 1
        elseif sel.type == "ingredient" then
            ingredientCount = ingredientCount + 1
        end
    end
    
    local addText = "ADD (" .. catalystCount .. " cat, " .. ingredientCount .. " ing)"
    local addColor = (catalystCount == 1 and ingredientCount > 0) and COLOR_SUCCESS or COLOR_BUTTON
    drawButton(1, y, width, addText, addColor, COLOR_TEXT)
end

-- Draw recipes tab
local function drawRecipesTab()
    local y = 3
    
    drawText(1, y, "Saved Recipes:", COLOR_BG, COLOR_HEADER)
    y = y + 1
    
    if #recipes == 0 then
        drawText(1, y, "No recipes saved", COLOR_BG, colors.gray)
        return
    end
    
    local maxVisible = height - y - 1
    local startIdx = scrollOffset + 1
    local endIdx = math.min(#recipes, startIdx + maxVisible - 1)
    
    for i = startIdx, endIdx do
        local recipe = recipes[i]
        
        -- Recipe header
        local catalystName = recipe.catalyst.item.displayName or recipe.catalyst.item.name
        local headerText = "#" .. i .. " " .. catalystName:sub(1, width - 10)
        drawText(1, y, headerText, COLOR_BG, COLOR_HEADER)
        y = y + 1
        
        -- Recipe stats
        if recipe.completedCount > 0 then
            local stats = "  Done: " .. recipe.completedCount .. "x, Avg: " .. math.floor(recipe.averageTime) .. "s"
            drawText(1, y, stats, COLOR_BG, colors.gray)
            y = y + 1
        end
        
        -- Ingredients
        local ingText = "  Ingredients: " .. #recipe.ingredients
        drawText(1, y, ingText, COLOR_BG, colors.gray)
        y = y + 1
        
        -- Spacing
        if i < endIdx then
            y = y + 1
        end
        
        if y >= height then break end
    end
    
    -- Scroll indicator
    if #recipes > maxVisible then
        local scrollText = "Scroll: " .. (scrollOffset + 1) .. "-" .. endIdx .. " of " .. #recipes
        drawText(width - #scrollText, height, scrollText, COLOR_BG, colors.gray)
    end
end

-- Draw screen
local function draw()
    clearMonitor()
    drawTabs()
    
    if currentTab == "status" then
        drawStatusTab()
    elseif currentTab == "programming" then
        drawProgrammingTab()
    elseif currentTab == "recipes" then
        drawRecipesTab()
    end
    
    drawStatusMessage()
end

-- Handle touch
local function handleTouch(x, y)
    local tabWidth = math.floor(width / 3)
    
    -- Tab switching
    if y == 1 then
        if x <= tabWidth then
            currentTab = "status"
        elseif x <= tabWidth * 2 then
            currentTab = "programming"
        else
            currentTab = "recipes"
        end
        scrollOffset = 0
        draw()
        return
    end
    
    -- Status tab
    if currentTab == "status" then
        if errorMode and y >= 6 and y <= 7 then
            modem.transmit(CHANNEL, CHANNEL, {
                type = "clear_error",
                data = {}
            })
        end
        return
    end
    
    -- Recipes tab
    if currentTab == "recipes" then
        -- Scrolling
        if y >= 4 and y < height then
            -- Click to scroll (future enhancement)
        end
        return
    end
    
    -- Programming tab
    if currentTab == "programming" then
        -- Item selection
        if y >= 4 and y < height - 2 then
            local itemIdx = y - 3
            if itemIdx <= #chestContents then
                local item = chestContents[itemIdx]
                
                if not selectionMode then
                    showStatus("ERROR: Select Catalyst or Ingredient mode first")
                    draw()
                    return
                end
                
                -- Toggle selection
                if selectedItems[item.slot] and selectedItems[item.slot].type == selectionMode then
                    selectedItems[item.slot] = nil
                else
                    if selectionMode == "catalyst" then
                        -- Only allow one catalyst
                        local catalystCount = 0
                        for _, sel in pairs(selectedItems) do
                            if sel.type == "catalyst" then
                                catalystCount = catalystCount + 1
                            end
                        end
                        
                        if catalystCount >= 1 then
                            showStatus("ERROR: Only 1 catalyst allowed")
                            draw()
                            return
                        end
                    end
                    
                    selectedItems[item.slot] = {
                        type = selectionMode,
                        matchNBT = true,
                        matchDMG = true
                    }
                end
            end
        end
        
        -- Button row 1
        if y == height - 2 then
            if x <= math.floor(width / 3) then
                -- Catalyst button (toggle)
                selectionMode = (selectionMode == "catalyst") and nil or "catalyst"
                
            elseif x <= math.floor(width / 3) * 2 then
                -- Ingredient button (toggle)
                selectionMode = (selectionMode == "ingredient") and nil or "ingredient"
                
            else
                -- NBT/DMG toggle on last selected item
                local lastSlot = nil
                for slot, _ in pairs(selectedItems) do
                    lastSlot = slot
                end
                
                if lastSlot and selectedItems[lastSlot] then
                    local sel = selectedItems[lastSlot]
                    if sel.matchNBT and sel.matchDMG then
                        sel.matchNBT = false
                    elseif not sel.matchNBT and sel.matchDMG then
                        sel.matchDMG = false
                    else
                        sel.matchNBT = true
                        sel.matchDMG = true
                    end
                end
            end
        end
        
        -- ADD button
        if y == height - 1 then
            local catalyst = nil
            local ingredients = {}
            
            for slot, selection in pairs(selectedItems) do
                local item = nil
                for _, chestItem in ipairs(chestContents) do
                    if chestItem.slot == slot then
                        item = chestItem
                        break
                    end
                end
                
                if item then
                    if selection.type == "catalyst" then
                        catalyst = {
                            item = item,
                            matchNBT = selection.matchNBT,
                            matchDMG = selection.matchDMG
                        }
                    elseif selection.type == "ingredient" then
                        table.insert(ingredients, {
                            item = item,
                            matchNBT = selection.matchNBT,
                            matchDMG = selection.matchDMG
                        })
                    end
                end
            end
            
            if not catalyst then
                showStatus("ERROR: No catalyst selected")
            elseif #ingredients == 0 then
                showStatus("ERROR: No ingredients selected")
            else
                modem.transmit(CHANNEL, CHANNEL, {
                    type = "add_recipe",
                    data = {
                        catalyst = catalyst,
                        ingredients = ingredients
                    }
                })
                
                showStatus("Recipe sent to server...")
            end
        end
        
        draw()
    end
end

-- Handle messages
local function handleMessage(msg)
    if type(msg) ~= "table" or not msg.type then return end
    
    if msg.type == "status_update" then
        recipes = msg.data.recipes or {}
        turtles = msg.data.turtles or {}
        altars = msg.data.altars or {}
        activeInfusions = msg.data.activeInfusions or {}
        errorMode = msg.data.errorMode or false
        errorMessage = msg.data.errorMessage or ""
        draw()
        
    elseif msg.type == "chest_contents" then
        chestContents = msg.data.items or {}
        draw()
        
    elseif msg.type == "error_mode" then
        errorMode = true
        errorMessage = msg.data.message
        draw()
        
    elseif msg.type == "error_cleared" then
        errorMode = false
        errorMessage = ""
        draw()
        
    elseif msg.type == "add_recipe_ack" then
        showStatus("Recipe added successfully!")
        selectedItems = {}
        selectionMode = nil
        draw()
        
    elseif msg.type == "add_recipe_nack" then
        showStatus("ERROR: " .. (msg.data.reason or "Unknown error"))
        draw()
        
    elseif msg.type == "recipe_added" or msg.type == "infusion_started" or 
           msg.type == "infusion_complete" or msg.type == "altar_registered" then
        -- Request status update
        modem.transmit(CHANNEL, CHANNEL, {
            type = "request_status",
            data = {}
        })
    end
end

-- Main loop
local function main()
    print("Thaumcraft Infusion Client v2.0 Starting...")
    
    clearMonitor()
    drawText(1, math.floor(height / 2), "Connecting to server...", COLOR_BG, COLOR_HEADER)
    
    -- Request initial status
    modem.transmit(CHANNEL, CHANNEL, {
        type = "request_status",
        data = {}
    })
    
    -- Request chest contents
    modem.transmit(CHANNEL, CHANNEL, {
        type = "request_chest_contents",
        data = {}
    })
    
    draw()
    
    local updateTimer = os.startTimer(2)
    
    while true do
        local event, p1, p2, p3, p4, p5 = os.pullEvent()
        
        if event == "monitor_touch" then
            handleTouch(p2, p3)
            
        elseif event == "modem_message" then
            handleMessage(p4)
            
        elseif event == "timer" and p1 == updateTimer then
            -- Periodic status update
            modem.transmit(CHANNEL, CHANNEL, {
                type = "request_status",
                data = {}
            })
            
            if currentTab == "programming" then
                modem.transmit(CHANNEL, CHANNEL, {
                    type = "request_chest_contents",
                    data = {}
                })
            end
            
            -- Redraw to update progress bars and clear old status messages
            draw()
            
            updateTimer = os.startTimer(2)
        end
    end
end

main()
