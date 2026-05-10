--[[
    AMIcoin Client Pad (v5.0 - Security Update)
    - Security: Passwords hashed (FNV-1a) before transmission; never sent in plaintext.
    - Security: Mining uses a time-based token instead of a password.
    - Fix: Separate Private/Public protocol handling.
    - Improved timeout for slower server hardware.
--]]

local PRIVATE_PORT    = "AMIcoin_Net"
local TOKEN_WINDOW_MS = 300000  -- must match bank.lua TOKEN_WINDOW_MS
local modemSide = nil

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

local function findBank()
    term.clear(); term.setCursorPos(1,1); print("Connecting to AMIbank...")
    local id = rednet.lookup(PRIVATE_PORT, "CentralBank")
    if not id then sleep(2); return nil end
    return id
end

local bankID = findBank()
while not bankID do bankID = findBank() end

local session = { accountID = nil, pw_hash = nil, name = nil }

local function drawHeader()
    term.clear(); term.setCursorPos(1,1); term.setBackgroundColor(colors.green); term.setTextColor(colors.white)
    term.clearLine(); print(" AMIcoin Mobile - " .. (session.name or "Guest"))
    term.setBackgroundColor(colors.black)
end

local function login()
    drawHeader(); print("\n[LOGIN]"); write("AccountID: "); local id = read(); write("Password: "); local pw_hash = fnv1a(read("*"))
    rednet.send(bankID, {type="login", accountID=id, pw_hash=pw_hash}, PRIVATE_PORT)
    local _, res = rednet.receive(PRIVATE_PORT, 5)
    if res and res.success then
        session.accountID = id; session.pw_hash = pw_hash; session.name = res.name; return true
    else
        print("\nLogin Failed: "..(res and res.error or "No response")); sleep(2); return false
    end
end

local function getBalance()
    rednet.send(bankID, {type="get_balance", accountID=session.accountID, pw_hash=session.pw_hash}, PRIVATE_PORT)
    local _, res = rednet.receive(PRIVATE_PORT, 5)
    return res and string.format("%.6f", res.balance) or "Error"
end

-- Generates a time-based mine token (no password sent over the network).
local function mineToken()
    local bucket = math.floor(os.epoch("utc") / TOKEN_WINDOW_MS)
    return fnv1a(session.pw_hash .. tostring(session.accountID) .. tostring(bucket))
end

while true do
    if not session.accountID then login() else
        drawHeader(); print("\nBalance: "..getBalance().." AMI")
        print("--------------------"); print("1. Send AMIcoin\n2. Start Mining\n3. Log Out")
        local _, char = os.pullEvent("char")
        if char == "1" then
            print("\nTo ID: "); local target = read(); print("Amount: "); local amt = tonumber(read())
            rednet.send(bankID, {type="transfer", accountID=session.accountID, pw_hash=session.pw_hash, toID=target, amount=amt}, PRIVATE_PORT)
            local _, res = rednet.receive(PRIVATE_PORT, 5)
            print(res and res.success and "Verified!" or "Failed: "..(res and res.error or "Timeout"))
            sleep(2)
        elseif char == "2" then
            print("\nMining... reward: 0.01 AMI"); local lastPing = 0
            while true do
                if os.epoch("utc") - lastPing > 5000 then
                    rednet.send(bankID, {type="ping", accountID=session.accountID, name=session.name}, PRIVATE_PORT)
                    lastPing = os.epoch("utc")
                end
                if math.random(1, 1000) == 500 then
                    rednet.send(bankID, {type="mine_submit", accountID=session.accountID, mine_token=mineToken()}, PRIVATE_PORT)
                    print(" +0.01 AMI (Block Found)")
                    for i = 60, 1, -1 do
                        if i % 5 == 0 then rednet.send(bankID, {type="ping", accountID=session.accountID, name=session.name}, PRIVATE_PORT) end
                        sleep(1)
                    end
                end
                sleep(0.1)
            end
        elseif char == "3" then session.accountID = nil end
    end
end
