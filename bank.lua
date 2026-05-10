--[[
    AMIcoin Central Bank Server (v9.0 - Security & Quality Update)
    - Security: FNV-1a password hashing; plaintext passwords never travel the network.
    - Security: Time-based mine tokens replace password in mine_submit messages.
    - Security: Server-side per-account mining cooldown (hub-bypass-proof).
    - Security: Transfer amounts validated > 0; both accounts verified before debit.
    - Feature:  Mining rewards now appear in the transaction log.
    - Feature:  Stale miner entries auto-pruned from memory (no more leak).
    - Quality:  MINE_REWARD constant — one place to change the reward value.
    - Quality:  Single unified handleMessage() replaces two near-identical handlers.
    - Quality:  Transparent migration: old plain-text password accounts upgrade on
                first successful login without requiring any manual intervention.
--]]

-- ── Constants ─────────────────────────────────────────────────────────────────
local MASTER_PASSWORD    = "SomemoreIsNeverEnough"
local MINE_REWARD        = 0.01
local MINING_COOLDOWN_MS = 60000   -- server-side: 60 s between credits per account
local MINER_STALE_MS     = 30000   -- drop miner from display after 30 s of silence
local TOKEN_WINDOW_MS    = 300000  -- 5-minute bucket for time-based mine tokens

local PRIVATE_PORT    = "AMIcoin_Net"
local PUBLIC_PORT     = "AMIcoin_Public"
local ROUTER_PROTOCOL = "AMIcoin_Router"
local ACCOUNTS_DIR    = "accounts/"
local STATS_FILE      = "bank_stats.json"
local LOG_FILE        = "transactions.json"
local MONITOR_SIDE    = "right"

local PI_DIGITS = "14159265358979323846264338327950288419716939937510"

if not fs.exists(ACCOUNTS_DIR) then fs.makeDir(ACCOUNTS_DIR) end

-- ── State ─────────────────────────────────────────────────────────────────────
local bankStats       = { placement = 1 }
local transactionLogs = {}
local activeMiners    = {}   -- [computerID] = { name, lastSeen }
local miningCooldowns = {}   -- [accountID]  = epoch-ms of last credit
local lastBroadcast   = 0

-- ── Crypto: FNV-1a hash (Lua 5.1 / CC:Tweaked compatible) ────────────────────
local function fnv1a(str)
    local acc = 0x811c9dc5
    for i = 1, #str do
        local b = str:byte(i)
        acc = bit.band(bit.bxor(acc, b) * 0x01000193, 0xFFFFFFFF)
    end
    return string.format("%08x", acc)
end

-- Returns the stored password hash for an account.
-- Supports old accounts that still carry a plain-text "password" field.
local function getHash(acc)
    return acc.password_hash or fnv1a(acc.password or "")
end

-- Checks whether the client-supplied pw_hash matches the account.
local function checkAuth(acc, pw_hash)
    return type(pw_hash) == "string" and pw_hash == getHash(acc)
end

-- Upgrades an old plain-text password to hashed storage in place.
-- Caller must saveAccount() afterwards.
local function migratePassword(acc, pw_hash)
    if not acc.password_hash then
        acc.password_hash = pw_hash
        acc.password      = nil
    end
end

-- Verifies a time-based mine token.
-- Token = fnv1a(pw_hash .. accountID .. bucket)
-- where bucket = floor(epoch / TOKEN_WINDOW_MS).
-- Accepts the current bucket and the previous one to handle edge-case submissions.
local function verifyMineToken(acc, token)
    if type(token) ~= "string" then return false end
    local pw_hash  = getHash(acc)
    local bucket   = math.floor(os.epoch("utc") / TOKEN_WINDOW_MS)
    local exp_cur  = fnv1a(pw_hash .. tostring(acc.accountID) .. tostring(bucket))
    local exp_prev = fnv1a(pw_hash .. tostring(acc.accountID) .. tostring(bucket - 1))
    return token == exp_cur or token == exp_prev
end

-- ── Persistence ───────────────────────────────────────────────────────────────
local function loadData()
    if fs.exists(STATS_FILE) then
        local f = fs.open(STATS_FILE, "r")
        bankStats = textutils.unserializeJSON(f.readAll()) or { placement = 1 }
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

local function addLog(logType, details)
    local entry = {
        time    = os.date("%H:%M:%S"),
        date    = os.date("%d/%m/%y"),
        type    = logType,
        details = details,
    }
    table.insert(transactionLogs, 1, entry)
    if #transactionLogs > 100 then table.remove(transactionLogs) end
    saveData()
    rednet.broadcast({ type = "receipt", data = entry }, PUBLIC_PORT)
end

-- ── Account management ────────────────────────────────────────────────────────
local function generateAccountID()
    local t        = os.time()
    local date     = os.date("*t")
    local dayName  = os.date("%A")
    local piStart  = math.random(1, #PI_DIGITS - 3)
    local piSnippet = PI_DIGITS:sub(piStart, piStart + 2)
    local baseNum  = (tonumber(tostring(t) .. piSnippet .. tostring(date.month)) or 0) * bankStats.placement
    local finalStr = tostring(baseNum)
    local result   = ""
    local weekIdx  = 1
    for i = 1, #finalStr do
        result = result .. finalStr:sub(i, i)
        if i % 2 == 0 and weekIdx <= #dayName then
            result  = result .. dayName:sub(weekIdx, weekIdx)
            weekIdx = weekIdx + 1
        end
    end
    if fs.exists(ACCOUNTS_DIR .. result .. ".json") then return generateAccountID() end
    return result
end

local function getAccount(id)
    local path = ACCOUNTS_DIR .. tostring(id) .. ".json"
    if not fs.exists(path) then return nil end
    local f    = fs.open(path, "r")
    local data = textutils.unserializeJSON(f.readAll())
    f.close()
    return data
end

local function saveAccount(account)
    local f = fs.open(ACCOUNTS_DIR .. account.accountID .. ".json", "w")
    f.write(textutils.serializeJSON(account))
    f.close()
end

-- pw_hash: FNV-1a hash of the raw password (computed on the client side).
local function createAccount(name, pw_hash)
    local acc = {
        name          = name,
        password_hash = pw_hash,
        accountID     = generateAccountID(),
        balance       = 0,
        mined_total   = 0,
        time_created  = os.date("%H:%M %d/%m/%Y"),
    }
    saveAccount(acc)
    bankStats.placement = bankStats.placement + 1
    saveData()
    addLog("NEW_ACC", { name = name, id = acc.accountID })
    return acc
end

-- ── Display helpers ───────────────────────────────────────────────────────────
local function pruneStaleMiner()
    local now = os.epoch("utc")
    for id, data in pairs(activeMiners) do
        if now - data.lastSeen > MINER_STALE_MS then
            activeMiners[id] = nil
        end
    end
end

local function updateMonitor()
    local m = peripheral.wrap(MONITOR_SIDE)
    if not m or not m.clear then return end
    local accounts = {}
    for _, file in ipairs(fs.list(ACCOUNTS_DIR)) do
        if file:sub(-5) == ".json" then
            local data = getAccount(file:sub(1, -6))
            if data then table.insert(accounts, { name = data.name, balance = data.balance }) end
        end
    end
    table.sort(accounts, function(a, b) return (a.balance or 0) > (b.balance or 0) end)
    m.setTextScale(1)
    if m.isColor and m.isColor() then m.setBackgroundColor(colors.black) end
    m.clear()
    m.setCursorPos(1, 1)
    if m.isColor and m.isColor() then m.setTextColor(colors.yellow) end
    m.write("== TOP WHALES ==")
    for i = 1, math.min(5, #accounts) do
        m.setCursorPos(1, i + 1)
        if m.isColor and m.isColor() then m.setTextColor(colors.white) end
        m.write(string.format("%d. %-8s: %.5f", i, accounts[i].name, accounts[i].balance))
    end
    local minerRow = 8
    m.setCursorPos(1, minerRow)
    if m.isColor and m.isColor() then m.setTextColor(colors.green) end
    m.write("== MINERS ONLINE ==")
    local now = os.epoch("utc")
    local mCount = 0
    for id, data in pairs(activeMiners) do
        if now - data.lastSeen < MINER_STALE_MS and mCount < 4 then
            m.setCursorPos(1, minerRow + 1 + mCount)
            if m.isColor and m.isColor() then m.setTextColor(colors.white) end
            m.write(" > " .. data.name)
            mCount = mCount + 1
        end
    end
    local logRow = 14
    m.setCursorPos(1, logRow)
    if m.isColor and m.isColor() then m.setTextColor(colors.cyan) end
    m.write("== RECENT LOGS ==")
    for i = 1, 5 do
        local log = transactionLogs[i]
        if log then
            m.setCursorPos(1, logRow + i)
            if m.isColor and m.isColor() then m.setTextColor(colors.gray) end
            local txt = log.type == "TRANSFER"
                and (log.details.from .. "->" .. log.details.to)
                or  log.type
            m.write(string.format("%s: %s", log.time, txt))
        end
    end
end

local function broadcastToDisplays()
    if os.epoch("utc") - lastBroadcast < 5000 then return end
    local sync = {}
    for _, file in ipairs(fs.list(ACCOUNTS_DIR)) do
        if file:sub(-5) == ".json" then
            local acc = getAccount(file:sub(1, -6))
            if acc then
                table.insert(sync, { name = acc.name, balance = acc.balance, mined_total = acc.mined_total or 0 })
            end
        end
    end
    rednet.broadcast({ type = "display_update", accounts = sync }, PUBLIC_PORT)
    lastBroadcast = os.epoch("utc")
end

-- ── Unified message handler ───────────────────────────────────────────────────
-- senderID : network computer ID (used only for activeMiners tracking).
-- msg      : the decoded message table.
-- reply(t) : callback that sends a response back to the original sender.
local function handleMessage(senderID, msg, reply)
    if type(msg) ~= "table" then return end

    if msg.type == "ping" then
        activeMiners[senderID] = { name = msg.name or "Unknown", lastSeen = os.epoch("utc") }

    elseif msg.type == "mine_submit" then
        local acc = getAccount(msg.accountID)
        if not acc then
            reply({ type = "mine_ack", success = false, error = "Account not found" })
            return
        end
        -- Verify time-based token — password is never transmitted for mining.
        if not verifyMineToken(acc, msg.mine_token) then
            reply({ type = "mine_ack", success = false, error = "Invalid token" })
            return
        end
        -- Server-side cooldown — cannot be bypassed by skipping the hub.
        local now        = os.epoch("utc")
        local lastCredit = miningCooldowns[acc.accountID] or 0
        if now - lastCredit < MINING_COOLDOWN_MS then
            local remaining = math.ceil((MINING_COOLDOWN_MS - (now - lastCredit)) / 1000)
            reply({ type = "mine_ack", success = false, next_in = remaining, error = "Cooldown" })
            return
        end
        -- Credit the account.
        miningCooldowns[acc.accountID] = now
        acc.balance     = acc.balance     + MINE_REWARD
        acc.mined_total = (acc.mined_total or 0) + MINE_REWARD
        saveAccount(acc)
        addLog("MINE", { account = acc.name, amount = MINE_REWARD })
        reply({ type = "mine_ack", success = true })

    elseif msg.type == "login" then
        local acc = getAccount(msg.accountID)
        if not acc or not checkAuth(acc, msg.pw_hash) then
            reply({ type = "res", success = false, error = "Invalid Auth" })
            return
        end
        migratePassword(acc, msg.pw_hash)
        saveAccount(acc)
        reply({ type = "res", success = true, name = acc.name })

    elseif msg.type == "get_balance" then
        local acc = getAccount(msg.accountID)
        if not acc or not checkAuth(acc, msg.pw_hash) then
            reply({ type = "res", success = false, error = "Invalid Auth" })
            return
        end
        reply({ type = "res", balance = acc.balance })

    elseif msg.type == "transfer" then
        local amt = tonumber(msg.amount)
        if not amt or amt <= 0 then
            reply({ type = "res", success = false, error = "Invalid amount" })
            return
        end
        local sender   = getAccount(msg.accountID)
        local receiver = getAccount(msg.toID)
        if not sender or not receiver then
            reply({ type = "res", success = false, error = "Account not found" })
            return
        end
        if not checkAuth(sender, msg.pw_hash) then
            reply({ type = "res", success = false, error = "Invalid Auth" })
            return
        end
        if sender.balance < amt then
            reply({ type = "res", success = false, error = "Insufficient funds" })
            return
        end
        sender.balance   = sender.balance   - amt
        receiver.balance = receiver.balance + amt
        saveAccount(sender)
        saveAccount(receiver)
        reply({ type = "res", success = true })
        addLog("TRANSFER", { from = sender.name, to = receiver.name, amount = amt })
    end
end

-- ── Modem setup ───────────────────────────────────────────────────────────────
local privateModem, publicModem, wiredRouterModem
for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
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

if wiredRouterModem then
    rednet.open(wiredRouterModem)
    rednet.host(ROUTER_PROTOCOL, "CentralBank_Router")
    print("Wired router modem: " .. wiredRouterModem .. " (PCrouter relay active)")
else
    print("INFO: No wired modem on bottom - PCrouter relay disabled.")
end

rednet.host(PRIVATE_PORT, "CentralBank")

-- ── Main loop ─────────────────────────────────────────────────────────────────
while true do
    broadcastToDisplays()
    updateMonitor()
    pruneStaleMiner()

    term.clear(); term.setCursorPos(1, 1)
    local minerCount = 0
    for _ in pairs(activeMiners) do minerCount = minerCount + 1 end
    print(string.format("AMIcoin Central Bank v9 | Logs: %d | Miners online: %d",
        #transactionLogs, minerCount))
    term.setCursorPos(1, 18)
    term.write("[M] Mint | [C] Create User | [Q] Quit")

    local event, p1, p2, p3 = os.pullEvent()

    if event == "rednet_message" and p3 == PRIVATE_PORT then
        local senderID = p1
        handleMessage(senderID, p2, function(resp)
            rednet.send(senderID, resp, PRIVATE_PORT)
        end)

    elseif event == "rednet_message" and p3 == ROUTER_PROTOCOL then
        if type(p2) == "table" and p2.type == "routed" and p2.origin_id and p2.payload then
            local routerID = p1
            local originID = p2.origin_id
            handleMessage(originID, p2.payload, function(resp)
                rednet.send(routerID, {
                    type      = "routed_response",
                    origin_id = originID,
                    payload   = resp,
                }, ROUTER_PROTOCOL)
            end)
        end

    elseif event == "key" then
        if p1 == keys.m then
            term.setCursorPos(1, 10)
            term.write("Master pass: ")
            if read("*") == MASTER_PASSWORD then
                term.write("Account ID: "); local tid = read()
                term.write("Amount: ");     local amt = tonumber(read())
                local acc = getAccount(tid)
                if acc and amt and amt > 0 then
                    acc.balance = acc.balance + amt
                    saveAccount(acc)
                    addLog("MINT", { to = acc.name, amount = amt })
                    print("Minted " .. amt .. " AMI to " .. acc.name)
                else
                    print("Invalid account or amount.")
                end
            else
                print("Wrong master password.")
            end
            sleep(1)

        elseif p1 == keys.c then
            term.setCursorPos(1, 10)
            term.write("Name: ");     local name = read()
            term.write("Password: "); local upw  = read("*")
            local pw_hash = fnv1a(upw)
            local acc = createAccount(name, pw_hash)
            term.clear()
            print("Account created!")
            print("Name: " .. acc.name)
            print("ID  : " .. acc.accountID)
            print("Press any key...")
            os.pullEvent("key")

        elseif p1 == keys.q then
            break
        end
    end
end
