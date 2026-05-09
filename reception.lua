--[[
    AMIcoin Reception Computer
    - Listens for bank broadcasts.
    - Prints physical receipts if a printer is attached.
--]]

local PORT = "AMIcoin_Net"
local modemSide = nil

-- Detect Modem
for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        modemSide = side
        rednet.open(side)
        break
    end
end

if not modemSide then error("No modem found!") end

local function findPrinter()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "printer" then
            return peripheral.wrap(side)
        end
    end
    return nil
end

term.clear()
term.setCursorPos(1,1)
print("AMIcoin Reception Online")
print("Waiting for bank data...")

while true do
    local id, msg = rednet.receive(PORT)
    
    if msg and type(msg) == "table" and msg.type == "receipt" then
        local log = msg.data
        local printer = findPrinter()
        
        term.setTextColor(colors.yellow)
        print("\nNew Receipt: " .. log.type)
        term.setTextColor(colors.white)
        
        if printer then
            if printer.getPaperLevel() > 0 and printer.getInkLevel() > 0 then
                printer.newPage()
                printer.setCursorPos(1,1)
                printer.write("--- AMICOIN BANK ---")
                printer.setCursorPos(1,2)
                printer.write("DATE: " .. log.date)
                printer.setCursorPos(1,3)
                printer.write("TIME: " .. log.time)
                printer.setCursorPos(1,5)
                printer.write("TYPE: " .. log.type)
                
                local row = 6
                for k, v in pairs(log.details) do
                    printer.setCursorPos(1, row)
                    printer.write(string.upper(k) .. ": " .. tostring(v))
                    row = row + 1
                end
                
                printer.setCursorPos(1, 10)
                printer.write("--------------------")
                printer.endPage()
                print("Receipt printed successfully.")
            else
                print("Error: Printer out of paper or ink!")
            end
        else
            print("No printer attached. Details:")
            for k, v in pairs(log.details) do
                print(" " .. k .. ": " .. tostring(v))
            end
        end
    end
end
