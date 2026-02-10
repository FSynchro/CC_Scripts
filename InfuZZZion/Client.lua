-- Thaumcraft Infusion Client
-- Monitor interface for recipe programming and status viewing

local CHANNEL = 1742

-- State
local monitor = peripheral.find("monitor")
local modem = peripheral.find("modem")
local currentTab = "status" -- "status" or "programming"
local chestContents = {}
local selectedItems = {} -- {slot = {type = "catalyst"|"ingredient", matchNBT = bool, matchDMG = bool}}
local recipes = {}
local turtles = {}
local activeInfusions = {}
local errorMode = false
local errorMessage = ""
local scrollOffset = 0

if not monitor then
    error("No monitor found!")
end

if not modem then
    error("No modem found! Please attach an ender modem.")
end

modem.open(CHANNEL)

-- Monitor dimensions
local width, height = monitor.getSize()

-- Colors
local COLOR_BG = colors.black
local COLOR_TEXT = colors.white
local COLOR_HEADER = colors.blue
local COLOR_BUTTON = colors.gray
local COLOR_BUTTON_ACTIVE = colors.lightBlue
local COLOR_CATALYST = colors.yellow
local COLOR_INGREDIENT = colors.lime
local COLOR_ERROR = colors.red
local COLOR_NBT_OFF = colors.yellow
local COLOR_DMG_OFF = colors.orange
local COLOR_BOTH_OFF = colors.red

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
    -- Status tab
    local statusColor = currentTab == "status" and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
    drawButton(1, 1, math.floor(width / 2), "Status", statusColor, COLOR_TEXT)
    
    -- Programming tab
    local progColor = currentTab == "programming" and COLOR_BUTTON_ACTIVE or COLOR_BUTTON
    drawButton(math.floor(width / 2) + 1, 1, width - math.floor(width / 2), "Program", progColor, COLOR_TEXT)
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
        
        drawButton(1, y, width, "RESET", COLOR_ERROR, COLOR_TEXT)
        return
    end
    
    drawText(1, y, "Recipes: " .. #recipes, COLOR_BG, COLOR_TEXT)
    y = y + 1
    drawText(1, y, "Turtles: " .. #turtles, COLOR_BG, COLOR_TEXT)
    y = y + 1
    
    -- Show active infusions
    local infusionCount = 0
    for _ in pairs(activeInfusions) do
        infusionCount = infusionCount + 1
    end
    
    drawText(1, y, "Active: " .. infusionCount, COLOR_BG, COLOR_TEXT)
    y = y + 2
    
    -- Show recipe list (scrollable)
    if #recipes > 0 then
        drawText(1, y, "Tracked Recipes:", COLOR_BG, COLOR_HEADER)
        y = y + 1
        
        local maxVisible = height - y
        local startIdx = scrollOffset + 1
        local endIdx = math.min(#recipes, startIdx + maxVisible - 1)
        
        for i = startIdx, endIdx do
            local recipe = recipes[i]
            local displayText = "#" .. i .. " "
            
            -- Show catalyst name (truncate if needed)
            if recipe.catalyst then
                local catalystName = recipe.catalyst.item.displayName or recipe.catalyst.item.name
                displayText = displayText .. catalystName:sub(1, width - #displayText - 2)
            end
            
            drawText(1, y, displayText, COLOR_BG, COLOR_TEXT)
            y = y + 1
            
            -- Show progress bar if infusing
            for altarIdx, infusion in pairs(activeInfusions) do
                if infusion.recipeId == i then
                    local elapsed = (os.epoch("utc") - infusion.startTime) / 1000
                    local expected = recipe.averageTime or 60
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
                    break
                end
            end
            
            if y >= height then break end
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
    local maxVisible = height - y - 2
    for i = 1, math.min(#chestContents, maxVisible) do
        local item = chestContents[i]
        local selection = selectedItems[item.slot]
        
        -- Item name
        local displayName = (item.displayName or item.name):sub(1, width - 4)
        local itemColor = COLOR_TEXT
        local itemBg = COLOR_BG
        
        if selection then
            if selection.type == "catalyst" then
                itemBg = COLOR_CATALYST
            elseif selection.type == "ingredient" then
                itemBg = COLOR_INGREDIENT
            end
            
            -- Draw border based on matching flags
            if not selection.matchNBT and not selection.matchDMG then
                itemColor = COLOR_BOTH_OFF
            elseif not selection.matchNBT then
                itemColor = COLOR_NBT_OFF
            elseif not selection.matchDMG then
                itemColor = COLOR_DMG_OFF
            end
        end
        
        -- Draw item text with border if needed
        if selection and (not selection.matchNBT or not selection.matchDMG) then
            monitor.setCursorPos(1, y)
            monitor.setTextColor(itemColor)
            monitor.setBackgroundColor(itemBg)
            monitor.write("[]")
            monitor.setCursorPos(3, y)
            monitor.setTextColor(COLOR_TEXT)
            monitor.write(displayName:sub(1, width - 4))
            monitor.setCursorPos(width - 1, y)
            monitor.setTextColor(itemColor)
            monitor.write("[]")
        else
            drawText(1, y, displayName, itemBg, itemColor)
        end
        
        y = y + 1
    end
    
    -- Draw buttons
    y = height - 1
    drawButton(1, y, math.floor(width / 3), "Cat", COLOR_BUTTON, COLOR_TEXT)
    drawButton(math.floor(width / 3) + 1, y, math.floor(width / 3), "Ing", COLOR_BUTTON, COLOR_TEXT)
    drawButton(math.floor(width / 3) * 2 + 1, y, width - math.floor(width / 3) * 2, "NBT/DMG", COLOR_BUTTON, COLOR_TEXT)
    
    y = height
    drawButton(1, y, width, "ADD", COLOR_INGREDIENT, COLOR_TEXT)
end

-- Draw screen
local function draw()
    clearMonitor()
    drawTabs()
    
    if currentTab == "status" then
        drawStatusTab()
    elseif currentTab == "programming" then
        drawProgrammingTab()
    end
end

-- Handle touch
local function handleTouch(x, y)
    -- Tab switching
    if y == 1 then
        if x <= math.floor(width / 2) then
            currentTab = "status"
        else
            currentTab = "programming"
        end
        draw()
        return
    end
    
    -- Status tab
    if currentTab == "status" then
        if errorMode and y == 6 then
            -- Reset button
            modem.transmit(CHANNEL, CHANNEL, {
                type = "clear_error",
                data = {}
            })
        end
        return
    end
    
    -- Programming tab
    if currentTab == "programming" then
        -- Item selection (clicking on item itself)
        if y >= 4 and y < height - 1 then
            local itemIdx = y - 3
            if itemIdx <= #chestContents then
                local item = chestContents[itemIdx]
                -- Store last selected item for button presses
                _G.lastSelectedSlot = item.slot
            end
        end
        
        -- Buttons row 1 (Catalyst, Ingredient, NBT/DMG)
        if y == height - 1 then
            if _G.lastSelectedSlot then
                -- Find the item
                local item = nil
                for _, chestItem in ipairs(chestContents) do
                    if chestItem.slot == _G.lastSelectedSlot then
                        item = chestItem
                        break
                    end
                end
                
                if item then
                    if x <= math.floor(width / 3) then
                        -- Catalyst button
                        -- Clear other catalyst selections
                        for slot, sel in pairs(selectedItems) do
                            if sel.type == "catalyst" then
                                selectedItems[slot] = nil
                            end
                        end
                        
                        if selectedItems[item.slot] and selectedItems[item.slot].type == "catalyst" then
                            selectedItems[item.slot] = nil
                        else
                            selectedItems[item.slot] = {
                                type = "catalyst",
                                matchNBT = true,
                                matchDMG = true
                            }
                        end
                        
                    elseif x <= math.floor(width / 3) * 2 then
                        -- Ingredient button
                        if selectedItems[item.slot] and selectedItems[item.slot].type == "ingredient" then
                            selectedItems[item.slot] = nil
                        else
                            selectedItems[item.slot] = {
                                type = "ingredient",
                                matchNBT = true,
                                matchDMG = true
                            }
                        end
                        
                    else
                        -- NBT/DMG toggle
                        if selectedItems[item.slot] then
                            local sel = selectedItems[item.slot]
                            if sel.matchNBT and sel.matchDMG then
                                sel.matchNBT = false
                            elseif not sel.matchNBT and sel.matchDMG then
                                sel.matchDMG = false
                            elseif sel.matchNBT and not sel.matchDMG then
                                sel.matchNBT = true
                                sel.matchDMG = true
                            else
                                sel.matchNBT = true
                            end
                        end
                    end
                end
            end
        end
        
        if y == height then
            -- ADD button
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
            
            if catalyst and #ingredients > 0 then
                modem.transmit(CHANNEL, CHANNEL, {
                    type = "add_recipe",
                    data = {
                        catalyst = catalyst,
                        ingredients = ingredients
                    }
                })
                
                selectedItems = {}
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
        
    elseif msg.type == "recipe_added" or msg.type == "infusion_started" or msg.type == "infusion_complete" then
        -- Request status update
        modem.transmit(CHANNEL, CHANNEL, {
            type = "request_status",
            data = {}
        })
    end
end

-- Main loop
local function main()
    print("Thaumcraft Infusion Client Starting...")
    
    clearMonitor()
    drawText(1, 1, "Connecting...", COLOR_BG, COLOR_TEXT)
    
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
    
    while true do
        local event, p1, p2, p3, p4, p5 = os.pullEvent()
        
        if event == "monitor_touch" then
            handleTouch(p2, p3)
        elseif event == "modem_message" then
            handleMessage(p4)
        elseif event == "timer" then
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
        end
        
        if event == "timer" or event == "monitor_touch" then
            os.startTimer(2)
        end
    end
end

os.startTimer(2)
main()
