--[[
    AMIcoin Client Pad (v6.0 - Hub Relay Update)
    - Connects to MinerHub via ender modem instead of Bank directly.
    - Hub relays all requests to the bank and returns responses.
    - Mining goes through hub for proper cooldown enforcement.
--]]

local PAD_PORT        = "AMIcoin_Pad"
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

local function findHub()
    term.clear(); term.setCursorPos(1,1); print("Connecting to MinerHub...")
    local id = rednet.lookup(PAD_PORT, "MinerHub")
    if not id then sleep(2); return nil end
    return id
end

local hubID = findHub()
while not hubID do hubID = findHub() end

local session = { accountID = nil, pw_hash = nil, name = nil }

local function drawHeader()
    term.clear(); term.setCursorPos(1,1); term.setBackgroundColor(colors.green); term.setTextColor(colors.white)
    term.clearLine(); print(" AMIcoin Mobile - " .. (session.name or "Guest"))
    term.setBackgroundColor(colors.black)
end

local function login()
    drawHeader(); print("\n[LOGIN]"); write("AccountID: "); local id = read(); write("Password: "); local pw_hash = fnv1a(read("*"))
    rednet.send(hubID, {type="login", accountID=id, pw_hash=pw_hash}, PAD_PORT)
    local _, res = rednet.receive(PAD_PORT, 5)
    if res and res.success then
        session.accountID = id; session.pw_hash = pw_hash; session.name = res.name; return true
    else
        print("\nLogin Failed: "..(res and res.error or "No response")); sleep(2); return false
    end
end

local function getBalance()
    rednet.send(hubID, {type="get_balance", accountID=session.accountID, pw_hash=session.pw_hash}, PAD_PORT)
    local _, res = rednet.receive(PAD_PORT, 5)
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
            rednet.send(hubID, {type="transfer", accountID=session.accountID, pw_hash=session.pw_hash, toID=target, amount=amt}, PAD_PORT)
            local _, res = rednet.receive(PAD_PORT, 5)
            print(res and res.success and "Verified!" or "Failed: "..(res and res.error or "Timeout"))
            sleep(2)
        elseif char == "2" then
            print("\nMining... reward: 0.01 AMI"); local lastPing = 0
            while true do
                if os.epoch("utc") - lastPing > 5000 then
                    rednet.send(hubID, {type="ping", accountID=session.accountID, name=session.name}, PAD_PORT)
                    lastPing = os.epoch("utc")
                end
                if math.random(1, 1000) == 500 then
                    local label = "Pad-" .. tostring(os.getComputerID())
                    rednet.send(hubID, {type="mine_submit", accountID=session.accountID, mine_token=mineToken(), miner_label=label}, PAD_PORT)
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
        elseif char == "3" then session.accountID = nil end
    end
end
