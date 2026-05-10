--[[
    AMIcoin Miner Hub (v2.0 - Pad Relay Update)
    Central hub for a cluster of wired-modem-connected miner computers.
    Also acts as a relay for AMIcoin Pad (ender pocket computers).

    Physical setup:
      [Miner1]--cable--\
      [Miner2]--cable---[MinerHub]--ender modem--//--[Bank]
      [Miner3]--cable--/
      [PadUser]--------ender------//--[MinerHub]

    How it works:
      • Each miner computer submits a "mine_submit" over the wired network.
      • The hub enforces a 60-second cooldown per individual miner computer ID.
      • Approved mine submissions are forwarded to the bank via the ender modem.
      • Pad computers (AMIcoin Pad) connect via ender on PAD_PORT.
      • All pad requests (login, balance, transfer, mining) are relayed to the bank.

    ── Miner-side protocol (wired) ──────────────────────────────────────────
    Miner  → Hub  :  { type="mine_submit", accountID="...", mine_token="..." }
    Hub    → Miner:  { type="mine_ack", success=true/false, next_in=<seconds> }

    ── Pad-side protocol (ender) ────────────────────────────────────────────
    Pad    → Hub  :  any AMIcoin message (login, get_balance, transfer, mine_submit)
    Hub    → Bank :  same message, forwarded on PRIVATE_PORT
    Bank   → Hub  :  response
    Hub    → Pad  :  response forwarded back on PAD_PORT
]]

local PRIVATE_PORT  = "AMIcoin_Net"
local PAD_PORT      = "AMIcoin_Pad"
local COOLDOWN_MS   = 60000   -- 60 seconds between credits per miner
local PING_INTERVAL = 10      -- seconds between keepalive pings to bank

-- Hub identity
local HUB_NAME = "MinerHub"

term.clear(); term.setCursorPos(1,1)
print("=== AMIcoin Miner Hub ===")
print("Starting up...")
sleep(1)

-- ── State ─────────────────────────────────────────────────────────────────────
-- [minerComputerID] = epoch-ms of last accepted submission
local minerCooldowns = {}

-- ── Peripheral detection ──────────────────────────────────────────────────────
local wiredSide = nil   -- connects to miner computers via cable
local enderSide = nil   -- connects to PCrouter / bank via ender modem

for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
        if m.isWireless and not m.isWireless() then
            if not wiredSide then wiredSide = side end
        else
            if not enderSide then enderSide = side end
        end
    end
end

if not wiredSide then
    error("MinerHub: No wired modem found. Connect miners via cable to this computer.")
end
if not enderSide then
    error("MinerHub: No ender/wireless modem found. Attach one to reach PCrouter/bank.")
end

-- ── Open modems ───────────────────────────────────────────────────────────────
rednet.open(wiredSide)
rednet.open(enderSide)

-- ── Locate bank ───────────────────────────────────────────────────────────────
print("Looking up CentralBank...")
local bankID = rednet.lookup(PRIVATE_PORT, "CentralBank")
if not bankID then
    print("WARNING: Bank not found. Pad relay will be unavailable until bank is online.")
end

-- Host hub name so pads can find us via rednet.lookup
rednet.host(PAD_PORT, HUB_NAME)

print("AMIcoin Miner Hub running")
print("  Wired (miners) : " .. wiredSide)
print("  Ender (bank+pads): " .. enderSide)
print("  Cooldown       : " .. (COOLDOWN_MS / 1000) .. "s per miner")
print("  Bank ID        : " .. tostring(bankID))
print("")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function sendPing()
    rednet.broadcast({type = "ping", name = HUB_NAME}, PRIVATE_PORT)
end

local function forwardToBank(accountID, mine_token, miner_label)
    rednet.broadcast({
        type        = "mine_submit",
        accountID   = accountID,
        mine_token  = mine_token,
        miner_label = miner_label,
    }, PRIVATE_PORT)
end

local function statusLine(minerID, accepted, remaining)
    local tag = accepted and "ACCEPTED" or ("COOLDOWN " .. remaining .. "s")
    print(string.format("[%s] Miner #%d → %s", os.date("%H:%M:%S"), minerID, tag))
end

-- ── Start-up ping ─────────────────────────────────────────────────────────────
sendPing()
local pingTimer = os.startTimer(PING_INTERVAL)

-- ── Main loop ─────────────────────────────────────────────────────────────────
while true do
    local event, p1, p2, p3 = os.pullEvent()
    local now = os.epoch("utc")

    -- ── Ping timer ────────────────────────────────────────────────────────────
    if event == "timer" and p1 == pingTimer then
        sendPing()
        pingTimer = os.startTimer(PING_INTERVAL)

    -- ── Message from a local miner computer ──────────────────────────────────
    elseif event == "rednet_message" and p3 == PRIVATE_PORT then
        local senderID = p1
        local msg      = p2

        if type(msg) == "table" and msg.type == "mine_submit" then
            local lastSubmit = minerCooldowns[senderID] or 0
            local elapsed    = now - lastSubmit

            if elapsed >= COOLDOWN_MS then
                -- ── Cooldown cleared: accept and relay to bank ─────────────
                minerCooldowns[senderID] = now

                -- Forward miner's credentials to the bank
                local accountID  = msg.accountID  or ""
                local mine_token = msg.mine_token  or ""

                if accountID == "" then
                    -- No credentials supplied; reject
                    rednet.send(senderID, {
                        type    = "mine_ack",
                        success = false,
                        next_in = 0,
                    }, PRIVATE_PORT)
                    print(string.format("[%s] Miner #%d -> REJECTED (no credentials)", os.date("%H:%M:%S"), senderID))
                else
                    local miner_label = msg.miner_label or ("Miner-" .. tostring(senderID))
                forwardToBank(accountID, msg.mine_token or "", miner_label)
                    rednet.send(senderID, {
                        type    = "mine_ack",
                        success = true,
                        next_in = 0,
                    }, PRIVATE_PORT)
                    statusLine(senderID, true, 0)
                end

            else
                -- ── Still on cooldown ──────────────────────────────────────
                local remaining = math.ceil((COOLDOWN_MS - elapsed) / 1000)
                rednet.send(senderID, {
                    type    = "mine_ack",
                    success = false,
                    next_in = remaining,
                }, PRIVATE_PORT)

                statusLine(senderID, false, remaining)
            end
        end

    -- ── Message from a pad (ender side) ──────────────────────────────────────
    elseif event == "rednet_message" and p3 == PAD_PORT then
        local padID = p1
        local msg   = p2
        if type(msg) ~= "table" then
            -- ignore malformed
        elseif msg.type == "ping" then
            -- Forward keepalive to bank so the monitor shows the pad as online.
            if bankID then rednet.send(bankID, msg, PRIVATE_PORT) end
        elseif not bankID then
            -- Bank not yet found; try a fresh lookup then report offline.
            bankID = rednet.lookup(PRIVATE_PORT, "CentralBank")
            rednet.send(padID, {type="res", success=false, error="Bank offline"}, PAD_PORT)
        else
            -- Relay request to bank, wait for its response, forward back to pad.
            -- The inner pullEvent loop filters by bankID so miner messages on
            -- PRIVATE_PORT are not accidentally consumed during the wait.
            rednet.send(bankID, msg, PRIVATE_PORT)
            local resp = nil
            local relayTimer = os.startTimer(3)
            while not resp do
                local ev, a, b, c = os.pullEvent()
                if ev == "rednet_message" and a == bankID and c == PRIVATE_PORT then
                    resp = b
                elseif ev == "timer" and a == relayTimer then
                    break
                end
            end
            if resp then
                rednet.send(padID, resp, PAD_PORT)
            else
                local fallback = (msg.type == "mine_submit")
                    and {type="mine_ack", success=false, error="Bank timeout"}
                    or  {type="res",      success=false, error="Bank timeout"}
                rednet.send(padID, fallback, PAD_PORT)
            end
            print(string.format("[%s] Pad #%d -> %s", os.date("%H:%M:%S"), padID, msg.type or "?"))
        end
    end
end
