--[[
    AMIcoin Miner Client (v1.0)
    Runs on each individual computer in the mining cluster.
    Connects to the MinerHub via a wired modem + cable.

    Physical setup:
      [MinerClient]--cable--[MinerHub]--ender modem--//--[PCrouter]--cable--[Bank]

    What it does:
      1. Asks for your AMIcoin account ID and password.
      2. Runs a continuous proof-of-work loop (hashing).
      3. When a valid hash is found, submits to the MinerHub.
      4. Hub verifies cooldown then credits your account directly.
      5. Displays live stats on screen.
]]

local PRIVATE_PORT    = "AMIcoin_Net"
local COOLDOWN_SEC    = 62      -- slightly over 60s to avoid edge-case rejections
local DIFFICULTY      = 4       -- number of leading zeroes required in hash
local TOKEN_WINDOW_MS = 300000  -- must match bank.lua TOKEN_WINDOW_MS

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
local SESSION_FILE = "miner_session.json"

local function saveSession(id, hash)
    local f = fs.open(SESSION_FILE, "w")
    f.write(textutils.serializeJSON({ accountID = id, pw_hash = hash }))
    f.close()
end

local function loadSession()
    if not fs.exists(SESSION_FILE) then return nil end
    local f    = fs.open(SESSION_FILE, "r")
    local data = textutils.unserializeJSON(f.readAll())
    f.close()
    return data
end

-- ── Identity + credentials ────────────────────────────────────────────────────
term.clear(); term.setCursorPos(1,1)
print("=== AMIcoin Miner Client ===")
local ACCOUNT_ID, PW_HASH
local saved = loadSession()
if saved and saved.accountID and saved.pw_hash then
    ACCOUNT_ID = saved.accountID
    PW_HASH    = saved.pw_hash
    print("Resumed session for account: " .. ACCOUNT_ID)
    sleep(1)
else
    term.write("Account ID : "); ACCOUNT_ID = read()
    term.write("Password   : "); PW_HASH    = fnv1a(read("*"))
    saveSession(ACCOUNT_ID, PW_HASH)
end
local MINER_LABEL = "Miner-" .. tostring(os.getComputerID())

-- Generates a time-based mine token (no raw password ever sent over network).
-- Token = fnv1a(pw_hash .. accountID .. bucket) where bucket = floor(epoch/TOKEN_WINDOW_MS).
local function mineToken()
    local bucket = math.floor(os.epoch("utc") / TOKEN_WINDOW_MS)
    return fnv1a(PW_HASH .. tostring(ACCOUNT_ID) .. tostring(bucket))
end

-- ── Modem detection ───────────────────────────────────────────────────────────
local wiredSide = nil
for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
        if m.isWireless and not m.isWireless() then
            wiredSide = side
            break
        end
    end
end

if not wiredSide then
    error("MinerClient: No wired modem found. Connect a cable from this computer to the MinerHub.")
end

rednet.open(wiredSide)

-- ── Proof-of-work ─────────────────────────────────────────────────────────────
-- Builds a simple hash by folding computer ID, time, nonce, and pi digits
-- into a hex-like string and checking for a run of leading zeroes.
-- This is intentionally lightweight for CC computers.

local PI = "14159265358979323846264338327950288419716939937510582097494459230781640628620899"

local function hashRound(data, nonce)
    local raw = tostring(os.computeID and os.computeID() or os.getComputerID())
              .. tostring(os.epoch("utc"))
              .. tostring(nonce)
              .. data
              .. PI:sub((nonce % 40) + 1, (nonce % 40) + 20)

    -- Mix: FNV-1a style using CC's bit library (Lua 5.1 compatible)
    local acc = 0x811c9dc5
    for i = 1, #raw do
        local b = raw:byte(i)
        acc = bit.band(bit.bxor(acc, b) * 0x01000193, 0xFFFFFFFF)
    end

    -- Spread into 8 hex digits via simple LCG steps
    local result = ""
    for _ = 1, 8 do
        acc = bit.band((acc * 1664525) + 1013904223, 0xFFFFFFFF)
        result = result .. string.format("%08x", acc)
    end
    return result
end

local function meetsDifficulty(hash)
    return hash:sub(1, DIFFICULTY) == string.rep("0", DIFFICULTY)
end

-- ── Stats ─────────────────────────────────────────────────────────────────────
local hashes     = 0
local accepted   = 0
local rejected   = 0
local startTime  = os.epoch("utc")
local lastSubmit = 0   -- epoch ms of last accepted submission
local nextAllowed = 0  -- epoch ms when cooldown expires

local function drawUI(status, hashStr)
    term.clear(); term.setCursorPos(1,1)
    local elapsed = math.max(1, math.floor((os.epoch("utc") - startTime) / 1000))
    local hashrate = math.floor(hashes / elapsed)

    if term.isColor and term.isColor() then term.setTextColor(colors.yellow) end
    print("=== AMIcoin Miner Client ===")
    if term.isColor and term.isColor() then term.setTextColor(colors.white) end
    print("Miner   : " .. MINER_LABEL .. " (" .. ACCOUNT_ID .. ")")
    print(string.format("Uptime  : %ds  |  Hashrate: %d H/s", elapsed, hashrate))
    print(string.format("Hashes  : %d", hashes))
    print(string.format("Accepted: %d  |  Rejected: %d", accepted, rejected))
    print("")
    if term.isColor and term.isColor() then
        term.setTextColor(status == "MINING" and colors.green
                          or status == "COOLDOWN" and colors.orange
                          or status == "SUBMITTED" and colors.cyan
                          or colors.red)
    end
    print("Status  : " .. status)
    if term.isColor and term.isColor() then term.setTextColor(colors.gray) end
    if hashStr then print("Hash    : " .. hashStr:sub(1,32) .. "...") end

    local now = os.epoch("utc")
    if nextAllowed > now then
        local wait = math.ceil((nextAllowed - now) / 1000)
        if term.isColor and term.isColor() then term.setTextColor(colors.orange) end
        print(string.format("Next in : %ds", wait))
    end
    if term.isColor and term.isColor() then term.setTextColor(colors.white) end
end

-- ── Main mining loop ──────────────────────────────────────────────────────────
print("Starting miner... (Ctrl+T to stop)")
sleep(1)

local nonce = math.random(0, 2^30)

while true do
    local now = os.epoch("utc")

    -- If we're still in cooldown, spin quietly until it expires
    if now < nextAllowed then
        local wait = math.ceil((nextAllowed - now) / 1000)
        drawUI("COOLDOWN", nil)
        sleep(1)

    else
        -- ── Hash loop: run for ~0.5s worth of iterations, then yield ────────
        local found     = false
        local foundHash = nil
        local batch     = 500  -- iterations per coroutine yield

        for _ = 1, batch do
            nonce = nonce + 1
            hashes = hashes + 1
            local h = hashRound(MINER_LABEL, nonce)
            if meetsDifficulty(h) then
                found     = true
                foundHash = h
                break
            end
        end

        if found then
            drawUI("SUBMITTED", foundHash)

            -- Submit to hub; token proves identity without exposing the password.
            rednet.broadcast({
                type        = "mine_submit",
                accountID   = ACCOUNT_ID,
                mine_token  = mineToken(),
                miner_label = MINER_LABEL,
            }, PRIVATE_PORT)

            -- Wait for hub acknowledgement (up to 5s)
            local hubID, ack = rednet.receive(PRIVATE_PORT, 5)

            if ack and ack.type == "mine_ack" then
                if ack.success then
                    accepted   = accepted + 1
                    lastSubmit = os.epoch("utc")
                    nextAllowed = lastSubmit + (COOLDOWN_SEC * 1000)
                    drawUI("ACCEPTED", foundHash)
                    sleep(1)
                else
                    rejected = rejected + 1
                    -- Hub told us how long to wait
                    local waitSec = ack.next_in or COOLDOWN_SEC
                    nextAllowed = os.epoch("utc") + (waitSec * 1000)
                    drawUI("COOLDOWN", nil)
                    sleep(1)
                end
            else
                -- No response from hub; back off a few seconds and retry
                drawUI("NO RESPONSE", nil)
                sleep(3)
            end
        else
            -- No solution yet; redraw UI every ~500 hashes
            drawUI("MINING", nil)
        end

        -- Yield so CC doesn't kill us for hogging the CPU
        sleep(0)
    end
end
