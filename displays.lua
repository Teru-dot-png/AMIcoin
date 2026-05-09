--[[
    AMIcoin Bank Display System (v8.0 - Public Sync)
    - Receives Top 10 data via "AMIcoin_Public" protocol
    - World Clocks (EU, US, Brazil)
    - Scrolling Welcome Marquee
    - Safety: Robust for B&W and Advanced Monitors
--]]

local MODEM_SIDE = "back" 
local PUBLIC_PORT = "AMIcoin_Public"

-- Monitors (Adjust sides as needed)
local CLOCK_MONITOR = "top" 
local STATS_MONITOR = "right"
local SCROLL_MONITOR = "bottom" 

local welcomeMsg = "Welcome to AMIbank, where money is not just digital! "
local scrollPos = 1

-- State to hold data received from bank
local cachedAccounts = {}

-- ULTRA SAFE COLOR WRAPPERS
local function setSafeColor(m, color)
    if m and m.setTextColor then
        if m.isColor and m.isColor() then
            m.setTextColor(color)
        else
            m.setTextColor(colors.white)
        end
    end
end

local function setSafeBG(m, color)
    if m and m.setBackgroundColor then
        if m.isColor and m.isColor() then
            m.setBackgroundColor(color)
        else
            m.setBackgroundColor(colors.black)
        end
    end
end

local function getTime(offset)
    local t = os.time() + offset
    if t >= 24 then t = t - 24 elseif t < 0 then t = t + 24 end
    local hours = math.floor(t)
    local mins = math.floor((t - hours) * 60)
    return string.format("%02d:%02d", hours, mins)
end

local function drawClocks()
    local m = peripheral.wrap(CLOCK_MONITOR)
    if not m then return end
    
    setSafeBG(m, colors.black)
    m.clear()
    if m.setTextScale then m.setTextScale(1) end
    
    local date = os.date("%d/%m/%Y")
    m.setCursorPos(1, 1)
    setSafeColor(m, colors.lightGray)
    m.write("DATE: " .. date)
    
    local zones = {
        {"EU (GMT):     ", 0},
        {"US (EST):     ", -5},
        {"Brazil (BRT): ", -3}
    }
    
    for i, zone in ipairs(zones) do
        m.setCursorPos(1, i + 2)
        setSafeColor(m, colors.white)
        m.write(zone[1])
        setSafeColor(m, colors.yellow)
        m.write(getTime(zone[2]))
    end
end

local function drawStats()
    local m = peripheral.wrap(STATS_MONITOR)
    if not m then return end
    
    setSafeBG(m, colors.black)
    m.clear()
    if m.setTextScale then m.setTextScale(0.5) end
    
    -- --- TOP 10 WEALTHY ---
    m.setCursorPos(1, 1)
    setSafeColor(m, colors.orange)
    m.write("=== TOP 10 WEALTHY ===")
    
    local wealthList = {}
    for _, acc in pairs(cachedAccounts) do table.insert(wealthList, acc) end
    table.sort(wealthList, function(a, b) return (a.balance or 0) > (b.balance or 0) end)

    for i = 1, math.min(10, #wealthList) do
        m.setCursorPos(1, i + 1)
        setSafeColor(m, colors.white)
        m.write(string.format("%2d. %-10s %.4f", i, wealthList[i].name or "Unknown", wealthList[i].balance or 0))
    end
    
    -- --- TOP 10 MINERS (Lifetime) ---
    m.setCursorPos(1, 13)
    setSafeColor(m, colors.cyan)
    m.write("=== TOP 10 MINERS ===")
    
    local minerList = {}
    for _, acc in pairs(cachedAccounts) do table.insert(minerList, acc) end
    table.sort(minerList, function(a, b) return (a.mined_total or 0) > (b.mined_total or 0) end)

    for i = 1, math.min(10, #minerList) do
        m.setCursorPos(1, 13 + i)
        setSafeColor(m, colors.white)
        m.write(string.format("%2d. %-10s %.5f", i, minerList[i].name or "Unknown", minerList[i].mined_total or 0))
    end
end

local function drawScrollingMarquee()
    local m = peripheral.wrap(SCROLL_MONITOR)
    if not m then return end
    
    local w, h = m.getSize()
    setSafeBG(m, colors.black)
    setSafeColor(m, colors.lime)
    if m.setTextScale then m.setTextScale(2) end
    
    local fullMsg = welcomeMsg .. welcomeMsg
    local displayStr = fullMsg:sub(scrollPos, scrollPos + math.floor(w * 0.8))
    
    m.clear()
    m.setCursorPos(1, math.max(1, math.floor(h/2)))
    m.write(displayStr)
    
    scrollPos = scrollPos + 1
    if scrollPos > #welcomeMsg then scrollPos = 1 end
end

-- REDNET LISTENER
local function networkSync()
    -- Listen specifically on the Public Port
    local id, msg = rednet.receive(PUBLIC_PORT, 0.05)
    if msg and type(msg) == "table" and msg.type == "display_update" then
        cachedAccounts = msg.accounts
    end
end

-- MAIN STARTUP
if not rednet.isOpen(MODEM_SIDE) then
    pcall(rednet.open, MODEM_SIDE)
end

-- Main Loop
while true do
    networkSync() 
    drawClocks()
    drawStats()
    -- Smooth scrolling sub-loop
    for i = 1, 4 do
        drawScrollingMarquee()
        sleep(0.15)
        networkSync() 
    end
end
