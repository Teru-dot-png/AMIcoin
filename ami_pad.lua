--[[
    AMIcoin Client Pad (v7.0 - Session Save & Mouse Support)
    - Saves login session to disk; resumes automatically on restart.
    - Refresh Balance button added to main menu.
    - Mouse click support on all menu items.
--]]

local PAD_PORT        = "AMIcoin_Pad"
local TOKEN_WINDOW_MS = 300000  -- must match bank.lua TOKEN_WINDOW_MS
local SESSION_FILE    = "ami_session.json"
local modemSide       = nil

for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then modemSide = side; rednet.open(side) end
end
if not modemSide then error("No Modem!") end

-- ── Crypto: FNV-1a hash (Lua 5.1 / CC:Tweaked compatible) ────────────────────
local function fnv1a(str)
    local acc = 0x811c9dc5
    for i = 1, #str do
        local b = str:byte(i)
        acc = bit.band(bit.bxor(acc, b) * 0x01000193, 0xFFFFFFFF)
    end
    return string.format("%08x", acc)
end

-- ── Session persistence ───────────────────────────────────────────────────────
local function saveSession(s)
    local f = fs.open(SESSION_FILE, "w")
    f.write(textutils.serializeJSON({ accountID = s.accountID, pw_hash = s.pw_hash, name = s.name }))
    f.close()
end

local function loadSession()
    if not fs.exists(SESSION_FILE) then return nil end
    local f    = fs.open(SESSION_FILE, "r")
    local data = textutils.unserializeJSON(f.readAll())
    f.close()
    return data
end

local function clearSession()
    if fs.exists(SESSION_FILE) then fs.delete(SESSION_FILE) end
end

local function findHub()
    term.clear(); term.setCursorPos(1,1); print("Connecting to MinerHub...")
    local id = rednet.lookup(PAD_PORT, "MinerHub")
    if not id then sleep(2); return nil end
    return id
end

local hubID = findHub()
while not hubID do hubID = findHub() end

-- ── Session (auto-load from disk if available) ────────────────────────────────
local session = { accountID = nil, pw_hash = nil, name = nil }
do
    local saved = loadSession()
    if saved and saved.accountID and saved.pw_hash then
        session.accountID = saved.accountID
        session.pw_hash   = saved.pw_hash
        session.name      = saved.name or "?"
    end
end

-- ── UI helpers ────────────────────────────────────────────────────────────────
local MENU_START_ROW = 5   -- screen row of the first menu item

local function drawHeader()
    term.clear(); term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.green); term.setTextColor(colors.white)
    term.clearLine(); print(" AMIcoin Mobile - " .. (session.name or "Guest"))
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
end

local function login()
    drawHeader(); print("\n[LOGIN]")
    write("AccountID: "); local id = read()
    write("Password : "); local pw_hash = fnv1a(read("*"))
    rednet.send(hubID, { type = "login", accountID = id, pw_hash = pw_hash }, PAD_PORT)
    local _, res = rednet.receive(PAD_PORT, 5)
    if res and res.success then
        session.accountID = id; session.pw_hash = pw_hash; session.name = res.name
        saveSession(session)
        return true
    else
        print("\nLogin Failed: " .. (res and res.error or "No response")); sleep(2); return false
    end
end

local function getBalance()
    rednet.send(hubID, { type = "get_balance", accountID = session.accountID, pw_hash = session.pw_hash }, PAD_PORT)
    local _, res = rednet.receive(PAD_PORT, 5)
    return res and string.format("%.6f", res.balance) or "Error"
end

local function mineToken()
    local bucket = math.floor(os.epoch("utc") / TOKEN_WINDOW_MS)
    return fnv1a(session.pw_hash .. tostring(session.accountID) .. tostring(bucket))
end

local function drawMenu(balance)
    drawHeader()
    term.setCursorPos(1, 2); print("\nBalance: " .. balance .. " AMI")
    print("--------------------")
    -- items start at MENU_START_ROW (row 5)
    print("1. Send AMIcoin")
    print("2. Start Mining")
    print("3. Refresh Balance")
    print("4. Log Out")
end

-- Returns "1"/"2"/"3"/"4" if the clicked row maps to a menu item, else nil.
local function rowToChoice(y)
    local idx = y - MENU_START_ROW + 1
    if idx >= 1 and idx <= 4 then return tostring(idx) end
    return nil
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
while true do
    if not session.accountID then
        login()
    else
        local balance = getBalance()
        drawMenu(balance)
        local event, p1, p2, p3 = os.pullEvent()
        local choice = nil
        if event == "char" then
            choice = p1
        elseif event == "mouse_click" then
            choice = rowToChoice(p3)   -- p3 = y coordinate
        end

        if choice == "1" then
            print("\nTo ID: ");  local target = read()
            print("Amount: ");  local amt    = tonumber(read())
            rednet.send(hubID, { type = "transfer", accountID = session.accountID, pw_hash = session.pw_hash, toID = target, amount = amt }, PAD_PORT)
            local _, res = rednet.receive(PAD_PORT, 5)
            print(res and res.success and "Verified!" or "Failed: " .. (res and res.error or "Timeout"))
            sleep(2)

        elseif choice == "2" then
            print("\nMining... reward: 0.01 AMI")
            local lastPing = 0
            while true do
                if os.epoch("utc") - lastPing > 5000 then
                    rednet.send(hubID, { type = "ping", accountID = session.accountID, name = session.name }, PAD_PORT)
                    lastPing = os.epoch("utc")
                end
                if math.random(1, 1000) == 500 then
                    local label = "Pad-" .. tostring(os.getComputerID())
                    rednet.send(hubID, { type = "mine_submit", accountID = session.accountID, mine_token = mineToken(), miner_label = label }, PAD_PORT)
                    local _, ack = rednet.receive(PAD_PORT, 5)
                    if ack and ack.success then
                        print(" +0.01 AMI (Block Found)")
                        sleep(60)
                    elseif ack and ack.next_in then
                        print(" Cooldown: " .. ack.next_in .. "s")
                        sleep(math.min(ack.next_in, 60))
                    else
                        print(" No response from hub")
                    end
                end
                sleep(0.1)
            end

        elseif choice == "3" then
            -- balance refreshed automatically at the top of the next iteration

        elseif choice == "4" then
            session.accountID = nil
            clearSession()
        end
    end
end
