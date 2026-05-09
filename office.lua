--[[
    AMIcoin Office Reception Program
    - Full-featured text editor
    - Auto-generates Account Opening Forms
    - Press Ctrl+A to Print
--]]

local printer = nil
-- Search for printer
for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "printer" then
        printer = peripheral.wrap(side)
        break
    end
end

local w, h = term.getSize()
local lines = {
    "--- AMICOIN BANK ---",
    "ACCOUNT OPENING FORM",
    "--------------------",
    "Date: " .. os.date("%d/%m/%Y"),
    "Full Name: ",
    "Address: ",
    "",
    "Account Type:",
    "[ ] Personal  [ ] Business",
    "[ ] Mining    [ ] Whale",
    "",
    "Initial Deposit: ____ AMI",
    "Reference ID: ",
    "",
    "Notes:",
    "____________________",
    "____________________",
    "",
    "Signature:",
    "X___________________",
    "",
    "--------------------",
    "FOR BANK USE ONLY:",
    "Name Paper approved for approval",
}

local cursorX, cursorY = 12, 5 -- Start at "Full Name"
local scrollY = 0

local function draw()
    term.clear()
    -- Draw Status Bar
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.clearLine()
    term.write(" AMIbank Office | Ctrl+A: Print | Lines: " .. #lines)
    term.setBackgroundColor(colors.black)

    -- Draw Text area
    for i = 1, h - 1 do
        local lineIdx = i + scrollY
        if lines[lineIdx] then
            term.setCursorPos(1, i + 1)
            term.write(lines[lineIdx])
        end
    end

    term.setCursorPos(cursorX, cursorY - scrollY + 1)
    term.setCursorBlink(true)
end

local function printDocument()
    if not printer then
        term.setCursorPos(1, h)
        term.setTextColor(colors.red)
        term.write("Error: No printer found!")
        sleep(1.5)
        term.setTextColor(colors.white)
        return
    end

    if printer.getPaperLevel() == 0 then
        term.setCursorPos(1, h)
        term.setTextColor(colors.red)
        term.write("Error: Out of paper!")
        sleep(1.5)
        term.setTextColor(colors.white)
        return
    end

    term.setCursorPos(1, h)
    term.setTextColor(colors.yellow)
    term.write("Printing... please wait.")
    
    printer.newPage()
    local pw, ph = printer.getPageSize()
    
    for i, text in ipairs(lines) do
        printer.setCursorPos(1, i)
        printer.write(text)
        if i >= ph then break end -- Limit to one page for now
    end
    
    printer.endPage()
    term.setTextColor(colors.white)
end

-- Main Loop
local ctrlDown = false

while true do
    draw()
    local event, p1, p2 = os.pullEvent()

    if event == "key" then
        if p1 == keys.left then
            cursorX = math.max(1, cursorX - 1)
        elseif p1 == keys.right then
            cursorX = math.min(#lines[cursorY] + 1, cursorX + 1)
        elseif p1 == keys.up then
            if cursorY > 1 then
                cursorY = cursorY - 1
                cursorX = math.min(cursorX, #lines[cursorY] + 1)
            end
        elseif p1 == keys.down then
            if cursorY < #lines then
                cursorY = cursorY + 1
                cursorX = math.min(cursorX, #lines[cursorY] + 1)
            end
        elseif p1 == keys.backspace then
            if cursorX > 1 then
                local line = lines[cursorY]
                lines[cursorY] = line:sub(1, cursorX - 2) .. line:sub(cursorX)
                cursorX = cursorX - 1
            elseif cursorY > 1 then
                -- Merge lines
                local oldLine = lines[cursorY]
                table.remove(lines, cursorY)
                cursorY = cursorY - 1
                cursorX = #lines[cursorY] + 1
                lines[cursorY] = lines[cursorY] .. oldLine
            end
        elseif p1 == keys.enter then
            local line = lines[cursorY]
            local remaining = line:sub(cursorX)
            lines[cursorY] = line:sub(1, cursorX - 1)
            table.insert(lines, cursorY + 1, remaining)
            cursorY = cursorY + 1
            cursorX = 1
        elseif p1 == keys.leftCtrl or p1 == keys.rightCtrl then
            ctrlDown = true
        elseif p1 == keys.a and ctrlDown then
            printDocument()
        end

    elseif event == "key_up" then
        if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
            ctrlDown = false
        end

    elseif event == "char" then
        local line = lines[cursorY]
        lines[cursorY] = line:sub(1, cursorX - 1) .. p1 .. line:sub(cursorX)
        cursorX = cursorX + 1
    end

    -- Handle Scrolling
    if cursorY - scrollY > h - 2 then
        scrollY = cursorY - (h - 2)
    elseif cursorY - scrollY < 1 then
        scrollY = cursorY - 1
    end
end
