local rdebug = require 'remotedebug.visitor'
local source = require 'backend.worker.source'
local luaver = require 'backend.worker.luaver'
local ev = require 'common.event'

local MAX_TABLE_FIELD = 300
local TEMPORARY = "(temporary)"
local LUAVERSION = 54

local info = {}
local varPool = {}
local standard = {}

local function init_standard()
    local lstandard = {
        "_G",
        "_VERSION",
        "assert",
        "collectgarbage",
        "coroutine",
        "debug",
        "dofile",
        "error",
        "getmetatable",
        "io",
        "ipairs",
        "load",
        "loadfile",
        "math",
        "next",
        "os",
        "package",
        "pairs",
        "pcall",
        "print",
        "rawequal",
        "rawget",
        "rawset",
        "require",
        "select",
        "setmetatable",
        "string",
        "table",
        "tonumber",
        "tostring",
        "type",
        "xpcall",
    }

    if LUAVERSION == 51 then
        table.insert(lstandard, "gcinfo")
        table.insert(lstandard, "getfenv")
        table.insert(lstandard, "loadstring")
        table.insert(lstandard, "module")
        table.insert(lstandard, "newproxy")
        table.insert(lstandard, "setfenv")
        table.insert(lstandard, "unpack")
    end
    if LUAVERSION >= 52 then
        table.insert(lstandard, "rawlen")
    end
    if LUAVERSION == 52 or LUAVERSION == 53 then
        table.insert(lstandard, "bit32")
    end
    if LUAVERSION >= 53 then
        table.insert(lstandard, "utf8")
    end
    if LUAVERSION >= 54 then
        table.insert(lstandard, "warn")
    end
    standard = {}
    for _, v in ipairs(lstandard) do
        standard[v] = true
    end
end

ev.on('initializing', function()
    LUAVERSION = luaver.LUAVERSION
    init_standard()
    TEMPORARY = LUAVERSION >= 54 and "(temporary)" or "(*temporary)"
end)


local special_has = {}

function special_has.Parameter(frameId)
    if LUAVERSION >= 52 then
        rdebug.getinfo(frameId, "u", info)
        if info.nparams > 0 then
            return true
        end
    end
    return rdebug.getlocalv(frameId, -1) ~= nil
end

function special_has.Local(frameId)
    local i = 1
    --已经在Parameter里调用过getinfo 'u'
    if LUAVERSION >= 52 and info.nparams > 0 then
        i = i + info.nparams
    end
    while true do
        local name = rdebug.getlocalv(frameId, i)
        if name == nil then
            return false
        end
        if name ~= TEMPORARY then
            return true
        end
        i = i + 1
    end
end

function special_has.Upvalue(frameId)
    local f = rdebug.getfunc(frameId)
    return rdebug.getupvaluev(f, 1) ~= nil
end

function special_has.Return(frameId)
    rdebug.getinfo(frameId, "r", info)
    return info.ftransfer > 0 and info.ntransfer > 0
end

function special_has.Global()
    local gt = rdebug._G
    local key
    while true do
        key = rdebug.nextv(gt, key)
        if not key then
            return false
        end
        if not standard[key] then
            return true
        end
    end
end

function special_has.Standard()
    return true
end


local function normalizeNumber(str)
    if str:find('.', 1, true) then
        str = str:gsub('0+$', '')
        if str:sub(-1) == '.' then
            return str .. '0'
        end
    end
    return str
end


local function varCanExtand(type, subtype, value)
    if type == 'function' then
        return rdebug.getupvaluev(value, 1) ~= nil
    elseif type == 'table' then
        if rdebug.nextv(value, nil) ~= nil then
            return true
        end
        if rdebug.getmetatablev(value) ~= nil then
            return true
        end
        return false
    elseif type == 'userdata' then
        if rdebug.getmetatablev(value) ~= nil then
            return true
        end
        if subtype == 'full' and rdebug.getuservaluev(value) ~= nil then
            return true
        end
        return false
    end
    return false
end

local function varGetName(value)
    local type, subtype = rdebug.type(value)
    if type == 'string' then
        local str = rdebug.value(value)
        if #str < 32 then
            return str
        end
        return str:sub(1, 32) .. '...'
    elseif type == 'boolean' then
        if rdebug.value(value) then
            return 'true'
        else
            return 'false'
        end
    elseif type == 'nil' then
        return 'nil'
    elseif type == 'number' then
        if LUAVERSION <= 52 then
            local rvalue = rdebug.value(value)
            if rvalue == math.floor(rvalue) then
                subtype = 'integer'
            end
        end
        if subtype == 'integer' then
            local rvalue = rdebug.value(value)
            if rvalue > 0 and rvalue < 1000 then
                return ('[%03d]'):format(rvalue)
            end
            return ('%d'):format(rvalue)
        else
            return normalizeNumber(('%.4f'):format(rdebug.value(value)))
        end
    end
    return tostring(rdebug.value(value))
end

local function varGetShortValue(value)
    local type, subtype = rdebug.type(value)
    if type == 'string' then
        local str = rdebug.value(value)
        if #str < 16 then
            return ("'%s'"):format(str)
        end
        return ("'%s...'"):format(str:sub(1, 16))
    elseif type == 'boolean' then
        if rdebug.value(value) then
            return 'true'
        else
            return 'false'
        end
    elseif type == 'nil' then
        return 'nil'
    elseif type == 'number' then
        if subtype == 'integer' then
            return ('%d'):format(rdebug.value(value))
        else
            return normalizeNumber(('%f'):format(rdebug.value(value)))
        end
    elseif type == 'function' then
        return 'func'
    elseif type == 'table' then
        if varCanExtand(type, subtype, value) then
            return "..."
        end
        return '{}'
    elseif type == 'userdata' then
        return 'userdata'
    elseif type == 'thread' then
        return 'thread'
    end
    return type
end

local TABLE_VALUE_MAXLEN = 32
local function varGetTableValue(t)
    local loct = rdebug.copytable(t,MAX_TABLE_FIELD)
    local str = ''
    local mark = {}
    for i, v in ipairs(loct) do
        if str == '' then
            str = varGetShortValue(v)
        else
            str = str .. "," .. varGetShortValue(v)
        end
        mark[i] = true
        if #str >= TABLE_VALUE_MAXLEN then
            return ("{%s...}"):format(str)
        end
    end

    local kvs = {}
    for key, value in pairs(loct) do
        if mark[key] then
            goto continue
        end
        local kn = varGetName(key)
        kvs[#kvs + 1] = { kn, value }
        if #kvs >= 300 then
            break
        end
        ::continue::
    end
    table.sort(kvs, function(a, b) return a[1] < b[1] end)

    for _, kv in ipairs(kvs) do
        if str == '' then
            str = kv[1] .. '=' .. varGetShortValue(kv[2])
        else
            str = str .. ',' .. kv[1] .. '=' .. varGetShortValue(kv[2])
        end
        if #str >= TABLE_VALUE_MAXLEN then
            return ("{%s...}"):format(str)
        end
    end
    return ("{%s}"):format(str)
end

local function getLineStart(str, pos, n)
    for _ = 1, n - 1 do
        local f, _, nl1, nl2 = str:find('([\n\r])([\n\r]?)', pos)
        if not f then
            return
        end
        if nl1 == nl2 then
            pos = f + 1
        elseif nl2 == '' then
            pos = f + 1
        else
            pos = f + 2
        end
    end
    return pos
end

local function getLineEnd(str, pos, n)
    local pos = getLineStart(str, pos, n)
    if not pos then
        return
    end
    local pos = str:find('[\n\r]', pos)
    if not pos then
        return
    end
    return pos - 1
end

local function getFunctionCode(str, startLn, endLn)
    local startPos = getLineStart(str, 1, startLn)
    if not startPos then
        return str
    end
    local endPos = getLineEnd(str, startPos, endLn - startLn + 1)
    if not endPos then
        return str:sub(startPos)
    end
    return str:sub(startPos, endPos)
end

-- context: getvalue,setvalue,scopes,hover,watch,repl,copyvalue
local function varGetValue(context, type, subtype, value)
    if type == 'string' then
        local str = rdebug.value(value)
        if context == "repl" or context == "copyvalue" then
            return ("'%s'"):format(str)
        end
        if context == "hover" then
            if #str < 2048 then
                return ("'%s'"):format(str)
            end
            return ("'%s...'"):format(str:sub(1, 2048))
        end
        if #str < 1024 then
            return ("'%s'"):format(str)
        end
        return ("'%s...'"):format(str:sub(1, 1024))
    elseif type == 'boolean' then
        if rdebug.value(value) then
            return 'true'
        else
            return 'false'
        end
    elseif type == 'nil' then
        return 'nil'
    elseif type == 'number' then
        if subtype == 'integer' then
            return ('%d'):format(rdebug.value(value))
        else
            return normalizeNumber(('%f'):format(rdebug.value(value)))
        end
    elseif type == 'function' then
        if subtype == 'c' then
            return 'C function'
        end
        rdebug.getinfo(value, "S", info)
        local src = source.create(info.source)
        if not source.valid(src) then
            return tostring(rdebug.value(value))
        end
        if not src.sourceReference then
            return ("%s:%d"):format(source.clientPath(src.path), info.linedefined)
        end
        local code = source.getCode(src.sourceReference)
        return getFunctionCode(code, info.linedefined, info.lastlinedefined)
    elseif type == 'table' then
        return varGetTableValue(value)
    elseif type == 'userdata' then
        local meta = rdebug.getmetatablev(value)
        if meta ~= nil then
            local fn = rdebug.indexv(meta, '__debugger_tostring')
            if fn ~= nil and rdebug.type(fn) == 'function' then
                local ok, res = rdebug.evalref(fn, value)
                if ok then
                    return res
                end
            end
            local name = rdebug.indexv(meta, '__name')
            if name ~= nil then
                return 'userdata: ' .. tostring(rdebug.value(name))
            end
        end
        if subtype == 'light' then
            return 'light' .. tostring(rdebug.value(value))
        end
        return 'userdata'
    elseif type == 'thread' then
        return 'thread'
    end
    return tostring(rdebug.value(value))
end

local function varGetType(type, subtype)
    if type == 'string'
        or type == 'boolean'
        or type == 'nil'
        or type == 'table'
        or type == 'table'
        or type == 'thread'
    then
        return type
    elseif type == 'number' then
        return subtype
    elseif type == 'function' then
        if subtype == 'c' then
            return 'C function'
        end
        return 'function'
    elseif type == 'userdata' then
        if subtype == 'light' then
            return 'lightuserdata'
        end
        return 'userdata'
    end
    return type
end

local function varCreateReference(frameId, value, evaluateName, context)
    local type, subtype = rdebug.type(value)
    local textType = varGetType(type, subtype)
    local textValue = varGetValue(context, type, subtype, value)
    if varCanExtand(type, subtype, value) then
        varPool[#varPool + 1] = {
            v = value,
            eval  = evaluateName,
            frameId = frameId,
        }
        return textValue, textType, #varPool
    end
    return textValue, textType
end

local function varCreateScopes(frameId, scopes, name, expensive)
    if not special_has[name](frameId) then
        return
    end
    varPool[#varPool + 1] = {
        v = {},
        special = name,
        frameId = frameId,
    }
    scopes[#scopes + 1] = {
        name = name,
        variablesReference = #varPool,
        expensive = expensive,
    }
end

local function varCreate(vars, frameId, varRef, name, nameidx, value, evaluateName, calcValue)
    local extand = varRef.extand
    if extand[name] then
        local index = extand[name][3]
        local nameidx = extand[name][4]
        local var = vars[index]
        if not nameidx or var.presentationHint then
            local log = require 'common.log'
            log.error("same name variables: "..name)
            return {}
        end
        local newname = ("%s #%d"):format(name, nameidx)
        if extand[newname] then
            local log = require 'common.log'
            log.error("same name variables: "..name)
            return {}
        end
        var.name = newname
        var.presentationHint = {
            kind = "virtual"
        }
        var.evaluateName = nil
        extand[newname] = extand[name]
        extand[newname][2] = nil
        extand[name] = nil
    end
    local text, type, ref = varCreateReference(frameId, value, evaluateName, "getvalue")
    local var =  {
        name = name,
        type = type,
        value = text,
        variablesReference = ref,
        evaluateName = evaluateName and evaluateName or nil,
    }
    vars[#vars + 1] = var
    extand[name] = { calcValue, evaluateName, #vars, nameidx }
    return var
end

local function getTabelKey(key)
    local type = rdebug.type(key)
    if type == 'string' then
        local str = rdebug.value(key)
        if str:match '^[_%a][_%w]*$' then
            return ('.%s'):format(str)
        end
        return ('[%q]'):format(str)
    elseif type == 'boolean' then
        return ('[%s]'):format(tostring(rdebug.value(key)))
    elseif type == 'number' then
        return ('[%s]'):format(tostring(rdebug.value(key)))
    end
end

local function extandTable(varRef)
    varRef.extand = {}
    local frameId = varRef.frameId
    local t = varRef.v
    local evaluateName = varRef.eval
    local vars = {}
    local loct = rdebug.copytable(t,MAX_TABLE_FIELD)
    for key, value in pairs(loct) do
        local evalKey = getTabelKey(key)
        varCreate(vars, frameId, varRef
            , varGetName(key), nil
            , value, evaluateName and evalKey and ('%s%s'):format(evaluateName, evalKey)
            , function() return rdebug.index(t, key) end
        )
    end
    table.sort(vars, function(a, b) return a.name < b.name end)

    local meta = rdebug.getmetatablev(t)
    if meta ~= nil then
        local var = varCreate(vars, frameId, varRef
            , '[metatable]', nil
            , meta, evaluateName and ('debug.getmetatable(%s)'):format(evaluateName)
            , function() return rdebug.getmetatable(t) end
        )
        var.presentationHint = {
            kind = "virtual"
        }
        table.insert(vars, 1, vars[#vars])
        vars[#vars] = nil
    end
    return vars
end

local function extandFunction(varRef)
    varRef.extand = {}
    local frameId = varRef.frameId
    local f = varRef.v
    local evaluateName = varRef.eval
    local vars = {}
    local i = 1
    local _, subtype = rdebug.type(f)
    local isCFunction = subtype == "c"
    while true do
        local name, value = rdebug.getupvaluev(f, i)
        if name == nil then
            break
        end
        local displayName = isCFunction and ("[%d]"):format(i) or name
        local fi = i
        local var = varCreate(vars, frameId, varRef
            , displayName, nil
            , value, evaluateName and ('select(2, debug.getupvalue(%s,%d))'):format(evaluateName, i)
            , function() local _, r = rdebug.getupvalue(f, fi) return r end
        )
        var.presentationHint = {
            kind = "virtual"
        }
        i = i + 1
    end
    return vars
end

local function extandUserdata(varRef)
    varRef.extand = {}
    local frameId = varRef.frameId
    local u = varRef.v
    local evaluateName = varRef.eval
    local vars = {}

    local meta = rdebug.getmetatablev(u)
    if meta ~= nil then
        local var = varCreate(vars, frameId, varRef
            , '[metatable]', nil
            , meta, evaluateName and ('debug.getmetatable(%s)'):format(evaluateName)
            , function() return rdebug.getmetatable(u) end
        )
        var.presentationHint = {
            kind = "virtual"
        }
    end

    if LUAVERSION >= 54 then
        local i = 1
        while true do
            local uv, ok = rdebug.getuservaluev(u, i)
            if not ok then
                break
            end
            if uv ~= nil then
                local fi = i
                local var = varCreate(vars, frameId, varRef
                    , ('[uservalue %d]'):format(i), nil
                    , uv, evaluateName and ('debug.getuservalue(%s,%d)'):format(evaluateName,i)
                    , function() return rdebug.getuservalue(u, fi) end
                )
                var.presentationHint = {
                    kind = "virtual"
                }
            end
            i = i + 1
        end
    else
        local uv = rdebug.getuservaluev(u)
        if uv ~= nil then
            local var = varCreate(vars, frameId, varRef
                , '[uservalue]', nil
                , uv, evaluateName and ('debug.getuservalue(%s)'):format(evaluateName)
                , function() return rdebug.getuservalue(u) end
            )
            var.presentationHint = {
                kind = "virtual"
            }
    end
    end
    return vars
end

local function extandValue(varRef)
    local type = rdebug.type(varRef.v)
    if type == 'table' then
        return extandTable(varRef)
    elseif type == 'function' then
        return extandFunction(varRef)
    elseif type == 'userdata' then
        return extandUserdata(varRef)
    end
    return {}
end

local function setValue(varRef, name, value)
    if not varRef.extand or not varRef.extand[name] then
        return nil, 'Failed set variable'
    end
    local frameId = varRef.frameId
    local newvalue
    if value == 'nil' then
        newvalue = nil
    elseif value == 'false' then
        newvalue = false
    elseif value == 'true' then
        newvalue = true
    elseif value:sub(1,1) == "'" and value:sub(-1,-1) == "'" then
        newvalue = value:sub(2,-2)
    elseif value:sub(1,1) == '"' and value:sub(-1,-1) == '"' then
        newvalue = value:sub(2,-2)
    elseif tonumber(value) then
        newvalue = tonumber(value)
    else
        newvalue = value
    end
    local calcValue, evaluateName = varRef.extand[name][1], varRef.extand[name][2]
    local rvalue = calcValue()
    if not rdebug.assign(rvalue, newvalue) then
        return nil, 'Failed set variable'
    end
    local text, type = varCreateReference(frameId, rvalue, evaluateName, "setvalue")
    return {
        value = text,
        type = type,
    }
end

local special_extand = {}

function special_extand.Local(varRef)
    varRef.extand = {}
    local frameId = varRef.frameId
    local tempVar = {}
    local vars = {}
    local i = 1
    if LUAVERSION >= 52 then
        rdebug.getinfo(frameId, "u", info)
        if info.nparams > 0 then
            i = i + info.nparams
        end
    end
    while true do
        local name, value = rdebug.getlocalv(frameId, i)
        if name == nil then
            break
        end
        if name ~= TEMPORARY then
            if name:sub(1,1) == "(" then
                tempVar[name] = tempVar[name] and (tempVar[name] + 1) or 1
                name = ("(%s #%d)"):format(name:sub(2,-2), tempVar[name])
            end
            local fi = i
            varCreate(vars, frameId, varRef
                , name, i
                , value, name
                , function() local _, r = rdebug.getlocal(frameId, fi) return r end
            )
        end
        i = i + 1
    end
    return vars
end

function special_extand.Upvalue(varRef)
    varRef.extand = {}
    local frameId = varRef.frameId
    local vars = {}
    local i = 1
    local f = rdebug.getfunc(frameId)
    while true do
        local name, value = rdebug.getupvaluev(f, i)
        if name == nil then
            break
        end
        local fi = i
        varCreate(vars, frameId, varRef
            , name, nil
            , value, name
            , function() local _, r = rdebug.getupvalue(f, fi) return r end
        )
        i = i + 1
    end
    return vars
end

function special_extand.Parameter(varRef)
    varRef.extand = {}
    local frameId = varRef.frameId
    local vars = {}

    if LUAVERSION >= 52 then
        rdebug.getinfo(frameId, "u", info)
        if info.nparams > 0 then
            for i = 1, info.nparams do
                local name, value = rdebug.getlocalv(frameId, i)
                if name ~= nil then
                    local fi = i
                    varCreate(vars, frameId, varRef
                        , name, i
                        , value, name
                        , function() local _, r = rdebug.getlocal(frameId, fi) return r end
                    )
                end
            end
        end
    end

    local i = -1
    while true do
        local name, value = rdebug.getlocalv(frameId, i)
        if name == nil then
            break
        end
        local fi = i
        varCreate(vars, frameId, varRef
            , ('[vararg %d]'):format(-i), nil
            , value, ('select(%d,...)'):format(-i)
            , function() local _, r = rdebug.getlocal(frameId, fi) return r end
        )
        i = i - 1
    end

    return vars
end

function special_extand.Return(varRef)
    varRef.extand = {}
    local frameId = varRef.frameId
    local vars = {}
    rdebug.getinfo(frameId, "r", info)
    if info.ftransfer > 0 and info.ntransfer > 0 then
        for i = info.ftransfer, info.ftransfer + info.ntransfer - 1 do
            local name, value = rdebug.getlocalv(frameId, i)
            if name ~= nil then
                local fi = i
                varCreate(vars, frameId, varRef
                    , ('[%d]'):format(i - info.ftransfer + 1), nil
                    , value, nil
                    , function() local _, r = rdebug.getlocal(frameId, fi) return r end
                )
            end
        end
    end
    return vars
end

function special_extand.Global(varRef)
    varRef.extand = {}
    local frameId = varRef.frameId
    local vars = {}
    local loct = rdebug.copytable(rdebug._G,MAX_TABLE_FIELD)
    for key, value in pairs(loct) do
        local name = varGetName(key)
        if not standard[name] then
            varCreate(vars, frameId, varRef
                , name, nil
                , value, ('_G%s'):format(getTabelKey(key))
                , function() return rdebug.index(rdebug._G, key) end
            )
        end
    end
    table.sort(vars, function(a, b) return a.name < b.name end)
    return vars
end

function special_extand.Standard(varRef)
    varRef.extand = {}
    local frameId = varRef.frameId
    local vars = {}
    local loct = rdebug.copytable(rdebug._G,MAX_TABLE_FIELD)
    for key, value in pairs(loct) do
        local name = varGetName(key)
        if standard[name] then
            varCreate(vars, frameId, varRef
                , name, nil
                , value , ('_G%s'):format(getTabelKey(key))
                , function() return rdebug.index(rdebug._G, key) end
            )
        end
    end
    table.sort(vars, function(a, b) return a.name < b.name end)
    return vars
end

local m = {}

function m.scopes(frameId)
    local scopes = {}
    varCreateScopes(frameId, scopes, "Parameter", false)
    varCreateScopes(frameId, scopes, "Local", false)
    varCreateScopes(frameId, scopes, "Upvalue", false)
    if LUAVERSION >= 54 then
        varCreateScopes(frameId, scopes, "Return", false)
    end
    varCreateScopes(frameId, scopes, "Global", true)
    varCreateScopes(frameId, scopes, "Standard", true)
    return scopes
end

function m.extand(valueId)
    local varRef = varPool[valueId]
    if not varRef then
        return nil, 'Error variablesReference'
    end
    if varRef.special then
        return special_extand[varRef.special](varRef)
    end
    return extandValue(varRef)
end

function m.set(valueId, name, value)
    local varRef = varPool[valueId]
    if not varRef then
        return nil, 'Error variablesReference'
    end
    return setValue(varRef, name, value)
end

function m.clean()
    varPool = {}
end

function m.createText(value, context)
    local type, subtype = rdebug.type(value)
    return varGetValue(context, type, subtype, value)
end

function m.createRef(frameId, value, evaluateName, context)
    local text, _, ref = varCreateReference(frameId, value, evaluateName, context)
    return text, ref
end

ev.on('terminated', function()
    m.clean()
end)

return m
