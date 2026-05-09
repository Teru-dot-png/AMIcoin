--[[
    AMIcoin Miner Hub (v1.0)
    Central hub for a cluster of wired-modem-connected miner computers.
    Miners do crypto-style proof-of-work locally and submit to this hub.

    Physical setup:
      [Miner1]--cable--\
      [Miner2]--cable---[MinerHub]--ender modem--//--[PCrouter]--cable--[Bank]
      [Miner3]--cable--/

    How it works:
      • Each miner computer submits a "mine_submit" over the wired network.
      • The hub enforces a 60-second cooldown per individual miner computer ID.
      • Approved submissions are forwarded to the bank via the ender modem
        (through PCrouter if needed).
      • The hub sends periodic pings so the bank shows it as online.

    ── Miner-side protocol ───────────────────────────────────────────────────
    Miner  → Hub  :  { type="mine_submit", accountID="...", password="..." }
    Hub    → Miner:  { type="mine_ack", success=true/false, next_in=<seconds> }

    ── Hub → Bank protocol ───────────────────────────────────────────────────
    Hub broadcasts { type="mine_submit", accountID="...", password="..." }
    on PRIVATE_PORT via the ender modem so PCrouter relays it to the bank.
]]

local PRIVATE_PORT  = "AMIcoin_Net"
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

print("AMIcoin Miner Hub running")
print("  Wired (miners) : " .. wiredSide)
print("  Ender (bank)   : " .. enderSide)
print("  Cooldown       : " .. (COOLDOWN_MS / 1000) .. "s per miner")
print("")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function sendPing()
    rednet.broadcast({type = "ping", name = HUB_NAME}, PRIVATE_PORT)
end

local function forwardToBank(accountID, password)
    rednet.broadcast({
        type      = "mine_submit",
        accountID = accountID,
        password  = password,
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

                -- Forward miner's own credentials to the bank
                local accountID = msg.accountID or ""
                local password  = msg.password  or ""

                if accountID == "" then
                    -- No credentials supplied; reject
                    rednet.send(senderID, {
                        type    = "mine_ack",
                        success = false,
                        next_in = 0,
                    }, PRIVATE_PORT)
                    print(string.format("[%s] Miner #%d -> REJECTED (no credentials)", os.date("%H:%M:%S"), senderID))
                else
                    forwardToBank(accountID, password)
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
    end
end
