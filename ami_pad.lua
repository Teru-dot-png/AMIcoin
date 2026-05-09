--[[
    AMIcoin Client Pad (v4.1 - Stability Update)
    - Fix: Separate Private/Public protocol handling.
    - Improved timeout for slower server hardware.
--]]

local PRIVATE_PORT = "AMIcoin_Net"
local modemSide = nil

for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then modemSide = side; rednet.open(side) end
end
if not modemSide then error("No Modem!") end

local function findBank()
    term.clear(); term.setCursorPos(1,1); print("Connecting to AMIbank...")
    local id = rednet.lookup(PRIVATE_PORT, "CentralBank")
    if not id then sleep(2); return nil end
    return id
end

local bankID = findBank()
while not bankID do bankID = findBank() end

local session = { accountID = nil, password = nil, name = nil }

local function drawHeader()
    term.clear(); term.setCursorPos(1,1); term.setBackgroundColor(colors.green); term.setTextColor(colors.white)
    term.clearLine(); print(" AMIcoin Mobile - " .. (session.name or "Guest"))
    term.setBackgroundColor(colors.black)
end

local function login()
    drawHeader(); print("\n[LOGIN]"); write("AccountID: "); local id = read(); write("Password: "); local pw = read("*")
    rednet.send(bankID, {type="login", accountID=id, password=pw}, PRIVATE_PORT)
    local _, res = rednet.receive(PRIVATE_PORT, 5)
    if res and res.success then
        session.accountID = id; session.password = pw; session.name = res.name; return true
    else
        print("\nLogin Failed: "..(res and res.error or "No response")); sleep(2); return false
    end
end

local function getBalance()
    rednet.send(bankID, {type="get_balance", accountID=session.accountID, password=session.password}, PRIVATE_PORT)
    local _, res = rednet.receive(PRIVATE_PORT, 5)
    return res and string.format("%.6f", res.balance) or "Error"
end

while true do
    if not session.accountID then login() else
        drawHeader(); print("\nBalance: "..getBalance().." AMI")
        print("--------------------"); print("1. Send AMIcoin\n2. Start Mining\n3. Log Out")
        local _, char = os.pullEvent("char")
        if char == "1" then
            print("\nTo ID: "); local target = read(); print("Amount: "); local amt = tonumber(read())
            rednet.send(bankID, {type="transfer", accountID=session.accountID, password=session.password, toID=target, amount=amt}, PRIVATE_PORT)
            local _, res = rednet.receive(PRIVATE_PORT, 5)
            print(res and res.success and "Verified!" or "Failed: "..(res and res.error or "Timeout"))
            sleep(2)
        elseif char == "2" then
            print("\nMining... reward: 0.00001"); local lastPing = 0
            while true do
                if os.epoch("utc") - lastPing > 5000 then
                    rednet.send(bankID, {type="ping", accountID=session.accountID, name=session.name}, PRIVATE_PORT)
                    lastPing = os.epoch("utc")
                end
                if math.random(1, 1000) == 500 then
                    rednet.send(bankID, {type="mine_submit", accountID=session.accountID}, PRIVATE_PORT)
                    print(" +0.00001 AMI (Block Found)")
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
