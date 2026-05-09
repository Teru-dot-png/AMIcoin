--[[
    AMIcoin PCrouter (v1.0)
    Relay computer bridging the Central Bank (wired cable) to
    far-away miners/hubs using ender modems (unlimited range).

    Physical setup:
      [Bank computer]--cable--[PCrouter]--ender modem--//--[MinerHub]

    Protocols:
      PRIVATE_PORT    - miner traffic (ender side)
      ROUTER_PROTOCOL - bank ↔ router traffic (wired side)

    How it works:
      1. Miner sends a message on PRIVATE_PORT via ender modem.
      2. PCrouter wraps it in a "routed" envelope and forwards to bank
         over the wired network on ROUTER_PROTOCOL.
      3. Bank processes the message, sends a "routed_response" back.
      4. PCrouter unwraps it and sends the original response to the
         miner over the ender modem.
]]

local PRIVATE_PORT    = "AMIcoin_Net"
local ROUTER_PROTOCOL = "AMIcoin_Router"

-- ── Peripheral detection ────────────────────────────────────────────────────

local wiredSide  = nil   -- cable to bank
local enderSides = {}    -- one or more ender / wireless modems for miners

for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
        if m.isWireless and not m.isWireless() then
            -- Wired modem → bank cable
            if not wiredSide then wiredSide = side end
        else
            -- Wireless / ender modem → miner side
            table.insert(enderSides, side)
        end
    end
end

if not wiredSide then
    error("PCrouter: No wired modem found. Connect a wired modem toward the bank cable.")
end
if #enderSides == 0 then
    error("PCrouter: No ender/wireless modems found. Attach at least one for miner connections.")
end

-- ── Open all modems ──────────────────────────────────────────────────────────

rednet.open(wiredSide)
for _, side in ipairs(enderSides) do
    rednet.open(side)
end

-- ── Locate the bank on the wired network ────────────────────────────────────

print("PCrouter: Looking up CentralBank_Router on wired network...")
local bankID = rednet.lookup(ROUTER_PROTOCOL, "CentralBank_Router")
if not bankID then
    error("PCrouter: Cannot find CentralBank_Router. Make sure bank.lua is running and has a wired modem on its bottom side.")
end

print("PCrouter ready.")
print("  Wired side  : " .. wiredSide .. " → Bank ID " .. bankID)
print("  Ender sides : " .. table.concat(enderSides, ", "))
print("  Relaying    : " .. PRIVATE_PORT .. " ↔ " .. ROUTER_PROTOCOL)

-- ── Main relay loop ──────────────────────────────────────────────────────────

while true do
    local event, senderID, msg, protocol = os.pullEvent("rednet_message")

    if protocol == PRIVATE_PORT then
        -- ── Inbound: miner → bank ──────────────────────────────────────────
        -- Wrap the original message in a routing envelope so the bank knows
        -- which computer originally sent it (origin_id).
        rednet.send(bankID, {
            type      = "routed",
            origin_id = senderID,
            payload   = msg,
        }, ROUTER_PROTOCOL)

    elseif protocol == ROUTER_PROTOCOL then
        -- ── Inbound: bank → miner (response) ──────────────────────────────
        if type(msg) == "table"
           and msg.type      == "routed_response"
           and msg.origin_id
           and msg.payload   then
            -- Forward the unwrapped response to the original miner
            rednet.send(msg.origin_id, msg.payload, PRIVATE_PORT)
        end
    end
end
