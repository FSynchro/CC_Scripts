-- Thaumcraft Infusion Client v3.2
-- NEW: Layout confirmation and rescan features

local CHANNEL = 1742

-- State
local monitor = peripheral.find("monitor")
local modem = peripheral.find("modem")
local currentTab = "status"
local chestContents = {}
local selectedItems = {}
local selectionMode = nil
local recipes = {}
local turtles = {}
local altars = {}
local activeInfusions = {}
local errorMode = false
local errorMessage = ""
local scrollOffset = 0
local statusMessage = ""
local statusMessageTime = 0
local setupComplete = false
local selectedAltarId = nil

if not monitor then
    error("No monitor found!")
end

if not modem then
    error("No modem found!")
end

modem.open(CHANNEL)

-- Monitor setup
local width, height = monitor.getSize()
monitor.setTextScale(0.5)
width, height = monitor.getSize()

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
local COLOR_PEDESTAL = colors.lime
local COLOR_STABILIZER = colors.lightBlue
local COLOR_AIR = colors.gray
local COLOR_PILLAR = colors.orange
local COLOR_WARNING = colors.orange

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
    local tabWidth = math.floor(width / 4)
    
    local statusColor = currentTab == "status" and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
    drawButton(1, 1, tabWidth, "Status", statusColor, COLOR_TEXT)
    
    local progColor = currentTab == "programming" and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
    drawButton(tabWidth + 1, 1, tabWidth, "Program", progColor, COLOR_TEXT)
    
    local recipeColor = currentTab == "recipes" and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
    drawButton(tabWidth * 2 + 1, 1, tabWidth, "Recipes", recipeColor, COLOR_TEXT)
    
    local altarColor = currentTab == "altars" and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
    drawButton(tabWidth * 3 + 1, 1, width - (tabWidth * 3), "Altars", altarColor, COLOR_TEXT)
end

-- Draw status message
local function drawStatusMessage()
    if statusMessage ~= "" and (os.epoch("utc") - statusMessageTime) < 3000 then
        local msgColor = statusMessage:find("ERROR") and COLOR_ERROR or COLOR_SUCCESS
        drawText(1, height, statusMessage:sub(1, width), COLOR_BG, msgColor)
    end
end

-- Show status
local function showStatus(msg)
    statusMessage = msg
    statusMessageTime = os.epoch("utc")
end

-- Draw status tab (similar to before but show confirmation status)
local function drawStatusTab()
    local y = 3
    
    if errorMode then
        drawText(1, y, "ERROR MODE", COLOR_BG, COLOR_ERROR)
        y = y + 1
        
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
    
    if not setupComplete then
        drawText(1, y, "SETUP IN PROGRESS", COLOR_BG, COLOR_WARNING)
        y = y + 1
        
        -- Show which altars need confirmation
        local unconfirmedCount = 0
        for _, altar in ipairs(altars) do
            if not altar.layoutConfirmed then
                unconfirmedCount = unconfirmedCount + 1
            end
        end
        
        if unconfirmedCount > 0 then
            drawText(1, y, unconfirmedCount .. " altar(s) awaiting confirmation", COLOR_BG, COLOR_WARNING)
        else
            drawText(1, y, "Waiting for altar scans...", COLOR_BG, colors.gray)
        end
        y = y + 2
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
    
    if infusionCount > 0 then
        drawText(1, y, "Active Infusions:", COLOR_BG, COLOR_HEADER)
        y = y + 1
        
        for altarId, infusion in pairs(activeInfusions) do
            local recipe = recipes[infusion.recipeId]
            if recipe then
                local catalystName = recipe.catalyst.item.displayName or recipe.catalyst.item.name
                local displayText = "Altar #" .. altarId .. ": " .. catalystName:sub(1, width - 15)
                drawText(1, y, displayText, COLOR_BG, COLOR_TEXT)
                y = y + 1
                
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

-- Draw programming tab (unchanged)
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
    
    local maxVisible = height - y - 3
    for i = 1, math.min(#chestContents, maxVisible) do
        local item = chestContents[i]
        local selection = selectedItems[item.slot]
        
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
    
    y = height - 2
    
    local catColor = selectionMode == "catalyst" and COLOR_CATALYST or COLOR_BUTTON
    local ingColor = selectionMode == "ingredient" and COLOR_INGREDIENT or COLOR_BUTTON
    
    drawButton(1, y, math.floor(width / 3), "Catalyst", catColor, COLOR_TEXT)
    drawButton(math.floor(width / 3) + 1, y, math.floor(width / 3), "Ingredient", ingColor, COLOR_TEXT)
    drawButton(math.floor(width / 3) * 2 + 1, y, width - math.floor(width / 3) * 2, "NBT/DMG", COLOR_BUTTON, COLOR_TEXT)
    
    y = height - 1
    
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

-- Draw recipes tab (unchanged)
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
        
        local catalystName = recipe.catalyst.item.displayName or recipe.catalyst.item.name
        local headerText = "#" .. i .. " " .. catalystName:sub(1, width - 10)
        drawText(1, y, headerText, COLOR_BG, COLOR_HEADER)
        y = y + 1
        
        if recipe.completedCount > 0 then
            local stats = "  Done: " .. recipe.completedCount .. "x, Avg: " .. math.floor(recipe.averageTime) .. "s"
            drawText(1, y, stats, COLOR_BG, colors.gray)
            y = y + 1
        end
        
        local ingText = "  Ingredients: " .. #recipe.ingredients
        drawText(1, y, ingText, COLOR_BG, colors.gray)
        y = y + 1
        
        if i < endIdx then
            y = y + 1
        end
        
        if y >= height then break end
    end
    
    if #recipes > maxVisible then
        local scrollText = "Scroll: " .. (scrollOffset + 1) .. "-" .. endIdx .. " of " .. #recipes
        drawText(width - #scrollText, height, scrollText, COLOR_BG, colors.gray)
    end
end

-- UPDATED: Draw altars tab with confirmation buttons
local function drawAltarsTab()
    local y = 3
    
    if #altars == 0 then
        drawText(1, y, "No altars registered", COLOR_BG, colors.gray)
        return
    end
    
    local listWidth = math.floor(width / 3)
    
    drawText(1, y, "Altars:", COLOR_BG, COLOR_HEADER)
    y = y + 1
    
    for _, altar in ipairs(altars) do
        local listColor = (selectedAltarId == altar.id) and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
        
        -- Status icon based on confirmation state
        local statusIcon
        if altar.layoutConfirmed then
            statusIcon = "[OK]"
        elseif altar.pedestalsScanned then
            statusIcon = "[??]"  -- Scanned but not confirmed
        else
            statusIcon = "[..]"  -- Not scanned
        end
        
        local altarText = "#" .. altar.id .. " " .. statusIcon
        
        if altar.busy then
            altarText = altarText .. " BUSY"
        end
        
        drawButton(1, y, listWidth, altarText:sub(1, listWidth), listColor, COLOR_TEXT)
        y = y + 1
        
        if y >= height - 1 then break end
    end
    
    -- Right side: Grid + buttons
    if selectedAltarId then
        local selectedAltar = nil
        for _, altar in ipairs(altars) do
            if altar.id == selectedAltarId then
                selectedAltar = altar
                break
            end
        end
        
        if selectedAltar then
            local gridX = listWidth + 3
            local gridY = 3
            
            -- Title
            local titleText = "Altar #" .. selectedAltarId
            if selectedAltar.layoutConfirmed then
                titleText = titleText .. " [CONFIRMED]"
            elseif selectedAltar.pedestalsScanned then
                titleText = titleText .. " [AWAITING CONFIRM]"
            else
                titleText = titleText .. " [NOT SCANNED]"
            end
            drawText(gridX, gridY, titleText, COLOR_BG, COLOR_HEADER)
            gridY = gridY + 2
            
            -- Legend
            drawText(gridX, gridY, "G=Air B=Stab P=Ped C=Cat O=Pillar", COLOR_BG, colors.gray)
            gridY = gridY + 1
            drawText(gridX, gridY, "Top=North Left=West", COLOR_BG, colors.gray)
            gridY = gridY + 1
            
            -- Create position maps
            local pedestalMap = {}
            local stabilizerMap = {}
            
            if selectedAltar.pedestals then
                for _, pos in ipairs(selectedAltar.pedestals) do
                    local xOffset = pos.x - selectedAltar.catalyst.x
                    local zOffset = pos.z - selectedAltar.catalyst.z
                    local key = xOffset .. "," .. zOffset
                    pedestalMap[key] = true
                end
            end
            
            if selectedAltar.stabilizers then
                for _, pos in ipairs(selectedAltar.stabilizers) do
                    local xOffset = pos.x - selectedAltar.catalyst.x
                    local zOffset = pos.z - selectedAltar.catalyst.z
                    local key = xOffset .. "," .. zOffset
                    stabilizerMap[key] = true
                end
            end
            
            -- Draw 7x7 grid
            for z = -3, 3 do
                for x = -3, 3 do
                    local posKey = x .. "," .. z
                    local symbol = "?"  -- Unknown by default
                    local symbolColor = colors.gray
                    
                    if x == 0 and z == 0 then
                        symbol = "C"
                        symbolColor = COLOR_CATALYST
                    
                    -- FIXED: Pillars at (±2, ±1) not (±2, ±2)
                    elseif (x == -2 and z == -1) or (x == -2 and z == 1) or 
                           (x == 2 and z == -1) or (x == 2 and z == 1) then
                        symbol = "O"
                        symbolColor = COLOR_PILLAR
                    
                    -- Only show scan results if scanning is complete
                    elseif selectedAltar.pedestalsScanned then
                        if pedestalMap[posKey] then
                            symbol = "P"
                            symbolColor = COLOR_PEDESTAL
                        
                        elseif stabilizerMap[posKey] then
                            symbol = "B"
                            symbolColor = COLOR_STABILIZER
                        
                        else
                            symbol = "G"  -- Air
                            symbolColor = COLOR_AIR
                        end
                    end
                    
                    drawText(gridX + x + 3, gridY + z + 3, symbol, COLOR_BG, symbolColor)
                end
            end
            
            -- Stats and buttons below grid
            local statsY = gridY + 11
            drawText(gridX, statsY, "Pedestals: " .. #(selectedAltar.pedestals or {}), COLOR_BG, COLOR_TEXT)
            statsY = statsY + 1
            drawText(gridX, statsY, "Stabilizers: " .. #(selectedAltar.stabilizers or {}), COLOR_BG, COLOR_TEXT)
            statsY = statsY + 2
            
            -- NEW: Action buttons
            if selectedAltar.pedestalsScanned and not selectedAltar.layoutConfirmed then
                -- Show CONFIRM button
                drawButton(gridX, statsY, 15, "CONFIRM LAYOUT", COLOR_SUCCESS, COLOR_TEXT)
                statsY = statsY + 1
                drawButton(gridX, statsY, 15, "RESCAN", COLOR_WARNING, COLOR_TEXT)
            elseif selectedAltar.layoutConfirmed then
                -- Show RESCAN button only
                drawButton(gridX, statsY, 15, "RESCAN", COLOR_BUTTON, COLOR_TEXT)
            else
                -- Not scanned yet
                drawText(gridX, statsY, "Waiting for scan...", COLOR_BG, colors.gray)
            end
        end
    else
        drawText(listWidth + 3, 5, "Select an altar from the list", COLOR_BG, colors.gray)
        drawText(listWidth + 3, 6, "to view its layout", COLOR_BG, colors.gray)
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
    elseif currentTab == "altars" then
        drawAltarsTab()
    end
    
    drawStatusMessage()
end

-- UPDATED: Handle touch with new buttons
local function handleTouch(x, y)
    local tabWidth = math.floor(width / 4)
    
    -- Tab switching
    if y == 1 then
        if x <= tabWidth then
            currentTab = "status"
        elseif x <= tabWidth * 2 then
            currentTab = "programming"
        elseif x <= tabWidth * 3 then
            currentTab = "recipes"
        else
            currentTab = "altars"
            if not selectedAltarId and #altars > 0 then
                selectedAltarId = altars[1].id
            end
        end
        scrollOffset = 0
        draw()
        return
    end
    
    if currentTab == "status" then
        if errorMode and y >= 6 and y <= 7 then
            modem.transmit(CHANNEL, CHANNEL, {
                type = "clear_error",
                data = {}
            })
        end
        return
    end
    
    if currentTab == "recipes" then
        return
    end
    
    -- UPDATED: Altars tab with button handling
    if currentTab == "altars" then
        local listWidth = math.floor(width / 3)
        
        -- Altar list selection
        if x <= listWidth and y >= 4 then
            local altarIdx = y - 3
            if altarIdx >= 1 and altarIdx <= #altars then
                selectedAltarId = altars[altarIdx].id
                draw()
            end
        end
        
        -- Button area (right side, bottom)
        local gridX = listWidth + 3
        local buttonY1 = 17  -- First button row
        local buttonY2 = 18  -- Second button row
        
        if selectedAltarId and x >= gridX then
            local selectedAltar = nil
            for _, altar in ipairs(altars) do
                if altar.id == selectedAltarId then
                    selectedAltar = altar
                    break
                end
            end
            
            if selectedAltar then
                -- CONFIRM LAYOUT button
                if y == buttonY1 and selectedAltar.pedestalsScanned and not selectedAltar.layoutConfirmed then
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "confirm_altar_layout",
                        data = {
                            altarId = selectedAltarId
                        }
                    })
                    showStatus("Confirming altar #" .. selectedAltarId .. " layout...")
                    draw()
                
                -- RESCAN button
                elseif y == buttonY1 or y == buttonY2 then
                    if (y == buttonY2 and selectedAltar.pedestalsScanned and not selectedAltar.layoutConfirmed) or
                       (y == buttonY1 and selectedAltar.layoutConfirmed) then
                        modem.transmit(CHANNEL, CHANNEL, {
                            type = "rescan_altar",
                            data = {
                                altarId = selectedAltarId
                            }
                        })
                        showStatus("Requesting rescan of altar #" .. selectedAltarId .. "...")
                        draw()
                    end
                end
            end
        end
        
        return
    end
    
    -- Programming tab (unchanged)
    if currentTab == "programming" then
        if y >= 4 and y < height - 2 then
            local itemIdx = y - 3
            if itemIdx <= #chestContents then
                local item = chestContents[itemIdx]
                
                if not selectionMode then
                    showStatus("ERROR: Select Catalyst or Ingredient mode first")
                    draw()
                    return
                end
                
                if selectedItems[item.slot] and selectedItems[item.slot].type == selectionMode then
                    selectedItems[item.slot] = nil
                else
                    if selectionMode == "catalyst" then
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
        
        if y == height - 2 then
            if x <= math.floor(width / 3) then
                selectionMode = (selectionMode == "catalyst") and nil or "catalyst"
                
            elseif x <= math.floor(width / 3) * 2 then
                selectionMode = (selectionMode == "ingredient") and nil or "ingredient"
                
            else
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
        setupComplete = msg.data.setupComplete or false
        
        if currentTab == "altars" and not selectedAltarId and #altars > 0 then
            selectedAltarId = altars[1].id
        end
        
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
    
    elseif msg.type == "setup_complete" then
        setupComplete = true
        showStatus("Setup complete! " .. (msg.data.altarCount or 0) .. " altars ready")
        draw()
        
    elseif msg.type == "altar_confirmed" then
        showStatus("Altar #" .. msg.data.altarId .. " confirmed!")
        draw()
        
    elseif msg.type == "altar_layout_cleared" then
        showStatus("Altar #" .. msg.data.altarId .. " cleared, rescanning...")
        -- Request fresh status to update display
        modem.transmit(CHANNEL, CHANNEL, {
            type = "request_status",
            data = {}
        })
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
        modem.transmit(CHANNEL, CHANNEL, {
            type = "request_status",
            data = {}
        })
    end
end

-- Main loop
local function main()
    print("Thaumcraft Infusion Client v3.2 Starting...")
    
    clearMonitor()
    drawText(1, math.floor(height / 2), "Connecting to server...", COLOR_BG, COLOR_HEADER)
    
    modem.transmit(CHANNEL, CHANNEL, {
        type = "request_status",
        data = {}
    })
    
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
            
            draw()
            
            updateTimer = os.startTimer(2)
        end
    end
end

main()
