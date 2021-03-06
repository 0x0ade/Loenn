local utils = require("utils")
local binfile = require("binfile")

local mapcoder = {}

function mapcoder.look(fh, lookup)
    return lookup[binfile.readShort(fh) + 1]
end

local decodeFunctions = {
    binfile.readBool,
    binfile.readByte,
    binfile.readSignedShort,
    binfile.readSignedLong,
    binfile.readFloat
}

local typeHeaders = {
    bool = 0,
    byte = 1,
    signedShort = 2,
    signedLong = 3,
    float32 = 4,
    stringLookup = 5,
    string = 6,
    runLengthEncoded = 7
}

local function decodeValue(fh, lookup, typ)
    if typ >= 0 and typ <= 4 then
        return decodeFunctions[typ + 1](fh)

    elseif typ == 5 then
        return mapcoder.look(fh, lookup)

    elseif typ == 6 then
        return binfile.readString(fh)

    elseif typ == 7 then
        return binfile.readRunLengthEncoded(fh)
    end
end

local function decodeElement(fh, lookup)
    coroutine.yield()

    local name = mapcoder.look(fh, lookup)
    local element = {__name=name}
    local attributeCount = binfile.readByte(fh)

    for i = 1, attributeCount do
        local key = mapcoder.look(fh, lookup)
        local typ = binfile.readByte(fh)

        local value = decodeValue(fh, lookup, typ)

        if key then
            element[key] = value
        end
    end

    local elementCount = binfile.readShort(fh)

    if elementCount > 0 then
        element.__children = {}

        for i = 1, elementCount do
            table.insert(element.__children, decodeElement(fh, lookup))
        end
    end

    return element
end

function mapcoder.decodeFile(path, header)
    header = header or "CELESTE MAP"

    local fh = io.open(path, "rb")
    local res = {}

    if not fh then
        return false, "File not found"
    end

    if #header > 0 and binfile.readString(fh) ~= header then
        return false, "Invalid Celeste map file"
    end

    local package = binfile.readString(fh)

    local lookupLength = binfile.readShort(fh)
    local lookup = {}

    for i = 1, lookupLength do
        table.insert(lookup, binfile.readString(fh))
    end

    res = decodeElement(fh, lookup)
    res._package = package

    fh:close()

    coroutine.yield("update", res)

    return res
end

local function countStrings(data, seen)
    seen = seen or {}

    local name = data.__name or ""
    local children = data.__children or {}

    seen[name] = (seen[name] or 0) + 1

    for k, v in pairs(data) do
        if type(k) == "string" and k ~= "__name" and k ~= "__children" then
            seen[k] = (seen[k] or 0) + 1
        end

        if type(v) == "string" and k ~= "innerText" then
            seen[v] = (seen[v] or 0) + 1
        end
    end

    for i, child in ipairs(children) do
        countStrings(child, seen)
    end

    return seen
end

local integerBits = {
    {typeHeaders.byte, 0, 255, binfile.writeByte},
    {typeHeaders.signedShort, -32768, 32767, binfile.writeSignedShort},
    {typeHeaders.signedLong, -2147483648, 2147483647, binfile.writeSignedLong},
}

function mapcoder.encodeNumber(fh, n, lookup)
    local float = n ~= math.floor(n)

    if float then
        binfile.writeByte(fh, typeHeaders.float32)
        binfile.writeFloat(fh, n)

    else
        for i, d in ipairs(integerBits) do
            local header, min, max, func = d[1], d[2], d[3], d[4]

            if n >= min and n <= max then
                binfile.writeByte(fh, header)
                func(fh, n)

                return
            end
        end
    end
end

function mapcoder.encodeBoolean(fh, b, lookup)
    binfile.writeByte(fh, typeHeaders.bool)
    binfile.writeBool(fh, b)
end

local function findInLookup(lookup, s)
    return lookup:index(look -> look == s)
end

function mapcoder.encodeString(fh, s, lookup)
    local index = findInLookup(lookup, s)

    if index then
        binfile.writeByte(fh, 5)
        binfile.writeSignedShort(fh, index - 1)

    else
        local encodedString = binfile.encodeRunLength(s)
        local encodedLength = #encodedString

        if encodedLength < #s and encodedLength < 2^15 then
            binfile.writeByte(fh, 7)
            binfile.writeSignedShort(fh, encodedLength)
            binfile.writeByteArray(fh, encodedString)

        else
            binfile.writeByte(fh, 6)
            binfile.writeString(fh, s)
        end
    end
end

function mapcoder.encodeTable(fh, data, lookup)
    coroutine.yield()

    local index = findInLookup(lookup, data.__name)

    local attributes = {}
    local attributeCount = 0

    local children = data.__children or {}

    for attr, value in pairs(data) do
        if attr ~= "__children" and attr ~= "__name" then
            attributes[attr] = value
            attributeCount += 1
        end
    end

    binfile.writeShort(fh, index - 1)
    binfile.writeByte(fh, attributeCount)

    for attr, value in pairs(attributes) do
        local attrIndex = findInLookup(lookup, attr)

        binfile.writeShort(fh, attrIndex - 1)
        mapcoder.encodeValue(fh, value, lookup)
    end

    binfile.writeShort(fh, #children)

    for i, child in ipairs(children) do
        mapcoder.encodeTable(fh, child, lookup)
    end
end

local encodingFunctions = {
    number = mapcoder.encodeNumber,
    boolean = mapcoder.encodeBoolean,
    string = mapcoder.encodeString,
    table = mapcoder.encodeTable
}

function mapcoder.encodeValue(fh, value, lookup)
    encodingFunctions[type(value)](fh, value, lookup)
end

-- TODO - Use buffer so we don't corrupt the bin midway if we fail
function mapcoder.encodeFile(path, data, header)
    header = header or "CELESTE MAP"

    local fh = utils.getFileHandle(path, "wb")

    local stringsSeen = countStrings(data)
    local lookupStrings = {}

    for s, c in pairs(stringsSeen) do
        table.insert(lookupStrings, {s, c})
    end

    lookupStrings = $(lookupStrings):sortby(v -> v[2]):reverse():map(v -> v[1])

    binfile.writeString(fh, header)
    binfile.writeString(fh, data._package or "")
    binfile.writeShort(fh, lookupStrings:len)

    for i, lookup <- lookupStrings do
        binfile.writeString(fh, lookup)
    end

    mapcoder.encodeTable(fh, data, lookupStrings)

    fh:close()

    coroutine.yield()
end

return mapcoder