-- Linking an officer's real SnailyCAD account: they paste their personal "User API Token" (CAD > Account
-- Settings > API Tokens) once; it's checked against the CAD itself before being saved, then every MDT action
-- for that character uses it (server/cad.lua, server/actions.lua).

Officer = {}
local officers = {}   -- [identifier] = { token, username }

local function load(identifier)
    if officers[identifier] ~= nil then return officers[identifier] or false end
    local row = MySQL.single.await('SELECT cad_token, cad_username FROM opslabs_mdt_officers WHERE identifier = ?', { identifier })
    officers[identifier] = row and { token = row.cad_token, username = row.cad_username } or false
    return officers[identifier]
end

--- the officer's saved CAD link, or nil
function Officer.Get(src)
    local id = FW.Identifier(src)
    if not id then return nil end
    return load(id) or nil
end

--- checks the token against the CAD, saves it if good. Returns (ok, usernameOrReason)
function Officer.Link(src, token)
    token = tostring(token or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if token == '' then return false, 'Paste your CAD User API Token first.' end
    if not Cad.Configured() then return false, 'SnailyCAD is not set up on this server yet.' end

    local data, status = Cad.AsOfficer(token, 'GET', '/leo/active-officer')
    if status ~= 200 and status ~= 404 then
        return false, Cad.DescribeError(status, data)
    end

    local id = FW.Identifier(src)
    if not id then return false, 'Could not identify you.' end
    local username = (status == 200 and data and data.officer and data.officer.user and data.officer.user.username) or nil

    MySQL.insert.await(
        'INSERT INTO opslabs_mdt_officers (identifier, cad_token, cad_username, linked_at) VALUES (?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE cad_token = VALUES(cad_token), cad_username = VALUES(cad_username), linked_at = VALUES(linked_at)',
        { id, token, username, os.time() }
    )
    officers[id] = { token = token, username = username }
    return true, username
end

function Officer.Unlink(src)
    local id = FW.Identifier(src)
    if not id then return end
    officers[id] = false
    MySQL.update.await('DELETE FROM opslabs_mdt_officers WHERE identifier = ?', { id })
end
