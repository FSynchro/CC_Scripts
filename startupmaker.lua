local rootDir = "/CC_Scripts"

-- Helper to center text on screen
local function center(text)
    local w, _ = term.getSize()
    local x = math.floor((w - #text) / 2) + 1
    term.setCursorPos(x, select(2, term.getCursorPos()))
    print(text)
end

-- 1. SLIM ASCII HEADER (Fits 51-char width)
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

-- 2. RECURSIVE FILE FINDER (Improved)
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
    table.sort(fileList) -- Keep it tidy
    return fileList
end

-- 3. UI RENDERER
local function drawMenu(scripts, selected)
    drawHeader()
    
    local w, h = term.getSize()
    -- List display starts after header
    for i, path in ipairs(scripts) do
        -- Simple scrolling check if list is long
        if i >= selected - 5 and i <= selected + 5 then
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
    
    -- Footer (pinned to bottom)
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
        local f = fs.open("startup.lua", "w")
        f.writeLine("-- CCSCRIPTSUTIL CONFIG")
        f.writeLine("shell.run(\"/" .. target .. "\")")
        f.close()
        
        term.setBackgroundColor(colors.blue)
        term.clear()
        term.setCursorPos(1, h/2)
        term.setTextColor(colors.white)
        center("CONFIGURATION SAVED")
        center("Rebooting...")
        sleep(1)
        os.reboot()
    end
end
