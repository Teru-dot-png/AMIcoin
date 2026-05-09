--[[
    AMIcoin Central Bank Server (v8.3 - Dual Modem Support)
    - Fix: Uses separate protocols for private/public messages.
    - Fix: Auto-detects 2 modems; first = private, second = public.
    - Features: Transaction Logs, Receipts, Auto-modem, Mining.
--]]

local MASTER_PASSWORD = "SomemoreIsNeverEnough"
local PRIVATE_PORT   = "AMIcoin_Net"     -- For Pad/Phone communication
local PUBLIC_PORT   = "AMIcoin_Public"  -- For Displays/Printers
local ROUTER_PROTOCOL = "AMIcoin_Router" -- For wired PCrouter relay
local ACCOUNTS_DIR = "accounts/"
local STATS_FILE = "bank_stats.json"
local LOG_FILE = "transactions.json"
local MONITOR_SIDE = "right"

local PI_DIGITS = "14159265358979323846264338327950288419716939937510"

if not fs.exists(ACCOUNTS_DIR) then fs.makeDir(ACCOUNTS_DIR) end

local bankStats = { placement = 1 }
local transactionLogs = {} 
local activeMiners = {} 
local lastBroadcast = 0

local function loadData()
    if fs.exists(STATS_FILE) then
        local f = fs.open(STATS_FILE, "r")
        bankStats = textutils.unserializeJSON(f.readAll()) or {placement=1}
        f.close()
    end
    if fs.exists(LOG_FILE) then
        local f = fs.open(LOG_FILE, "r")
        transactionLogs = textutils.unserializeJSON(f.readAll()) or {}
        f.close()
    end
end

local function saveData()
    local f = fs.open(STATS_FILE, "w")
    f.write(textutils.serializeJSON(bankStats))
    f.close()
    local f2 = fs.open(LOG_FILE, "w")
    f2.write(textutils.serializeJSON(transactionLogs))
    f2.close()
end

loadData()

local function addLog(type, details)
    local entry = {
        time = os.date("%H:%M:%S"),
        date = os.date("%d/%m/%y"),
        type = type,
        details = details
    }
    table.insert(transactionLogs, 1, entry)
    if #transactionLogs > 10 then table.remove(transactionLogs) end
    saveData()
    -- BROADCAST ON PUBLIC PORT
    rednet.broadcast({type="receipt", data=entry}, PUBLIC_PORT)
end

local function generateAccountID()
    local t = os.time(); local date = os.date("*t"); local dayName = os.date("%A")
    local piStart = math.random(1, #PI_DIGITS - 3)
    local piSnippet = PI_DIGITS:sub(piStart, piStart + 2)
    local baseNum = (tonumber(tostring(t)..piSnippet..tostring(date.month)) or 0) * bankStats.placement
    local finalStr = tostring(baseNum); local result = ""; local weekIdx = 1
    for i = 1, #finalStr do
        result = result .. finalStr:sub(i, i)
        if i % 2 == 0 and weekIdx <= #dayName then
            result = result .. dayName:sub(weekIdx, weekIdx); weekIdx = weekIdx + 1
        end
    end
    if fs.exists(ACCOUNTS_DIR .. result .. ".json") then return generateAccountID() end
    return result
end

local function getAccount(id)
    local path = ACCOUNTS_DIR .. tostring(id) .. ".json"
    if fs.exists(path) then
        local f = fs.open(path, "r"); local data = textutils.unserializeJSON(f.readAll()); f.close()
        return data
    end
    return nil
end

local function saveAccount(account)
    local f = fs.open(ACCOUNTS_DIR .. account.accountID .. ".json", "w")
    f.write(textutils.serializeJSON(account)); f.close()
end

local function createAccount(name, password)
    local acc = {
        name = name, password = password, accountID = generateAccountID(),
        balance = 0, mined_total = 0, time_created = os.date("%H:%M %d/%m/%Y")
    }
    saveAccount(acc); bankStats.placement = bankStats.placement + 1; saveData()
    addLog("NEW_ACC", {name=name, id=acc.accountID})
    return acc
end

local function updateMonitor()
    local m = peripheral.wrap(MONITOR_SIDE)
    if not m or not m.clear then return end
    local accounts = {}
    local files = fs.list(ACCOUNTS_DIR)
    for _, file in ipairs(files) do
        if file:sub(-5) == ".json" then
            local data = getAccount(file:sub(1, -6))
            if data then table.insert(accounts, {name = data.name, balance = data.balance}) end
        end
    end
    table.sort(accounts, function(a, b) return (a.balance or 0) > (b.balance or 0) end)
    m.setTextScale(1); if m.isColor and m.isColor() then m.setBackgroundColor(colors.black) end; m.clear()
    m.setCursorPos(1,1); if m.isColor and m.isColor() then m.setTextColor(colors.yellow) end
    m.write("== TOP WHALES ==")
    for i = 1, math.min(5, #accounts) do
        m.setCursorPos(1, i + 1); if m.isColor and m.isColor() then m.setTextColor(colors.white) end
        m.write(string.format("%d. %-8s: %.2f", i, accounts[i].name, accounts[i].balance))
    end
    local minerRow = 8; m.setCursorPos(1, minerRow); if m.isColor and m.isColor() then m.setTextColor(colors.green) end
    m.write("== MINERS ONLINE =="); local now = os.epoch("utc"); local mCount = 0
    for id, data in pairs(activeMiners) do
        if now - data.lastSeen < 15000 and mCount < 4 then
            m.setCursorPos(1, minerRow + 1 + mCount); if m.isColor and m.isColor() then m.setTextColor(colors.white) end
            m.write(" > " .. data.name); mCount = mCount + 1
        end
    end
    local logRow = 14; m.setCursorPos(1, logRow); if m.isColor and m.isColor() then m.setTextColor(colors.cyan) end
    m.write("== RECENT LOGS ==")
    for i = 1, 5 do
        local log = transactionLogs[i]
        if log then
            m.setCursorPos(1, logRow + i); if m.isColor and m.isColor() then m.setTextColor(colors.gray) end
            local txt = log.type == "TRANSFER" and (log.details.from.."->"..log.details.to) or log.type
            m.write(string.format("%s: %s", log.time, txt))
        end
    end
end

local function broadcastToDisplays()
    if os.epoch("utc") - lastBroadcast < 5000 then return end
    local sync = {}
    local files = fs.list(ACCOUNTS_DIR)
    for _, file in ipairs(files) do
        if file:sub(-5) == ".json" then
            local acc = getAccount(file:sub(1, -6))
            if acc then table.insert(sync, {name=acc.name, balance=acc.balance, mined_total=acc.mined_total or 0}) end
        end
    end
    rednet.broadcast({type="display_update", accounts=sync}, PUBLIC_PORT)
    lastBroadcast = os.epoch("utc")
end

local function processMessage(id, msg)
    if type(msg) ~= "table" then return end
    if msg.type == "ping" then
        activeMiners[id] = { name = msg.name or "Unknown", lastSeen = os.epoch("utc") }
    elseif msg.type == "mine_submit" then
        local acc = getAccount(msg.accountID)
        if acc then
            acc.balance = acc.balance + 0.00001; acc.mined_total = (acc.mined_total or 0) + 0.00001
            saveAccount(acc)
        end
    elseif msg.type == "login" then
        local acc = getAccount(msg.accountID)
        if acc and acc.password == msg.password then
            rednet.send(id, {type="res", success=true, name=acc.name}, PRIVATE_PORT)
        else
            rednet.send(id, {type="res", success=false, error="Invalid Auth"}, PRIVATE_PORT)
        end
    elseif msg.type == "get_balance" then
        local acc = getAccount(msg.accountID)
        if acc and acc.password == msg.password then
            rednet.send(id, {type="res", balance=acc.balance}, PRIVATE_PORT)
        end
    elseif msg.type == "transfer" then
        local sender = getAccount(msg.accountID); local receiver = getAccount(msg.toID)
        if sender and receiver and sender.password == msg.password and sender.balance >= msg.amount then
            sender.balance = sender.balance - msg.amount; receiver.balance = receiver.balance + msg.amount
            saveAccount(sender); saveAccount(receiver)
            -- SEND RESPONSE FIRST
            rednet.send(id, {type="res", success=true}, PRIVATE_PORT)
            -- THEN LOG (WHICH BROADCASTS ON PUBLIC PORT)
            addLog("TRANSFER", {from=sender.name, to=receiver.name, amount=msg.amount})
        else
            rednet.send(id, {type="res", success=false, error="Transfer Failed"}, PRIVATE_PORT)
        end
    end
end

-- ============================================================
-- Routed message handler: processes messages forwarded by PCrouter
-- on behalf of far-away miners connected via ender modems.
-- routerID  = computer ID of the PCrouter
-- originID  = computer ID of the original sender (miner/hub)
-- msg       = the original message payload
-- ============================================================
local function processRoutedMessage(routerID, originID, msg)
    if type(msg) ~= "table" then return end

    local function reply(response)
        rednet.send(routerID, {type="routed_response", origin_id=originID, payload=response}, ROUTER_PROTOCOL)
    end

    if msg.type == "ping" then
        activeMiners[originID] = { name = msg.name or "RouterMiner", lastSeen = os.epoch("utc") }

    elseif msg.type == "mine_submit" then
        local acc = getAccount(msg.accountID)
        if acc then
            acc.balance = acc.balance + 0.00001
            acc.mined_total = (acc.mined_total or 0) + 0.00001
            saveAccount(acc)
        end

    elseif msg.type == "login" then
        local acc = getAccount(msg.accountID)
        if acc and acc.password == msg.password then
            reply({type="res", success=true, name=acc.name})
        else
            reply({type="res", success=false, error="Invalid Auth"})
        end

    elseif msg.type == "get_balance" then
        local acc = getAccount(msg.accountID)
        if acc and acc.password == msg.password then
            reply({type="res", balance=acc.balance})
        else
            reply({type="res", success=false, error="Invalid Auth"})
        end

    elseif msg.type == "transfer" then
        local sender   = getAccount(msg.accountID)
        local receiver = getAccount(msg.toID)
        if sender and receiver and sender.password == msg.password and sender.balance >= msg.amount then
            sender.balance   = sender.balance   - msg.amount
            receiver.balance = receiver.balance + msg.amount
            saveAccount(sender); saveAccount(receiver)
            reply({type="res", success=true})
            addLog("TRANSFER", {from=sender.name, to=receiver.name, amount=msg.amount})
        else
            reply({type="res", success=false, error="Transfer Failed"})
        end
    end
end

-- Auto-detect up to 2 wireless modems: first = private, second = public.
-- If only 1 modem is found, it handles both roles (degraded mode).
-- Also detects a wired modem on the bottom for PCrouter relay.
local privateModem, publicModem, wiredRouterModem
for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
        -- Wired modem on bottom is reserved for the PCrouter cable connection
        if side == "bottom" and m.isWireless and not m.isWireless() then
            wiredRouterModem = side
        elseif m.isWireless and m.isWireless() then
            if not privateModem then
                privateModem = side
            elseif not publicModem then
                publicModem = side
                break
            end
        end
    end
end

if not privateModem then
    error("No wireless modem found! Attach at least one wireless modem for private networking.")
end

rednet.open(privateModem)
print("Private modem: " .. privateModem)

if publicModem then
    rednet.open(publicModem)
    print("Public modem:  " .. publicModem)
else
    publicModem = privateModem
    print("WARNING: Only 1 wireless modem found. Public and private traffic share " .. privateModem)
end

-- Open wired modem (bottom) for PCrouter relay if present
if wiredRouterModem then
    rednet.open(wiredRouterModem)
    rednet.host(ROUTER_PROTOCOL, "CentralBank_Router")
    print("Wired router modem: " .. wiredRouterModem .. " (PCrouter relay active)")
else
    print("INFO: No wired modem on bottom - PCrouter relay disabled.")
end

rednet.host(PRIVATE_PORT, "CentralBank")

while true do
    broadcastToDisplays(); updateMonitor()
    term.clear(); term.setCursorPos(1,1); print("AMIcoin Central Bank | Logs: "..#transactionLogs)
    term.setCursorPos(1,18); term.write("[M] Mint | [C] Create User | [Q] Quit")
    
    local event, p1, p2, p3 = os.pullEvent()
    if event == "rednet_message" and p3 == PRIVATE_PORT then
        processMessage(p1, p2)
    elseif event == "rednet_message" and p3 == ROUTER_PROTOCOL then
        -- Message forwarded by PCrouter from a far-away miner
        if type(p2) == "table" and p2.type == "routed" and p2.origin_id and p2.payload then
            processRoutedMessage(p1, p2.origin_id, p2.payload)
        end
    elseif event == "key" then
        if p1 == keys.m then
            term.setCursorPos(1,10); term.write("Pass: "); if read("*") == MASTER_PASSWORD then
                term.write("ID: "); local tid = read(); term.write("Amt: "); local amt = tonumber(read())
                local acc = getAccount(tid); if acc and amt then acc.balance = acc.balance + amt; saveAccount(acc); addLog("MINT", {to=acc.name, amount=amt}); print("Minted!") end
            end
            sleep(1)
        elseif p1 == keys.c then
            term.setCursorPos(1,10); term.write("Name: "); local name = read(); term.write("Pass: "); local upw = read("*")
            local acc = createAccount(name, upw); term.clear(); print("ID: "..acc.accountID.."\nPress any key..."); os.pullEvent("key")
        elseif p1 == keys.q then break end
    end
end
