local rootDir = "/CC_Scripts"

-- Helper to center text on screen
local function center(text)
    local w, _ = term.getSize()
    local x = math.floor((w - #text) / 2) + 1
    term.setCursorPos(x, select(2, term.getCursorPos()))
    print(text)
end

-- 1. UPDATED FSYNC HEADER
local function drawHeader()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1,1)
    
    term.setTextColor(colors.gray)
    print("---------------------------------------------------")
    term.setTextColor(colors.cyan)
    center("  _____  ______     ___   _  ____")
    center(" |  ___|/ ___\\ \\   / / \\ | |/ ___|")
    center(" | |_   \\___ \\\\ \\ / /|  \\| | |    ")
    center(" |  _|   ___) |\\ V / | |\\  | |___ ")
    center(" |_|    |____/  |_|  |_| \\_|\\____|")
    
    print("")
    term.setTextColor(colors.yellow)
    center("[ Computer startup configuration utility ]")
    term.setTextColor(colors.gray)
    print("---------------------------------------------------")
    term.setTextColor(colors.white)
    center("Select a program to auto-start")
    center("on system reboot.")
    print("---------------------------------------------------")
end

-- 2. RECURSIVE FILE FINDER
local function getScripts(dir, fileList)
    fileList = fileList or {}
    if not fs.exists(dir) or not fs.isDir(dir) then return fileList end
    local list = fs.list(dir)
    for _, file in ipairs(list) do
        local path = fs.combine(dir, file)
        if fs.isDir(path) then
            getScripts(path, fileList)
        elseif file:sub(-4) == ".lua" and file ~= "startupmaker.lua" and file ~= "startup.lua" then
            table.insert(fileList, path)
        end
    end
    table.sort(fileList)
    return fileList
end

-- 3. UI RENDERER
local function drawMenu(scripts, selected)
    drawHeader()
    
    local w, h = term.getSize()
    
    for i, path in ipairs(scripts) do
        -- Scissor the list so it doesn't run off the bottom of the screen
        if i >= selected - 3 and i <= selected + 3 then
            if i == selected then
                term.setBackgroundColor(colors.lightGray)
                term.setTextColor(colors.black)
                term.clearLine()
                term.write("> " .. path)
                print("")
                term.setBackgroundColor(colors.black)
            else
                term.setTextColor(colors.white)
                print("  " .. path)
            end
        end
    end
    
    -- Footer
    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()
    term.write(" [UP/DOWN] Move | [ENTER] Save | [Q] Quit")
    term.setBackgroundColor(colors.black)
end

-- 4. MAIN LOGIC
local scripts = getScripts(rootDir)
if #scripts == 0 then
    drawHeader()
    term.setTextColor(colors.red)
    center("Error: No scripts found in "..rootDir)
    return
end

local selected = 1
while true do
    drawMenu(scripts, selected)
    local event, key = os.pullEvent("key")
    
    if key == keys.up then
        selected = selected > 1 and selected - 1 or #scripts
    elseif key == keys.down then
        selected = selected < #scripts and selected + 1 or 1
    elseif key == keys.q then
        term.clear()
        term.setCursorPos(1,1)
        break
    elseif key == keys.enter then
        local target = scripts[selected]
        
        -- WRITING THE NEW AUTO-UPDATING STARTUP SCRIPT
        local f = fs.open("startup.lua", "w")
        f.writeLine("-- FSYNC AUTO-UPDATING BOOT")
        f.writeLine("print('Checking for updates...')")
        
        -- Delete the old folder to ensure a clean clone
        f.writeLine("if fs.exists('" .. rootDir .. "') then fs.delete('" .. rootDir .. "') end")
        
        -- Clone the repo (Assumes clone.min is already on the computer)
        f.writeLine("shell.run('clone.min https://github.com/FSynchro/CC_Scripts')")
        
        -- Run the selected script
        f.writeLine("if fs.exists('" .. target .. "') then")
        f.writeLine("  shell.run('" .. target .. "')")
        f.writeLine("else")
        f.writeLine("  print('Error: Target script not found after update.')")
        f.writeLine("  print('Path: " .. target .. "')")
        f.writeLine("end")
        f.close()
        
        -- UI Confirmation
        local w, h = term.getSize()
        term.setBackgroundColor(colors.blue)
        term.clear()
        term.setCursorPos(1, math.floor(h/2))
        term.setTextColor(colors.white)
        center("FSYNC: AUTO-UPDATE ENABLED")
        center("Script: " .. fs.getName(target))
        center("Rebooting computer...")
        sleep(1.5)
        os.reboot()
    end
end
