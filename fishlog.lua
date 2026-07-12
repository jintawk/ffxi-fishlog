--[[
FishLog - a fishing session logger and live catch identifier for Windower 4.

Copyright 2026 Jintawk

The hooked-catch identification logic and the fishing parameter tables in
data.lua are ported from "fisher" by Seth VanHeulen
(https://gitlab.com/svanheulen/fisher), licensed GPL-3.0.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
]]

_addon.name = 'FishLog'
_addon.author = 'Jintawk'
_addon.version = '1.3.1'
_addon.commands = {'fishlog', 'fl'}

local bit = require('bit')
local config = require('config')
local slate = require('slate')
local res = require('resources')
require('pack')

local data = require('data')

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

local defaults = {
    display = {
        pos = {x = 260, y = 260},
        bg = {alpha = 225, red = 14, green = 18, blue = 26, visible = true},
        flags = {draggable = true, bold = false},
        padding = 8,
        text = {
            font = 'Segoe UI',
            fonts = {'Arial'},
            size = 12,
            alpha = 255, red = 228, green = 233, blue = 240,
            stroke = {width = 1, alpha = 170, red = 0, green = 0, blue = 0},
        },
    },
    visible = true,
    compact = false,
    lines = 10,
    ui = {scale = 1, minimized = false},
    tracked = '',
    sound_enabled = true,
    sound_monster_enabled = true,
    sound_tracked = 'tracked',
    sound_monster = 'monster',
    debug = false,
    research = true,
    monster_command = '',
    today = {date = '', count = 0},
    lifetime = {casts = 0, fish = 0, skill = 0},
    -- exact fishing skill with decimal, pinned when a +0.1 skill-up crosses a
    -- level boundary ("skill reaches level N" right after a +0.1 rise means
    -- exactly N.0). 0 means the decimal is currently unknown; see the
    -- exact-skill tracking section. Stored per-character.
    known_skill = 0,
    -- highest integer fishing level confirmed from a "reaches level N" chat line
    -- or the game's own skills packet. The game's in-memory integer is stale (it
    -- only refreshes on menu/zone/login), so this is a fresher floor for the
    -- integer shown on the HUD. Stored per-character.
    known_int = 0,
    colors = {
        title   = {r = 96,  g = 218, b = 208},
        zone    = {r = 206, g = 216, b = 230},
        meta    = {r = 140, g = 152, b = 168},
        rule    = {r = 46,  g = 54,  b = 68},
        stamp   = {r = 100, g = 112, b = 130},
        catch   = {r = 120, g = 214, b = 150},
        track   = {r = 245, g = 205, b = 120},
        miss    = {r = 118, g = 128, b = 146},
        lost    = {r = 238, g = 168, b = 110},
        brk     = {r = 240, g = 100, b = 104},
        skill   = {r = 104, g = 200, b = 236},
        monster = {r = 240, g = 120, b = 176},
        info    = {r = 150, g = 186, b = 220},
        label   = {r = 140, g = 152, b = 168},
        value   = {r = 224, g = 230, b = 238},
        online  = {r = 118, g = 222, b = 208},
    },
}

local settings = config.load(defaults)

local render    -- forward declaration; assigned in the rendering section

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local session
local cast
local history = {}
local HISTORY_MAX = 300
local view_offset = 0
local player_status
local last_fishing_ts = 0
local last_hook_ts
local char_name
local log_file_ok = true
local skill_int       -- last integer fishing skill observed from the game
local last_skillup    -- {v, ts} of the most recent "skill rises" message
local last_boundary   -- {n, ts} of the most recent "skill reaches level N" line

local function new_cast()
    cast = {hooked = false, names = nil, kind = nil, senses = nil,
            monster = false, outcome = false}
end

local function new_session()
    session = {
        start = nil, casts = 0, bites = 0, catch_events = 0, fish = 0,
        nobite = 0, lost = 0, line_breaks = 0, rod_breaks = 0,
        released = 0, monsters = 0, skill = 0, tally = {},
    }
    new_cast()
end

new_session()

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

-- FFXI chat is Shift-JIS; anything multi-byte garbles. HUD text is fine.
local function msg(text)
    windower.add_to_chat(207, '[FishLog] ' .. (text:gsub('[\128-\255]', '')))
end

local function cs(c)
    return string.format('\\cs(%d,%d,%d)', c.r, c.g, c.b)
end
local CR = '\\cr'

local function format_dur(s)
    local h = math.floor(s / 3600)
    local m = math.floor(s % 3600 / 60)
    if h > 0 then
        return string.format('%d:%02d:%02d', h, m, s % 60)
    end
    return string.format('%d:%02d', m, s % 60)
end

local function strip_codes(str)
    return (str:gsub(string.char(0x1E) .. '.', '')
               :gsub(string.char(0x1F) .. '.', '')
               :gsub('%c', ''))
end

local function fishing_status(s)
    return s ~= nil and s >= 56 and s <= 63
end

-- Fishing fatigue resets at Japanese midnight (00:00 JST = UTC+9). Returns
-- true if the day just rolled over, so callers can persist/redraw.
local function check_today()
    local today = os.date('!%Y-%m-%d', os.time() + 9 * 3600)
    if settings.today.date ~= today then
        settings.today.date = today
        settings.today.count = 0
        return true
    end
    return false
end

local function play(name)
    if not settings.sound_enabled or not name or name == '' then return end
    windower.play_sound(windower.addon_path .. 'sounds/' .. name .. '.wav')
end

-------------------------------------------------------------------------------
-- Tracked catches
-------------------------------------------------------------------------------

local function tracked_list()
    local list = {}
    for word in settings.tracked:gmatch('[^,]+') do
        word = word:match('^%s*(.-)%s*$'):lower()
        if #word > 0 then
            list[#list + 1] = word
        end
    end
    return list
end

local function is_tracked(name)
    name = name:lower()
    for _, t in ipairs(tracked_list()) do
        if name:find(t, 1, true) then
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- File logging (data/logs/YYYY-MM-DD_Char.log)
-------------------------------------------------------------------------------

local function flog(line)
    if not log_file_ok then return end
    local path = windower.addon_path .. 'data/logs/'
        .. os.date('%Y-%m-%d') .. '_' .. (char_name or 'unknown') .. '.log'
    local f = io.open(path, 'a')
    if not f then
        log_file_ok = false
        msg('Warning: unable to write to data/logs - file logging disabled.')
        return
    end
    f:write(string.format('[%s] %s\n', os.date('%H:%M:%S'), line))
    f:close()
end

-------------------------------------------------------------------------------
-- Research logging: one CSV row per cast, for community catch-rate analysis
-------------------------------------------------------------------------------

local pending_row     -- the cast currently in progress (open, no outcome yet)
local finalized_row   -- a cast whose outcome is known but whose write is held
                      -- briefly: the "fishing skill rises" message arrives a
                      -- few seconds AFTER the catch line, so we keep the row
                      -- buffered long enough to record the skill-up on it

local CSV_HEADER = 'v,contributor,utc,zone_id,zone,skill,rod_id,rod,bait_id,bait,'
    .. 'moon,moon_phase,vana_min,vana_day,weather_id,outcome,bite_id,'
    .. 'p1,p2,p3,p4,p5,p6,p7,p8,p9,identified,caught,count,fight_s,x,y,z,facing,'
    .. 'skillup'

-- stable anonymous contributor id (djb2 hash of character name)
local function anon_id(name)
    local h = 5381
    for i = 1, #name do
        h = (h * 33 + name:byte(i)) % 4294967296
    end
    return string.format('%08x', h)
end

local function csv_field(v)
    if v == nil then return '' end
    return (tostring(v):gsub('[,\r\n"]', ' '))
end

local function write_cast_row(row)
    local path = windower.addon_path .. 'data/casts/casts_' .. os.date('!%Y-%m') .. '.csv'
    local new_file = not windower.file_exists(path)
    local f = io.open(path, 'a')
    if not f then return end
    if new_file then
        f:write(CSV_HEADER .. '\n')
    end
    local fields = {}
    for i, key in ipairs({'v', 'contributor', 'utc', 'zone_id', 'zone', 'skill',
                          'rod_id', 'rod', 'bait_id', 'bait', 'moon', 'moon_phase',
                          'vana_min', 'vana_day', 'weather_id', 'outcome', 'bite_id',
                          'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8', 'p9',
                          'identified', 'caught', 'count', 'fight_s',
                          'x', 'y', 'z', 'facing', 'skillup'}) do
        fields[i] = csv_field(row[key])
    end
    f:write(table.concat(fields, ',') .. '\n')
    f:close()
end

-- called at cast start: snapshot everything that could influence the bite
local function open_cast_row(rod_id, bait_id)
    if not settings.research then return end
    local info = windower.ffxi.get_info()
    local player = windower.ffxi.get_player()
    if not player then return end
    local me = windower.ffxi.get_mob_by_target('me')
    -- prefer the exact known skill (with decimal) over the game's integer when
    -- we've pinned it; still just a number, so parsers read either fine
    local skill_val = (settings.known_skill and settings.known_skill > 0)
        and settings.known_skill
        or (player.skills and player.skills.fishing) or ''
    pending_row = {
        v = 3,
        contributor = anon_id(char_name or 'unknown'),
        utc = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        zone_id = info.zone,
        zone = res.zones[info.zone] and res.zones[info.zone].en or '',
        skill = skill_val,
        rod_id = rod_id or '',
        rod = rod_id and res.items[rod_id] and res.items[rod_id].en or '',
        bait_id = bait_id or '',
        bait = bait_id and res.items[bait_id] and res.items[bait_id].en or '',
        moon = info.moon or '',
        moon_phase = info.moon_phase or '',
        vana_min = info.time or '',
        vana_day = info.day or '',
        weather_id = info.weather or '',
        x = me and me.x or '',
        y = me and me.y or '',
        z = me and me.z or '',
        facing = me and me.facing or '',
    }
end

-- write the buffered (finalized) row to disk, if any
local function flush_row()
    if finalized_row then
        write_cast_row(finalized_row)
        finalized_row = nil
    end
end

local function finish_cast_row(outcome, caught, count, fight_s)
    if not pending_row then return end
    -- a previous cast may still be buffered awaiting its skill-up window; flush
    -- it before we start holding a new one so rows never overlap
    flush_row()
    pending_row.outcome = outcome
    pending_row.caught = caught
    pending_row.count = count
    pending_row.fight_s = fight_s
    pending_row._t = os.time()   -- for the grace-flush timer (not a CSV column)
    finalized_row = pending_row
    pending_row = nil
end

-------------------------------------------------------------------------------
-- History
-------------------------------------------------------------------------------

local function add_entry(icon, color_key, text, opts)
    history[#history + 1] = {
        ts = os.date('%H:%M:%S'),
        icon = icon,
        color = color_key,
        text = text,
    }
    if #history > HISTORY_MAX then
        table.remove(history, 1)
    end
    -- keep the same lines in view if the user has scrolled back
    if view_offset > 0 then
        view_offset = math.min(view_offset + 1, math.max(#history - settings.lines, 0))
    end
    if not (opts and opts.nofile) then
        flog(icon .. ' ' .. text)
    end
    render()
end

-------------------------------------------------------------------------------
-- Hooked-item identification (ported from fisher by Seth VanHeulen)
-------------------------------------------------------------------------------

local get_equipped_item_id
do
    local bag_by_id = {
        [0] = 'inventory',
        [8] = 'wardrobe',
        [10] = 'wardrobe2',
        [11] = 'wardrobe3',
        [12] = 'wardrobe4',
        [13] = 'wardrobe5',
        [14] = 'wardrobe6',
        [15] = 'wardrobe7',
        [16] = 'wardrobe8',
    }

    function get_equipped_item_id(slot_name, items)
        items = items or windower.ffxi.get_items()
        local bag = items.equipment[slot_name .. '_bag']
        local bag_name = bag_by_id[bag]
        local slot = items.equipment[slot_name]
        if not bag_name or not slot or slot == 0 then return end
        local item = items[bag_name][slot]
        if item then return item.id end
    end
end

local identify_hooked_item
do
    local function make_uid(item, normal_mod, legendary_mod, size_mod)
        local stamina = item.stamina
        local arrow_duration = item.arrow_duration
        local arrow_frequency = item.arrow_frequency
        if item.count then
            local count_mod = 1 + 0.1 * (item.count - 1)
            stamina = math.floor(stamina * count_mod)
            arrow_duration = math.floor(arrow_duration * count_mod)
            arrow_frequency = math.floor(arrow_frequency * count_mod)
        end
        local size = item.size or 0
        if size_mod == 0 and size == 1 then
            arrow_duration = math.max(arrow_duration - 1, 1)
            arrow_frequency = arrow_frequency + 2
        elseif size_mod == 1 and size == 0 then
            arrow_duration = math.max(arrow_duration - 2, 1)
            arrow_frequency = math.max(arrow_frequency - 1, 1)
        end
        local stamina_depletion = item.stamina_depletion
        if normal_mod and not item.legendary then
            stamina_depletion = math.floor(stamina_depletion * normal_mod)
        end
        legendary_mod = legendary_mod or normal_mod
        if legendary_mod and item.legendary then
            stamina_depletion = math.floor(stamina_depletion * legendary_mod)
        end
        return table.concat({stamina, math.min(arrow_duration, 15), math.min(arrow_frequency, 15), stamina_depletion * 20, size}, ',')
    end

    local item_by_rod_and_uid = {}

    local function find_item(stamina_base, fishing_parameters)
        local range_id = get_equipped_item_id('range')
        local rod_modifiers = data.rod_modifiers_by_id[range_id]
        if not rod_modifiers then return end
        if not item_by_rod_and_uid[range_id] then
            local item_by_uid = {}
            for i = 1, #data.item_fishing_parameters do
                local item = data.item_fishing_parameters[i]
                local uid = make_uid(item, unpack(rod_modifiers))
                if not item_by_uid[uid] then item_by_uid[uid] = {} end
                table.insert(item_by_uid[uid], item)
            end
            item_by_rod_and_uid[range_id] = item_by_uid
        end
        local uid = table.concat({stamina_base, fishing_parameters[2], fishing_parameters[4], fishing_parameters[5], fishing_parameters[8] % 2}, ',')
        return item_by_rod_and_uid[range_id][uid]
    end

    function identify_hooked_item(fishing_parameters)
        local continent = data.continent_by_zone[windower.ffxi.get_info().zone] or 1
        local identified = {}
        for i = 95, 105 do
            if fishing_parameters[1] % i == 0 then
                local item = find_item(math.floor(fishing_parameters[1] / i), fishing_parameters)
                if item then
                    for j = 1, #item do
                        if not item[j].continent or bit.band(item[j].continent, continent) ~= 0 then
                            table.insert(identified, item[j])
                        end
                    end
                end
            end
        end
        if #identified == 0 then
            table.insert(identified, data.unknown_item)
        end
        return identified
    end
end

-- returns a display string of candidate names and a monster flag
local function describe_identified(fishing_parameters)
    local ok, identified = pcall(identify_hooked_item, fishing_parameters)
    if not ok or not identified then return end
    local names, seen, monster = {}, {}, false
    for i = 1, #identified do
        local item = identified[i]
        if item.id == 80000 then
            monster = true
        else
            local label = item.id == 80001 and '???' or item.name
            if item.count then label = label .. ' x' .. item.count end
            if not seen[label] then
                seen[label] = true
                names[#names + 1] = label
            end
        end
    end
    if #names > 3 then
        names = {names[1], names[2], names[3], '...'}
    end
    return table.concat(names, ' / '), monster
end

-------------------------------------------------------------------------------
-- Rendering (Slate panel, libs/slate.lua)
-------------------------------------------------------------------------------

local UI_W  = 270
local ROW_H = 17
local DIV_H = 7

-- history entry color name -> slate token (filled in build_ui, after slate
-- scale is set)
local HIST_COLORS

local ui = {
    built = false,
    panel = nil,
    zone = nil,
    meta = nil,
    hist = {},       -- pooled: {ts, txt}
    divs = {},
    scrollind = nil,
    status = nil,
    foot1 = nil,
    foot2 = nil,
    histbox = nil,   -- wheel-scroll / right-click region over the content
}

local function build_ui()
    if ui.built then
        return
    end
    ui.built = true
    slate.set_scale(tonumber(settings.ui.scale) or 1)
    HIST_COLORS = {
        catch   = slate.color.ok,
        track   = slate.color.accent,
        miss    = slate.color.text_faint,
        lost    = slate.color.warn,
        brk     = slate.color.bad,
        skill   = slate.color.warn,
        monster = slate.color.bad,
        info    = slate.color.text_dim,
        value   = slate.color.text,
    }
    ui.panel = slate.Panel({
        x = settings.display.pos.x,
        y = settings.display.pos.y,
        pos_source = function() return settings.display.pos.x, settings.display.pos.y end,
        w = UI_W,
        content_h = 60,
        title = 'FISHLOG',
        minimized = settings.ui.minimized,
        on_move = function(x, y)
            settings.display.pos.x = x
            settings.display.pos.y = y
            config.save(settings)
        end,
        on_minimize = function(min)
            settings.ui.minimized = min
            config.save(settings)
            render()
        end,
    })
    ui.zone = ui.panel:add(slate.Label({size = 10, color = slate.color.text}), 10, 4)
    ui.meta = ui.panel:add(slate.Label({size = 9, color = slate.color.text_dim}), 10, 4 + ROW_H)
    for i = 1, 3 do
        ui.divs[i] = ui.panel:add(slate.Divider({w = UI_W - 20}), 10, 0)
    end
    ui.scrollind = ui.panel:add(slate.Label({size = 9, color = slate.color.text_dim}), 10, 0)
    ui.status = ui.panel:add(slate.Label({size = 10, color = slate.color.text_dim}), 10, 0)
    ui.foot1 = ui.panel:add(slate.Label({size = 9, color = slate.color.text_dim}), 10, 0)
    ui.foot2 = ui.panel:add(slate.Label({size = 9, color = slate.color.text_dim}), 10, 0)
    ui.histbox = ui.panel:add(slate.HitBox({
        w = UI_W, h = 10,
        on_scroll = function(delta)
            local max_offset = math.max(#history - settings.lines, 0)
            if delta > 0 then
                view_offset = math.min(view_offset + 3, max_offset)
            else
                view_offset = math.max(view_offset - 3, 0)
            end
            render()
        end,
        on_rclick = function()
            settings.compact = not settings.compact
            config.save(settings)
            render()
        end,
    }), 0, 0)
end

local function ensure_hist(n)
    for i = #ui.hist + 1, n do
        ui.hist[i] = {
            ts  = ui.panel:add(slate.Label({size = 9, font = slate.font.mono, color = slate.color.text_faint}), 10, 0),
            txt = ui.panel:add(slate.Label({size = 10, color = slate.color.text}), 68, 0),
        }
    end
end

render = function()
    if not settings.visible then
        if ui.built then
            ui.panel:hide()
        end
        return
    end
    local info = windower.ffxi.get_info()
    local player = info.logged_in and windower.ffxi.get_player()
    if not player then
        if ui.built then
            ui.panel:hide()
        end
        return
    end
    check_today()
    build_ui()
    if not ui.panel:visible() then
        ui.panel:show()
    end
    if ui.panel:is_minimized() then
        return
    end

    local y = 4

    -- header: zone, then skill / moon / session clock
    local zone = res.zones[info.zone] and res.zones[info.zone].en or ''
    ui.zone:text(zone)
    ui.panel:place(ui.zone, 10, y)
    y = y + ROW_H

    local skill = player.skills and player.skills.fishing
    -- the game's in-memory integer is STALE (refreshes only on menu/zone/login);
    -- a level boundary seen in chat is fresher, so floor the shown integer to the
    -- highest level we've actually confirmed
    if skill and settings.known_int and settings.known_int > skill then
        skill = settings.known_int
    end
    -- show the exact decimal when we've pinned it. The game's integer may be
    -- STALE (it only refreshes on menu open/zone/login), so a pinned value at
    -- or above it is trusted; only a pinned value BELOW the integer means we
    -- missed skill-ups. Otherwise "<int>.?" = decimal not yet known.
    local skill_str
    if settings.known_skill > 0 and skill
       and math.floor(settings.known_skill + 1e-4) >= skill then
        skill_str = string.format('%.1f', settings.known_skill)
    elseif skill then
        skill_str = skill .. '.?'
    else
        skill_str = '?'
    end
    local clock = session.start and format_dur(os.time() - session.start) or '0:00'
    local meta = 'skill ' .. skill_str
    if info.moon then
        meta = meta .. '  ·  moon ' .. info.moon .. '%'
    end
    ui.meta:text(meta .. '  ·  ' .. clock)
    ui.panel:place(ui.meta, 10, y + 1)
    y = y + ROW_H

    ui.panel:place(ui.divs[1], 10, y + 3)
    y = y + DIV_H

    -- history window (hidden entirely in compact mode)
    local hist_used = 0
    if not settings.compact then
        local total = #history
        local last = total - view_offset
        local first = math.max(last - settings.lines + 1, 1)
        if total == 0 then
            ensure_hist(1)
            hist_used = 1
            local row = ui.hist[1]
            row.ts:text('')
            row.txt:text('cast a line to begin...')
            row.txt:color(slate.color.text_faint)
            ui.panel:place(row.ts, 10, y + 1)
            ui.panel:place(row.txt, 68, y)
            y = y + ROW_H
        else
            ensure_hist(last - first + 1)
            for i = first, last do
                local e = history[i]
                hist_used = hist_used + 1
                local row = ui.hist[hist_used]
                row.ts:text(e.ts)
                row.txt:text(e.icon .. ' ' .. e.text)
                row.txt:color(HIST_COLORS[e.color] or slate.color.text)
                ui.panel:place(row.ts, 10, y + 1)
                ui.panel:place(row.txt, 68, y)
                y = y + ROW_H
            end
        end
        if view_offset > 0 then
            ui.scrollind:text(string.format('v %d newer (scroll down)', view_offset))
            ui.panel:place(ui.scrollind, 10, y)
            ui.scrollind:show()
            y = y + ROW_H
        else
            ui.scrollind:hide()
        end
        ui.panel:place(ui.divs[2], 10, y + 3)
        ui.divs[2]:show()
        y = y + DIV_H
    else
        ui.scrollind:hide()
        ui.divs[2]:hide()
    end

    -- live status line
    if cast.hooked then
        if cast.monster then
            ui.status:text('MONSTER ON THE LINE!')
            ui.status:color(slate.color.bad)
        else
            local what = cast.senses or cast.names or 'something'
            local kind = cast.kind and ('  (' .. cast.kind .. ')') or ''
            ui.status:text('on line: ' .. what .. kind)
            ui.status:color(slate.color.accent)
        end
    elseif player_status == 56 then
        ui.status:text('line in the water...')
        ui.status:color(slate.color.text_dim)
    else
        ui.status:text('idle')
        ui.status:color(slate.color.text_faint)
    end
    ui.panel:place(ui.status, 10, y)
    y = y + ROW_H

    ui.panel:place(ui.divs[3], 10, y + 3)
    y = y + DIV_H

    -- stats footer
    local pct = session.casts > 0
        and math.floor(session.catch_events / session.casts * 100 + 0.5) or 0
    local rate = '-'
    if session.start and session.fish > 0 then
        local hours = (os.time() - session.start) / 3600
        if hours > 0.016 then
            rate = string.format('%d', session.fish / hours + 0.5)
        end
    end
    ui.foot1:text(string.format('casts %d  ·  catch %d (%d%%)  ·  fish/hr %s',
        session.casts, session.catch_events, pct, rate))
    ui.panel:place(ui.foot1, 10, y + 1)
    y = y + ROW_H
    ui.foot2:text(string.format('skill +%.1f  ·  breaks %d  ·  today %d/200',
        session.skill, session.line_breaks + session.rod_breaks, settings.today.count))
    ui.panel:place(ui.foot2, 10, y + 1)
    y = y + ROW_H

    ui.panel:content_height(y + 4)

    -- the wheel / right-click region covers the whole content area
    ui.histbox:size(UI_W, y + 4)
    ui.panel:place(ui.histbox, 0, 0)

    -- pooled history rows beyond the current window stay hidden
    for i = 1, #ui.hist do
        local v = i <= hist_used
        ui.hist[i].ts:visible(v)
        ui.hist[i].txt:visible(v)
    end
end

-------------------------------------------------------------------------------
-- Catch / outcome handling
-------------------------------------------------------------------------------

local function on_catch(name, n)
    session.catch_events = session.catch_events + 1
    session.fish = session.fish + n
    session.tally[name] = (session.tally[name] or 0) + n
    settings.lifetime.fish = settings.lifetime.fish + n
    -- daily fatigue is tallied per catch *event* in on_status (statuses
    -- 58/61), not per fish, to match fisher and the game's /200 cap
    config.save(settings)
    cast.outcome = true

    local fight_s
    if last_hook_ts then
        local dur = os.time() - last_hook_ts
        if dur > 0 and dur < 600 then
            fight_s = dur
        end
    end
    finish_cast_row('catch', name, n, fight_s)

    local suffix = n > 1 and (' x' .. n) or ''
    if fight_s then
        suffix = suffix .. '  (' .. fight_s .. 's)'
    end
    if is_tracked(name) then
        add_entry('♦', 'track', name .. suffix)
        play(settings.sound_tracked)
        msg('Tracked catch: ' .. name .. '!')
    else
        add_entry('•', 'catch', name .. suffix)
    end
end

local function on_monster_hooked()
    if cast.monster then return end
    cast.monster = true
    add_entry('●', 'monster', 'MONSTER on the line!')
    if settings.sound_monster_enabled then
        play(settings.sound_monster)
    end
    if #settings.monster_command > 0 then
        windower.send_command(settings.monster_command)
    end
end

local function parse_line(text)
    -- bite type (order matters: !!! before !)
    if text:find('Something caught the hook!!!', 1, true) then
        cast.kind = 'big one!'
        render()
        return
    end
    if text:find('Something caught the hook!', 1, true) then
        cast.kind = 'small'
        render()
        return
    end
    if text:find('something pulling at your line', 1, true) then
        cast.kind = 'item?'
        render()
        return
    end
    if text:find('clamps onto your line ferociously', 1, true) then
        on_monster_hooked()
        return
    end

    -- keen angler's senses / epic catch
    local sensed = text:match("senses tell you that this is the pull of an? (.-)[%.!]")
    if sensed then
        cast.senses = sensed
        add_entry('›', 'info', 'senses: ' .. sensed)
        return
    end
    if text:find('verge of an epic catch', 1, true) then
        add_entry('♦', 'track', 'EPIC CATCH incoming!')
        play(settings.sound_tracked)
        return
    end

    -- Catch lines read "<name> caught a crayfish!" using the ACTOR's name,
    -- so a player fishing next to you produces the same message. Only record
    -- catches made by us. (Bite lines like "Something caught the hook!" are
    -- matched and returned above, so they never reach here.)
    local actor, rest = text:match('^%s*(%a+) caught (.+)')
    if actor then
        if actor == char_name or actor == 'You' then
            local n, name = rest:match('^(%d+) (.-)[%.!]')
            if not name then
                name = rest:match('^an? (.-)[%.!]')
                n = 1
            else
                n = tonumber(n)
            end
            if name then
                on_catch(name, n)
            end
        end
        return
    end

    -- misses and mishaps; append what was on the line when it was identified.
    -- cast.names is '' (not nil) for a monster-only bite, so guard against the
    -- empty string or we print an ugly "released  ()".
    local function with_hooked(label)
        local what = cast.senses or cast.names
        if what and what ~= '' then
            return label .. '  (' .. what .. ')'
        end
        return label
    end
    if text:find("didn't catch anything", 1, true) then
        session.nobite = session.nobite + 1
        cast.outcome = true
        finish_cast_row('nobite')
        add_entry('·', 'miss', 'no bite')
        return
    end
    if text:find('lost your catch', 1, true) or text:find('got away', 1, true) then
        session.lost = session.lost + 1
        cast.outcome = true
        finish_cast_row('lost')
        add_entry('×', 'lost', with_hooked('lost the catch'))
        return
    end
    if text:find('lost your bait', 1, true) then
        session.lost = session.lost + 1
        cast.outcome = true
        finish_cast_row('baitlost')
        add_entry('×', 'lost', with_hooked('bait lost'))
        return
    end
    if text:find('line breaks', 1, true) or text:find('line snaps', 1, true) then
        session.line_breaks = session.line_breaks + 1
        cast.outcome = true
        finish_cast_row('linebreak')
        add_entry('▼', 'brk', with_hooked('line snapped!'))
        return
    end
    if text:find('rod breaks', 1, true) or text:find('rod snaps', 1, true) then
        session.rod_breaks = session.rod_breaks + 1
        cast.outcome = true
        finish_cast_row('rodbreak')
        add_entry('▼', 'brk', with_hooked('ROD SNAPPED!'))
        return
    end
    if text:find('You give up', 1, true) then
        -- giving up on a monster is the monster's outcome, not a normal
        -- release; record it as such and skip the spurious "~ released ()"
        -- line (the "MONSTER on the line!" entry already told the story)
        if cast.monster then
            if not cast.outcome then
                cast.outcome = true
                session.monsters = session.monsters + 1
                finish_cast_row('monster')
            end
            return
        end
        session.released = session.released + 1
        cast.outcome = true
        finish_cast_row('release')
        add_entry('○', 'miss', with_hooked('released'))
        return
    end

    -- skill up
    local pts = text:match('fishing skill rises.- ([%d%.]+) point')
    if pts then
        local v = tonumber(pts) or 0
        session.skill = session.skill + v
        settings.lifetime.skill = settings.lifetime.skill + v
        -- remember this gain so reconcile_skill() can tell, when the game's
        -- integer skill next ticks up, whether the boundary was crossed by a
        -- clean +0.1 (which pins the decimal to exactly X.0)
        last_skillup = {v = v, ts = os.time()}
        -- if we already know the exact decimal, keep it exact by adding the
        -- gain (works for 0.1, 0.2, 0.3 - the delta is known precisely)
        if settings.known_skill and settings.known_skill > 0 then
            settings.known_skill = settings.known_skill + v
        end
        -- reaches-first ordering: the game does NOT guarantee "reaches level N"
        -- comes after "rises" (it frequently comes BEFORE), so if a level
        -- boundary just fired this instant, a clean +0.1 crossing pins us to
        -- exactly that level. Consume the boundary so a later rise can't re-pin.
        if last_boundary and (os.time() - last_boundary.ts) <= 5
           and math.abs(v - 0.1) < 1e-4 then
            settings.known_skill = last_boundary.n
            last_boundary = nil
        end
        -- record the skill-up against the just-finished cast that earned it
        -- (this message lands a few seconds after the catch, while the row is
        -- still buffered in finalized_row)
        if finalized_row then
            finalized_row.skillup = (finalized_row.skillup or 0) + v
        end
        config.save(settings)
        add_entry('▲', 'skill', string.format('fishing skill +%.1f', v))
        return
    end

    -- level boundary: "<name>'s fishing skill reaches level N." arrives right
    -- after the "rises" line. This is the authoritative boundary signal - the
    -- game's in-memory integer skill lags until the server resends the skills
    -- packet (menu open / zone), so we must NOT wait on it. A boundary crossed
    -- by a single +0.1 means we are at exactly N.0.
    local lvl = text:match('fishing skill reaches level (%d+)')
    if lvl then
        local n = tonumber(lvl)
        local rise_01 = last_skillup
            and (os.time() - last_skillup.ts) <= 5
            and math.abs(last_skillup.v - 0.1) < 1e-4
        if rise_01 then
            -- rises-first ordering: the crossing +0.1 already landed, so we are
            -- at exactly n.0. Consume both so a following rise can't re-pin.
            local already = settings.known_skill > 0
                and math.abs(settings.known_skill - n) < 1e-3
            settings.known_skill = n
            last_boundary = nil
            last_skillup = nil
            if not already then
                add_entry('▲', 'skill', string.format('exact skill pinned: %.1f', settings.known_skill))
            end
        else
            -- reaches-first ordering (the game often sends the boundary BEFORE
            -- the rise) or a >0.1 crossing: stash the boundary so the paired
            -- "rises" line, arriving next, can pin the decimal. Do NOT yet treat
            -- an off-by-one decimal as a contradiction - the pending +0.1 that
            -- crosses this boundary has not been added, so floor == n-1 is
            -- expected, not wrong.
            last_boundary = {n = n, ts = os.time()}
            if settings.known_skill > 0
               and math.floor(settings.known_skill + 1e-4) ~= n
               and math.floor(settings.known_skill + 1e-4) ~= n - 1 then
                settings.known_skill = 0
            end
        end
        -- the boundary message is fresher than the game's stale integer; adopt
        -- it so reconcile_skill() doesn't re-judge this level-up later, and use
        -- it as the shown-integer floor while the game's own value lags
        skill_int = n
        if n > (settings.known_int or 0) then settings.known_int = n end
        config.save(settings)
        return
    end
end

-------------------------------------------------------------------------------
-- Exact-skill tracking
--
-- The game only exposes the integer fishing skill (player.skills.fishing); the
-- decimal is hidden. Fishing skill moves in 0.1 steps, so when a *single* +0.1
-- skill-up crosses a level boundary we were necessarily at X.9 and are now at
-- exactly (X+1).0 - the one moment the decimal is knowable. The boundary is
-- signalled by the chat line "fishing skill reaches level N", handled in
-- parse_line(); from there we keep the value exact by adding each subsequent
-- gain (0.1/0.2/0.3...). A +0.2 (or larger) crossing from an UNKNOWN decimal
-- stays unknown, since e.g. X.8->.0 and X.9->.1 are indistinguishable.
--
-- IMPORTANT: the in-memory integer is STALE. The client only updates
-- player.skills.fishing when the server resends the char-skills packet (menu
-- open, zoning, login) - verified 2026-07-07, when it lagged a skill-up by 15
-- minutes. So the chat text is authoritative while we're loaded, and
-- reconcile_skill() only (a) validates the stored decimal on first sighting
-- and (b) catches skill-ups we missed entirely (gained while unloaded).
-------------------------------------------------------------------------------

local function reconcile_skill()
    local player = windower.ffxi.get_player()
    local g = player and player.skills and player.skills.fishing
    if not g then return end

    -- keep the shown-integer floor current whenever the game refreshes its value
    if g > (settings.known_int or 0) then
        settings.known_int = g
        config.save(settings)
    end

    -- first sighting this load: adopt the integer, and distrust a stored
    -- decimal the game says is too low (we skilled up while unloaded). A
    -- stored decimal ABOVE the integer is fine - skill never decreases, so
    -- that just means the game's value is stale.
    if skill_int == nil then
        skill_int = g
        if settings.known_skill > 0
           and math.floor(settings.known_skill + 1e-4) < g then
            settings.known_skill = 0
            config.save(settings)
        end
        return
    end

    if g <= skill_int then return end   -- act only on an observed level-up

    local single_01 = (g == skill_int + 1)
        and last_skillup
        and (os.time() - last_skillup.ts) <= 10
        and math.abs(last_skillup.v - 0.1) < 1e-4

    if settings.known_skill > 0 and math.floor(settings.known_skill + 1e-4) >= g then
        -- text tracking is already at (or past) this integer; trust it
    elseif single_01 then
        settings.known_skill = g                     -- exactly g.0
        config.save(settings)
        add_entry('▲', 'skill', string.format('exact skill pinned: %.1f', settings.known_skill))
    else
        settings.known_skill = 0                      -- decimal indeterminate
        config.save(settings)
    end
    skill_int = g
end

-------------------------------------------------------------------------------
-- Status transitions (fishing statuses are 56-63)
-------------------------------------------------------------------------------

local function on_status(old, new)
    if fishing_status(new) then
        last_fishing_ts = os.time()
    end
    -- status packets are a quiet moment to reconcile the exact skill decimal
    reconcile_skill()
    -- Fishing fatigue: the game bumps the daily counter once per successful
    -- catch (statuses 58/61), regardless of stack size. fisher counts the
    -- same way, and this is what the /200 daily cap actually tracks. Driving
    -- it off the status packet (our own) also keeps it player-only.
    if new == 58 or new == 61 then
        check_today()
        settings.today.count = settings.today.count + 1
        config.save(settings)
    end
    if new == 56 and old ~= 56 then
        if not session.start then
            session.start = os.time()
            flog('session start: ' .. (res.zones[windower.ffxi.get_info().zone] and res.zones[windower.ffxi.get_info().zone].en or '?'))
        end
        session.casts = session.casts + 1
        settings.lifetime.casts = settings.lifetime.casts + 1
        new_cast()
        -- persist the previous cast (with any skill-up now attached) before we
        -- start a new one
        flush_row()
        finish_cast_row('unknown')
        local ok, items = pcall(windower.ffxi.get_items)
        if ok and items then
            open_cast_row(get_equipped_item_id('range', items), get_equipped_item_id('ammo', items))
        else
            open_cast_row()
        end
        render()
    elseif new == 57 and old ~= 57 then
        session.bites = session.bites + 1
        cast.hooked = true
        last_hook_ts = os.time()
        render()
    elseif fishing_status(old) and not fishing_status(new) then
        if cast.monster and not cast.outcome then
            cast.outcome = true
            session.monsters = session.monsters + 1
            finish_cast_row('monster')
            add_entry('●', 'monster', 'monster reeled in - heads up!')
        end
        cast.hooked = false
        render()
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

windower.register_event('incoming chunk', function(id, original)
    if id == 0x037 then
        local player = windower.ffxi.get_player()
        if not player then return end
        local s = player.status
        if s == player_status then return end
        local old = player_status
        player_status = s
        on_status(old, s)
    elseif id == 0x115 then
        local fp = {string.unpack(original, 'HHHHHHHHI', 5)}
        local names, monster = describe_identified(fp)
        cast.names = names
        if pending_row then
            for i = 1, 9 do
                pending_row['p' .. i] = fp[i]
            end
            -- Fish Bite ID: unsigned int at offset 0x0A, unique per species
            if fp[4] and fp[5] then
                pending_row.bite_id = fp[4] + fp[5] * 65536
            end
            local ok, identified = pcall(identify_hooked_item, fp)
            if ok and identified then
                local ids = {}
                for i = 1, #identified do
                    ids[#ids + 1] = identified[i].id
                end
                pending_row.identified = table.concat(ids, ';')
            end
        end
        if monster then
            on_monster_hooked()
        else
            render()
        end
    end
end)

windower.register_event('incoming text', function(original)
    if not (fishing_status(player_status) or os.time() - last_fishing_ts <= 8) then
        return
    end
    local text = strip_codes(original)
    if settings.debug then
        flog('RAW: ' .. text)
    end
    parse_line(text)
end)

windower.register_event('zone change', function(new_id)
    finish_cast_row('unknown')
    flush_row()
    if session.casts > 0 and res.zones[new_id] then
        flog('zone: ' .. res.zones[new_id].en)
    end
end)

-- mouse interaction (wheel scroll, right-click compact toggle, drag,
-- minimize) is handled by the slate library via ui.histbox and the panel

local function init()
    local player = windower.ffxi.get_player()
    char_name = player and player.name
    player_status = player and player.status
    new_session()
    history = {}
    view_offset = 0
    -- forget the previous character's skill state; reconcile_skill() re-adopts
    -- the integer and re-validates this character's stored known_skill
    skill_int = nil
    last_skillup = nil
    check_today()
    render()
end

windower.register_event('load', function()
    windower.create_dir(windower.addon_path .. 'data')
    windower.create_dir(windower.addon_path .. 'data/logs')
    windower.create_dir(windower.addon_path .. 'data/casts')
    windower.create_dir(windower.addon_path .. 'data/export')
    windower.create_dir(windower.addon_path .. 'data/import')
    if windower.ffxi.get_info().logged_in then
        init()
    end
end)

windower.register_event('login', function()
    coroutine.schedule(init, 3)
end)

windower.register_event('logout', function()
    if ui.built then
        ui.panel:hide()
    end
end)

windower.register_event('unload', function()
    finish_cast_row('unknown')
    flush_row()
    if session.casts > 0 then
        flog(string.format(
            'session end: casts %d, catches %d (%d fish), no bites %d, lost %d, breaks %d, monsters %d, skill +%.1f',
            session.casts, session.catch_events, session.fish, session.nobite,
            session.lost, session.line_breaks + session.rod_breaks,
            session.monsters, session.skill))
    end
    config.save(settings)
end)

-- once-per-second: roll the daily counter at Japanese midnight (even while
-- idle) and refresh the header clock while a session is live
coroutine.schedule(function()
    while true do
        coroutine.sleep(1)
        if windower.ffxi.get_info().logged_in then
            local rolled = check_today()
            if rolled then
                config.save(settings)
            end
            reconcile_skill()
            -- grace-flush: if a finished cast has been held long enough for its
            -- skill-up window to pass (and no new cast came to flush it), write
            -- it out so it isn't stuck in memory if the player stops fishing
            if finalized_row and finalized_row._t
               and os.time() - finalized_row._t >= 12 then
                flush_row()
            end
            if settings.visible then
                if rolled then
                    render()
                elseif session.start then
                    local player = windower.ffxi.get_player()
                    local s = player and player.status
                    if fishing_status(s) or os.time() - last_fishing_ts < 30 then
                        render()
                    end
                end
            end
        end
    end
end, 1)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

local function print_tally()
    local sorted = {}
    for name, count in pairs(session.tally) do
        sorted[#sorted + 1] = {name = name, count = count}
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    if #sorted == 0 then
        msg('Nothing caught this session yet.')
    else
        msg('Session tally:')
        for _, e in ipairs(sorted) do
            msg(string.format('  %s x%d', e.name, e.count))
        end
        msg(string.format('  total: %d fish over %d casts', session.fish, session.casts))
    end
    msg(string.format('Lifetime: %d fish, %d casts, skill +%.1f',
        settings.lifetime.fish, settings.lifetime.casts, settings.lifetime.skill))
end

local function load_test_data()
    if not session.start then
        session.start = os.time() - 754
    end
    session.casts = session.casts + 9
    session.bites = session.bites + 7
    session.catch_events = session.catch_events + 5
    session.fish = session.fish + 7
    session.skill = session.skill + 0.3
    session.line_breaks = session.line_breaks + 1
    local t = {nofile = true}
    add_entry('•', 'catch', 'crayfish  (9s)', t)
    add_entry('•', 'catch', 'moat carp x3  (14s)', t)
    add_entry('·', 'miss', 'no bite', t)
    add_entry('›', 'info', 'senses: gold carp', t)
    add_entry('♦', 'track', 'rusty bucket  (11s)', t)
    add_entry('▼', 'brk', 'line snapped!', t)
    add_entry('▲', 'skill', 'fishing skill +0.1', t)
    add_entry('●', 'monster', 'MONSTER on the line!', t)
    add_entry('•', 'catch', 'crayfish  (8s)', t)
    msg('Test entries added - drag the window into place. //fl clear resets.')
end

local function export_data()
    local dir = windower.addon_path .. 'data/casts/'
    local files = windower.get_dir(dir)
    local out_name = 'fishlog_' .. anon_id(char_name or 'unknown') .. '_' .. os.date('!%Y%m%d') .. '.csv'
    local out_path = windower.addon_path .. 'data/export/' .. out_name
    local out = io.open(out_path, 'w')
    if not out then
        msg('Unable to write export file.')
        return
    end
    out:write(CSV_HEADER .. '\n')
    local rows = 0
    if files then
        table.sort(files)
        for _, name in ipairs(files) do
            if name:match('%.csv$') then
                local f = io.open(dir .. name, 'r')
                if f then
                    for line in f:lines() do
                        -- match by stable prefix, not exact string: older files
                        -- were written under an earlier CSV_HEADER (fewer
                        -- trailing columns) and would otherwise leak their
                        -- header line into the merged output as a fake row
                        if not line:find('^v,contributor,utc,') and #line > 0 then
                            out:write(line .. '\n')
                            rows = rows + 1
                        end
                    end
                    f:close()
                end
            end
        end
    end
    out:close()
    if rows == 0 then
        msg('No research data recorded yet - go fish!')
    else
        msg(string.format('Exported %d casts to addons/fishlog/data/export/%s', rows, out_name))
        msg('No character names inside - safe to share for community catch-rate research.')
    end
end

-------------------------------------------------------------------------------
-- Fish stats (//fl stats <fish>): where/when/how analysis of one species from
-- the research CSVs. Prints a summary to chat and writes a plain-text
-- report to data/export/.
-------------------------------------------------------------------------------

-- research CSV column positions. v1 rows end at fight_s, v2 added x/y/z/facing,
-- v3 added skillup - older rows simply have fewer trailing fields, so every
-- access below is nil-guarded rather than schema-switched.
local COL = {
    contributor = 2, utc = 3, zone = 5, skill = 6, rod = 8, bait = 10,
    moon_phase = 12, vana_min = 13, vana_day = 14, weather_id = 15,
    outcome = 16, bite_id = 17, caught = 28, count = 29, fight_s = 30,
    x = 31, y = 32, skillup = 35,
}

local function split_csv(line)
    local fields = {}
    for field in (line .. ','):gmatch('([^,]*),') do
        fields[#fields + 1] = field
    end
    return fields
end

-- Run fn over every data row in data/casts/, plus any community files dropped
-- into data/import/ (other players' //fl export output), so shared data joins
-- the same analysis. Duplicate rows (the same contributor at the same second,
-- e.g. your own export copied into import/, or overlapping community files)
-- are counted once.
local function scan_rows(fn)
    local seen = {}
    for _, sub in ipairs({'data/casts/', 'data/import/'}) do
        local dir = windower.addon_path .. sub
        local files = windower.get_dir(dir)
        if files then
            table.sort(files)
            for _, name in ipairs(files) do
                if name:match('%.csv$') then
                    local f = io.open(dir .. name, 'r')
                    if f then
                        for line in f:lines() do
                            if #line > 0 and not line:find('^v,contributor,utc,') then
                                local fields = split_csv(line)
                                local contributor = fields[COL.contributor] or ''
                                local utc = fields[COL.utc] or ''
                                local key = contributor .. '|' .. utc
                                if #contributor == 0 or #utc == 0 or not seen[key] then
                                    seen[key] = true
                                    fn(fields)
                                end
                            end
                        end
                        f:close()
                    end
                end
            end
        end
    end
end

-- first pass: catalogue every species caught (name, counts, bite ids) plus
-- dataset-wide provenance for the report header
local function scan_species()
    local species = {}
    local totals = {casts = 0, contributors = {}, n_contrib = 0}
    scan_rows(function(f)
        totals.casts = totals.casts + 1
        local c = f[COL.contributor] or ''
        if #c > 0 and not totals.contributors[c] then
            totals.contributors[c] = true
            totals.n_contrib = totals.n_contrib + 1
        end
        local utc = f[COL.utc] or ''
        if #utc > 0 then
            if not totals.first or utc < totals.first then totals.first = utc end
            if not totals.last or utc > totals.last then totals.last = utc end
        end
        if (f[COL.outcome] or '') == 'catch' then
            local caught = f[COL.caught] or ''
            if #caught > 0 then
                local key = caught:lower()
                local s = species[key]
                if not s then
                    s = {key = key, name = caught, catches = 0, fish = 0, bite_ids = {}}
                    species[key] = s
                end
                s.catches = s.catches + 1
                s.fish = s.fish + (tonumber(f[COL.count]) or 1)
                local bid = f[COL.bite_id] or ''
                if #bid > 0 then
                    s.bite_ids[bid] = true
                end
            end
        end
    end)
    return species, totals
end

local TOD_LABELS = {'Dawn (4-6)', 'Day (6-16)', 'Dusk (16-18)',
                    'Evening (18-20)', 'Night (20-24)', 'Dead of Night (0-4)'}

local function tod_label(vana_min)
    local h = math.floor((tonumber(vana_min) or -60) / 60)
    if h < 0 or h > 23 then return nil end
    if h < 4 then return TOD_LABELS[6] end
    if h < 6 then return TOD_LABELS[1] end
    if h < 16 then return TOD_LABELS[2] end
    if h < 18 then return TOD_LABELS[3] end
    if h < 20 then return TOD_LABELS[4] end
    return TOD_LABELS[5]
end

local function res_label(tbl, id)
    id = tonumber(id)
    local e = id and tbl[id]
    return e and e.en or nil
end

-- distinct .en labels of a resource table in id order (moon phases repeat
-- names across ids, e.g. two Waxing Crescent entries merge into one bucket)
local function res_label_order(tbl, max_id)
    local order, dup = {}, {}
    for id = 0, max_id do
        local e = tbl[id]
        if e and not dup[e.en] then
            dup[e.en] = true
            order[#order + 1] = e.en
        end
    end
    return order
end

local function cond_bump(t, label, hooked)
    if not label then return end
    local e = t[label]
    if not e then
        e = {c = 0, h = 0}
        t[label] = e
    end
    e.c = e.c + 1
    if hooked then e.h = e.h + 1 end
end

-- second pass: full tally for one species. A cast counts as a hook of the
-- target when its species-unique bite id matches (so hooks that were lost,
-- broke the line, or were released all count) or, for catches, when the
-- caught name matches (covers rows whose 0x115 packet was missed).
local function analyse_fish(target, zone_filter)
    local A = {
        hooks = 0, catches = 0, fish = 0, out = {}, pairs = {}, rods = {},
        fight = {n = 0, sum = 0}, skillups = 0, skillup_sum = 0, pos = {},
    }
    scan_rows(function(f)
        local outcome = f[COL.outcome] or ''
        if outcome == '' or outcome == 'unknown' then return end
        local zone = f[COL.zone] or ''
        if zone == '' then zone = '?' end
        if zone_filter and not zone:lower():find(zone_filter, 1, true) then return end
        local bait = f[COL.bait] or ''
        if bait == '' then bait = '?' end
        local caught = (f[COL.caught] or ''):lower()
        local bid = f[COL.bite_id] or ''

        local hooked
        if outcome == 'catch' then
            hooked = caught == target.key
        else
            hooked = #bid > 0 and target.bite_ids[bid] or false
        end

        local pkey = zone .. '|' .. bait
        local p = A.pairs[pkey]
        if not p then
            p = {zone = zone, bait = bait, casts = 0, hooks = 0, nobite = 0,
                 monster = 0, pool = {},
                 cond = {moon = {}, tod = {}, weather = {}, day = {}}}
            A.pairs[pkey] = p
        end
        p.casts = p.casts + 1
        cond_bump(p.cond.moon, res_label(res.moon_phases, f[COL.moon_phase]), hooked)
        cond_bump(p.cond.tod, tod_label(f[COL.vana_min]), hooked)
        cond_bump(p.cond.weather, res_label(res.weather, f[COL.weather_id]), hooked)
        cond_bump(p.cond.day, res_label(res.days, f[COL.vana_day]), hooked)

        if outcome == 'nobite' then
            p.nobite = p.nobite + 1
        elseif outcome == 'monster' or caught == 'monster' then
            p.monster = p.monster + 1
        elseif outcome == 'catch' and #caught > 0 then
            p.pool[caught] = (p.pool[caught] or 0) + 1
        end

        if not hooked then return end
        p.hooks = p.hooks + 1
        A.hooks = A.hooks + 1
        A.out[outcome] = (A.out[outcome] or 0) + 1

        local rod = f[COL.rod] or ''
        if rod == '' then rod = '?' end
        local r = A.rods[rod]
        if not r then
            r = {rod = rod, hooks = 0, landed = 0, lost = 0, broke = 0}
            A.rods[rod] = r
        end
        r.hooks = r.hooks + 1
        if outcome == 'catch' then
            r.landed = r.landed + 1
        elseif outcome == 'lost' or outcome == 'baitlost' then
            r.lost = r.lost + 1
        elseif outcome == 'linebreak' or outcome == 'rodbreak' then
            r.broke = r.broke + 1
        end

        local x, y = tonumber(f[COL.x] or ''), tonumber(f[COL.y] or '')
        if x and y then
            local pz = A.pos[zone]
            if not pz then
                pz = {n = 0, sx = 0, sy = 0, sxx = 0, syy = 0}
                A.pos[zone] = pz
            end
            pz.n = pz.n + 1
            pz.sx, pz.sy = pz.sx + x, pz.sy + y
            pz.sxx, pz.syy = pz.sxx + x * x, pz.syy + y * y
        end

        if outcome == 'catch' then
            A.catches = A.catches + 1
            A.fish = A.fish + (tonumber(f[COL.count]) or 1)
            local ft = tonumber(f[COL.fight_s] or '')
            if ft then
                A.fight.n = A.fight.n + 1
                A.fight.sum = A.fight.sum + ft
                if not A.fight.min or ft < A.fight.min then A.fight.min = ft end
                if not A.fight.max or ft > A.fight.max then A.fight.max = ft end
            end
            local sk = tonumber(f[COL.skill] or '')
            if sk and sk > 0 then
                if not A.skill_min or sk < A.skill_min then A.skill_min = sk end
                if not A.skill_max or sk > A.skill_max then A.skill_max = sk end
            end
            local su = tonumber(f[COL.skillup] or '')
            if su and su > 0 then
                A.skillups = A.skillups + 1
                A.skillup_sum = A.skillup_sum + su
            end
        end
    end)
    return A
end

local function fmt_pct(h, c)
    if c == 0 then return '-' end
    local p = math.floor(h / c * 100 + 0.5)
    if p == 0 and h > 0 then return '<1%' end
    return string.format('%d%%', p)
end

-- small-sample marker, referenced by the report footnote
local function small(c)
    return c < 20 and ' *' or ''
end

local function trunc(s, n)
    if #s > n then return s:sub(1, n - 2) .. '..' end
    return s
end

local function comma(n)
    local s = tostring(n)
    local k
    repeat
        s, k = s:gsub('^(%d+)(%d%d%d)', '%1,%2')
    until k == 0
    return s
end

local function fmt_skill(v)
    if v % 1 < 1e-4 then return string.format('%d', v) end
    return string.format('%.1f', v)
end

local function title_case(s)
    return (s:gsub("(%a[%w']*)", function(w)
        return w:sub(1, 1):upper() .. w:sub(2)
    end))
end

-- best-rate condition with at least min_c casts; only meaningful when two or
-- more buckets qualify (otherwise there is nothing to compare against)
local function best_cond(t, min_c)
    local best, qualified = nil, 0
    for label, e in pairs(t) do
        if e.c >= min_c then
            qualified = qualified + 1
            if not best or e.h / e.c > best.h / best.c then
                best = {label = label, c = e.c, h = e.h}
            end
        end
    end
    if qualified >= 2 then
        return best
    end
end

local function fish_stats(args)
    local species, totals = scan_species()
    if totals.casts == 0 then
        msg('No research data recorded yet - go fish!')
        return
    end

    -- no fish given: list what the data knows about
    if #args == 0 then
        local list = {}
        for _, s in pairs(species) do
            list[#list + 1] = s
        end
        table.sort(list, function(a, b) return a.catches > b.catches end)
        msg(string.format('%s casts on record. Species caught:', comma(totals.casts)))
        local buf = {}
        for i = 1, math.min(#list, 24) do
            buf[#buf + 1] = string.format('%s x%d', list[i].name, list[i].catches)
            if #buf == 4 then
                msg('  ' .. table.concat(buf, ',  '))
                buf = {}
            end
        end
        if #buf > 0 then
            msg('  ' .. table.concat(buf, ',  '))
        end
        if #list > 24 then
            msg(string.format('  ...and %d more.', #list - 24))
        end
        msg('Usage: //fl stats <fish>   (optionally: //fl stats <fish> in <zone>)')
        return
    end

    -- '<fish> in <zone>' restricts the analysis to matching zones
    local query, zone_filter = args, nil
    local q, zf = args:match('^(.-)%s+in%s+(.+)$')
    if q and #q > 0 then
        query, zone_filter = q, zf
    end

    local target = species[query]
    if not target then
        local matches = {}
        for key, s in pairs(species) do
            if key:find(query, 1, true) then
                matches[#matches + 1] = s
            end
        end
        if #matches == 1 then
            target = matches[1]
        elseif #matches > 1 then
            local names = {}
            for _, s in ipairs(matches) do
                names[#names + 1] = s.name
            end
            table.sort(names)
            msg(string.format('"%s" matches %d species: %s. Be more specific.',
                query, #matches, table.concat(names, ', ')))
            return
        else
            msg(string.format('No recorded catches of "%s". //fl stats lists every species caught so far.', query))
            return
        end
    end

    local A = analyse_fish(target, zone_filter)
    if A.hooks == 0 then
        msg(string.format('No hooks of %s%s in the data.', target.name,
            zone_filter and (' in zones matching "' .. zone_filter .. '"') or ''))
        return
    end

    -- qualifying (zone, bait) pairs: any water where this fish actually bit.
    -- These are the denominators for hook rates and condition breakdowns -
    -- casts on water where the fish cannot bite would only dilute the rates.
    local plist = {}
    for _, p in pairs(A.pairs) do
        if p.hooks > 0 then
            plist[#plist + 1] = p
        end
    end
    table.sort(plist, function(a, b)
        local ra, rb = a.hooks / a.casts, b.hooks / b.casts
        if ra ~= rb then return ra > rb end
        return a.casts > b.casts
    end)

    -- merge conditions and bite pools across qualifying pairs
    local cond = {moon = {}, tod = {}, weather = {}, day = {}}
    local pool, q_casts, q_nobite, q_monster = {}, 0, 0, 0
    for _, p in ipairs(plist) do
        q_casts = q_casts + p.casts
        q_nobite = q_nobite + p.nobite
        q_monster = q_monster + p.monster
        for dim, t in pairs(p.cond) do
            for label, e in pairs(t) do
                local m = cond[dim][label]
                if not m then
                    m = {c = 0, h = 0}
                    cond[dim][label] = m
                end
                m.c, m.h = m.c + e.c, m.h + e.h
            end
        end
        for name, n in pairs(p.pool) do
            pool[name] = (pool[name] or 0) + n
        end
    end

    -- build the report
    local title = title_case(target.name)
    local R = {}
    local function add(fmt, ...)
        R[#R + 1] = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    end

    local RULE = string.rep('=', 66)
    add(RULE)
    add(' %s - where, when and how to catch it', title:upper())
    add(' FishLog catch report | generated %s', os.date('!%Y-%m-%d'))
    add(' data: %s casts | %d contributor%s | %s to %s',
        comma(totals.casts), totals.n_contrib, totals.n_contrib == 1 and '' or 's',
        (totals.first or '?'):sub(1, 10), (totals.last or '?'):sub(1, 10))
    if zone_filter then
        add(' filter: zones matching "%s"', zone_filter)
    end
    add(RULE)
    add('')

    local landed = A.out.catch or 0
    local lost = (A.out.lost or 0) + (A.out.baitlost or 0)
    local lbreak = A.out.linebreak or 0
    local rbreak = A.out.rodbreak or 0
    local released = A.out.release or 0
    add('TOTALS')
    add('  catches      %d (%d fish counting stacks)', A.catches, A.fish)
    add('  hooked       %d times: landed %s, lost %s, line broke %s,', A.hooks,
        fmt_pct(landed, A.hooks), fmt_pct(lost, A.hooks), fmt_pct(lbreak, A.hooks))
    add('               rod broke %s, released %s',
        fmt_pct(rbreak, A.hooks), fmt_pct(released, A.hooks))
    if A.fight.n > 0 then
        add('  fight time   %d-%ds on the line, avg %.1fs',
            A.fight.min, A.fight.max, A.fight.sum / A.fight.n)
    end
    if A.skill_min then
        add('  caught at    fishing skill %s to %s',
            fmt_skill(A.skill_min), fmt_skill(A.skill_max))
    end
    if A.skillups > 0 then
        add('  skill-ups    %d catches skilled up (+%.1f total)',
            A.skillups, A.skillup_sum)
    end
    add('')

    add('WHERE TO FISH (hook rate = bites of this fish per cast)')
    add('  %-23s %-19s %5s %5s %5s', 'zone', 'bait', 'casts', 'hooks', 'rate')
    for i = 1, math.min(#plist, 12) do
        local p = plist[i]
        add('  %-23s %-19s %5d %5d %5s%s', trunc(p.zone, 23), trunc(p.bait, 19),
            p.casts, p.hooks, fmt_pct(p.hooks, p.casts), small(p.casts))
    end
    add('')

    local pos_lines = {}
    for zone, pz in pairs(A.pos) do
        if pz.n >= 3 then
            local mx, my = pz.sx / pz.n, pz.sy / pz.n
            local var = math.max(pz.sxx / pz.n - mx * mx, 0)
                      + math.max(pz.syy / pz.n - my * my, 0)
            pos_lines[#pos_lines + 1] = string.format(
                '  %-23s x %.1f, y %.1f  (spread %.1f, %d hooks)',
                trunc(zone, 23), mx, my, math.sqrt(var), pz.n)
        end
    end
    if #pos_lines > 0 then
        table.sort(pos_lines)
        add('SPOTS (average standing position of hooks)')
        for _, l in ipairs(pos_lines) do
            add(l)
        end
        add('')
    end

    local rlist = {}
    for _, r in pairs(A.rods) do
        rlist[#rlist + 1] = r
    end
    table.sort(rlist, function(a, b) return a.hooks > b.hooks end)
    add('RODS (landing the fish once hooked)')
    add('  %-23s %5s %7s %6s %6s', 'rod', 'hooks', 'landed', 'lost', 'broke')
    for _, r in ipairs(rlist) do
        add('  %-23s %5d %7s %6s %6s%s', trunc(r.rod, 23), r.hooks,
            fmt_pct(r.landed, r.hooks), fmt_pct(r.lost, r.hooks),
            fmt_pct(r.broke, r.hooks), small(r.hooks))
    end
    add('')

    add('CONDITIONS (hook rate on the waters listed above)')
    add('  %-23s %5s %5s %5s', '', 'casts', 'hooks', 'rate')
    local dims = {
        {key = 'moon', name = 'moon phase', order = res_label_order(res.moon_phases, 11)},
        {key = 'tod', name = "time of day (Vana'diel)", order = TOD_LABELS},
        {key = 'weather', name = 'weather', order = res_label_order(res.weather, 19)},
        {key = 'day', name = 'day', order = res_label_order(res.days, 7)},
    }
    for _, dim in ipairs(dims) do
        local t = cond[dim.key]
        if next(t) then
            add('  -- %s', dim.name)
            for _, label in ipairs(dim.order) do
                local e = t[label]
                if e then
                    add('  %-23s %5d %5d %5s%s', label, e.c, e.h,
                        fmt_pct(e.h, e.c), small(e.c))
                end
            end
        end
    end
    add('')

    local competitors = {}
    for name, n in pairs(pool) do
        competitors[#competitors + 1] = {name = name, n = n}
    end
    if q_monster > 0 then
        competitors[#competitors + 1] = {name = 'MONSTER', n = q_monster}
    end
    if q_nobite > 0 then
        competitors[#competitors + 1] = {name = 'no bite', n = q_nobite}
    end
    table.sort(competitors, function(a, b) return a.n > b.n end)
    add('WHAT ELSE TAKES THIS BAIT (share of the %s casts above)', comma(q_casts))
    local buf = {}
    for i = 1, math.min(#competitors, 12) do
        buf[#buf + 1] = string.format('%s %s',
            competitors[i].name, fmt_pct(competitors[i].n, q_casts))
        if #buf == 4 then
            add('  ' .. table.concat(buf, ' | '))
            buf = {}
        end
    end
    if #buf > 0 then
        add('  ' .. table.concat(buf, ' | '))
    end
    add('')

    add(string.rep('-', 66))
    add('* fewer than 20 casts - small sample, treat as a hint')
    add('Condition rates are observational (you fish when you fish); vary')
    add('your sessions across moons/times/weather to firm them up.')
    add('Generated by the FishLog Windower addon (//fl stats). Every cast is')
    add("logged as one CSV row; drop friends' //fl export files into")
    add('data/import/ and their casts join this analysis automatically.')

    -- write the report file
    local fname = 'stats_' .. target.key:gsub('%W+', '_')
        .. (zone_filter and ('_in_' .. zone_filter:gsub('%W+', '_')) or '')
        .. '_' .. os.date('!%Y%m%d') .. '.txt'
    local out = io.open(windower.addon_path .. 'data/export/' .. fname, 'w')
    local saved = false
    if out then
        out:write(table.concat(R, '\n') .. '\n')
        out:close()
        saved = true
    end

    -- chat summary: the headline numbers plus the best water and conditions
    msg(string.format('%s: %d catches (%d fish) from %d hooks, %s landed.',
        title, A.catches, A.fish, A.hooks, fmt_pct(landed, A.hooks)))
    for i = 1, math.min(#plist, 2) do
        local p = plist[i]
        msg(string.format('  %s + %s: %s hook rate (%d casts%s)',
            p.zone, p.bait, fmt_pct(p.hooks, p.casts), p.casts,
            p.casts < 20 and ', small sample' or ''))
    end
    local bests = {}
    for _, t in ipairs({cond.moon, cond.tod, cond.weather}) do
        local b = best_cond(t, 15)
        if b then
            bests[#bests + 1] = string.format('%s %s (%d casts)',
                b.label, fmt_pct(b.h, b.c), b.c)
        end
    end
    if #bests > 0 then
        msg('  Best conditions: ' .. table.concat(bests, ' | '))
    end
    if saved then
        msg('Full report: addons/fishlog/data/export/' .. fname)
    else
        msg('Warning: could not write the report file.')
    end
end

local HELP = {
    '//fl              toggle the window',
    '//fl clear        reset the session (history, stats, timer)',
    '//fl tally        print per-catch counts to chat',
    '//fl track <name> chime + highlight when <name> is caught (substring, e.g. "rusty")',
    '//fl untrack <name> / //fl tracked',
    '//fl lines <n>    history rows shown (3-25)',
    '//fl compact      hide history (right-click the window does this too)',
    '//fl sound on|off all sounds; //fl sound monster on|off just the monster jingle',
    '//fl today <n|+n|-n> correct the daily fatigue counter (no packet exists for it)',
    '//fl skill <n.n>  set the exact skill decimal (pins itself on +0.1 level-ups)',
    '//fl stats <fish> [in <zone>]  full where/when/how analysis of one species',
    '//fl stats        list every species in the research data',
    '//fl export       merge all research CSVs into one shareable file',
    '//fl research on|off  per-cast CSV logging (rod/bait/moon/weather/outcome)',
    '//fl test         insert sample entries to position the window',
    '//fl debug on|off write raw fishing chat lines to the file log',
    'Scroll wheel over the window pages through older entries.',
}

windower.register_event('addon command', function(command, ...)
    if slate.handle_command(command, ...) then
        return
    end
    command = command and command:lower() or 'toggle'
    local args = table.concat({...}, ' '):lower()

    if command == 'scale' then
        local n = tonumber(args)
        if n and n >= 0.5 and n <= 3 then
            settings.ui.scale = n
            config.save(settings)
            slate.set_scale(n)
            render()
            msg(string.format('HUD scale set to %g.', n))
        else
            msg('Usage: //fl scale <0.5-3>')
        end
    elseif command == 'toggle' or command == 'show' or command == 'hide' then
        if command == 'toggle' then
            settings.visible = not settings.visible
        else
            settings.visible = command == 'show'
        end
        config.save(settings)
        render()
    elseif command == 'clear' then
        new_session()
        history = {}
        view_offset = 0
        render()
        msg('Session cleared.')
    elseif command == 'tally' then
        print_tally()
    elseif command == 'track' then
        if #args == 0 then
            msg('Usage: //fl track <name or part of name>')
        else
            local list = tracked_list()
            list[#list + 1] = args
            settings.tracked = table.concat(list, ',')
            config.save(settings)
            msg('Tracking: ' .. args)
        end
    elseif command == 'untrack' then
        local list = tracked_list()
        local kept = {}
        for _, t in ipairs(list) do
            if t ~= args then kept[#kept + 1] = t end
        end
        settings.tracked = table.concat(kept, ',')
        config.save(settings)
        msg('No longer tracking: ' .. args)
    elseif command == 'tracked' then
        local list = tracked_list()
        msg(#list > 0 and ('Tracked: ' .. table.concat(list, ', ')) or 'Nothing tracked. //fl track <name>')
    elseif command == 'lines' then
        local n = tonumber(args)
        if n then
            settings.lines = math.max(3, math.min(25, math.floor(n)))
            config.save(settings)
            render()
        end
    elseif command == 'compact' then
        settings.compact = not settings.compact
        config.save(settings)
        render()
    elseif command == 'sound' then
        local which, state = args:match('^(%a+)%s+(%a+)$')
        if which == 'monster' then
            settings.sound_monster_enabled = state ~= 'off'
            config.save(settings)
            msg('Monster sound ' .. (settings.sound_monster_enabled and 'on.' or 'off.'))
        else
            settings.sound_enabled = args ~= 'off'
            config.save(settings)
            msg('Sounds ' .. (settings.sound_enabled and 'on.' or 'off.'))
        end
    elseif command == 'today' then
        check_today()
        local v = tonumber(args)
        if not v then
            msg(string.format('Today: %d/200 caught. //fl today <n|+n|-n> to correct.', settings.today.count))
        else
            if args:match('^[+-]') then
                settings.today.count = math.max(settings.today.count + v, 0)
            else
                settings.today.count = math.max(math.floor(v), 0)
            end
            config.save(settings)
            render()
            msg(string.format('Today set to %d/200.', settings.today.count))
        end
    elseif command == 'stats' or command == 'fish' then
        fish_stats(args)
    elseif command == 'skill' then
        local v = tonumber(args)
        if not v then
            if settings.known_skill > 0 then
                msg(string.format('Exact skill: %.1f. //fl skill <n.n> to correct.', settings.known_skill))
            else
                msg('Exact skill unknown (decimal pins on the next +0.1 level-up). //fl skill <n.n> to set it.')
            end
        elseif v < 0 or v > 110 then
            msg('Skill must be between 0 and 110.')
        else
            settings.known_skill = math.floor(v * 10 + 0.5) / 10
            config.save(settings)
            render()
            msg(string.format('Exact skill set to %.1f.', settings.known_skill))
        end
    elseif command == 'export' then
        export_data()
    elseif command == 'research' then
        settings.research = args ~= 'off'
        config.save(settings)
        msg('Research cast logging ' .. (settings.research and 'on.' or 'off.'))
    elseif command == 'debug' then
        settings.debug = args ~= 'off'
        config.save(settings)
        msg('Debug ' .. (settings.debug and 'on - raw fishing chat lines will be written to data/logs.' or 'off.'))
    elseif command == 'test' then
        load_test_data()
    elseif command == 'help' then
        for _, line in ipairs(HELP) do
            msg(line)
        end
    else
        msg('Unknown command. //fl help')
    end
end)
