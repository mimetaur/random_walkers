-- Random Walkers

engine.name = "PolyPercPannable"

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local RELOAD_LIBS = true
local DEFAULT_CELL_BRIGHTNESS = 8
local MIN_BRIGHTNESS = 2
local MAX_AMP = 0.8
local MIN_AMP = 0.2

-------------------------------------------------------------------------------
-- Script Local Vars
-------------------------------------------------------------------------------
local json = require "agents/lib/json"

local libs = {
    world_path = "agents/lib/world",
    walker_path = "agents/lib/walker",
    walker_sonar_path = "agents/lib/walker_sonar",
    arc_params = "arc_params/lib/arc_params"
}
if RELOAD_LIBS then
    local reload_libraries = require "agents/lib/reload_libraries"
    reload_libraries.with_table(libs)
end

local World = require(libs.world_path)
local Walker = require(libs.walker_path)
local WalkerSonar = require(libs.walker_sonar_path)
local ArcParams = require(libs.arc_params)

-- script vars
local world = {}
local walkers = {}

local scale_names = {}
local notes = {}

-- arc
local ar = arc.connect()
local arc_params = ArcParams.new(ar)

function ar.delta(n, delta)
    arc_params:update(n, delta)
end

-- OSC
dest = {"192.168.1.12", 10112}
local connected_osc = false

-------------------------------------------------------------------------------
-- OSC
-------------------------------------------------------------------------------
local function send_world_size()
    local w, h = world:size()
    osc.send(dest, "/world/size", {w, h, world:cell_size()})
end

function osc_in(path, args, from)
    if path == "/hello" then
        print("received /hello")
        dest[1] = from[1]
        osc.send(dest, "/hello")
        send_world_size()
        connected_osc = true
    else
        print("osc from " .. from[1] .. " port " .. from[2])
    end
end
osc.event = osc_in

-------------------------------------------------------------------------------
-- BeatClock Callbacks
-------------------------------------------------------------------------------
local function step()
    world:update()
    for i, walker in ipairs(walkers) do
        walker:update(world)
        walker.sonar:step()
    end

    redraw()
end
-- step needs to be defined first
local clock = metro.init(step, 1, -1)

local function reset()
    world:reset()
end

-------------------------------------------------------------------------------
-- World Callbacks
-------------------------------------------------------------------------------
local function on_update_cell(self, x, y, cell)
    cell.brightness = cell.brightness - 1
    if cell.brightness < MIN_BRIGHTNESS then
        self:delete_cell(x, y)
    end
end

-- throttling osc output
-- TODO parameterize this
local counter = 1
local osc_threshold = 5
local function on_world_draw(self)
    if not connected_osc then
        return
    end
    counter = counter + 1
    if counter > osc_threshold then
        local world2d = self:to_2d_array()
        local w, h = self:size()
        for col_num = 1, h do
            -- remember that every other programming language uses 0 based arrays!
            osc.send(dest, "/world/update/column", {col_num - 1, json.encode(world2d[col_num])})
        end
        counter = 1
    end
end

-------------------------------------------------------------------------------
-- Walker Callbacks
-------------------------------------------------------------------------------
local function emit(walker_sonar)
    local walker = walker_sonar:get_parent()
    local x, y = walker:position()
    local id = walker:index()

    -- print("Walker #" .. id .. " playing note " .. MusicUtil.note_num_to_name(self.note_, true))

    -- calculate the amplitude of the note, based on
    -- its distance to the nearest neighbor
    local idist = walker_sonar:inverted_normalized_distance_to_nearest_neighbor(walkers)
    local amp = util.linexp(0.0, 1.0, MIN_AMP * 0.5, MAX_AMP, idist)
    if (amp <= MIN_AMP) then
        amp = 0
    end

    local cell_linear = y * x
    local lower_bound = 0
    local upper_bound = 64 * 128
    local freq = util.linexp(lower_bound, upper_bound, params:get("low_freq"), params:get("hi_freq"), cell_linear)

    local release_pct = params:get("release_mult") / 100
    local rel = walker_sonar:get_release_amount() * release_pct

    local num = walker:num()
    local pw = util.linexp(0, #walkers, 0.2, 0.8, num)
    local pan = util.linlin(0, #walkers, -0.9, 0.9, num)

    engine.pan(pan)
    engine.amp(amp)
    engine.pw(pw)
    engine.release(rel)
    engine.hz(freq)
end

-------------------------------------------------------------------------------
-- Param Action Callbacks
-------------------------------------------------------------------------------
local function change_walkers(value)
    local amount = math.ceil(value)
    local offset = math.random(amount)
    if amount > #walkers then
        local diff = amount - #walkers
        for i = 1, diff do
            local w, h = world:size()
            local walker = Walker.new(math.random(w), math.random(h), i)

            local emit_rate = math.random(32, 128)

            local r = (walker:index() % #WalkerSonar.RELEASE_TIMES)
            local release_idx = util.clamp(r, 1, #WalkerSonar.RELEASE_TIMES)

            walker.sonar = WalkerSonar.new(walker, note, emit, emit_rate, release_idx, params:get("max_dist"))
            table.insert(walkers, walker)
        end
    else
        local diff = #walkers - amount
        for i = 1, diff do
            table.remove(walkers)
        end
    end
end

local function set_speed(value)
    local time = value / 1000
    clock:stop()
    clock:start(time)
end

-------------------------------------------------------------------------------
-- Norns Methods
-------------------------------------------------------------------------------

function init()
    local opts = {}
    opts.cell_size = 2
    opts.update_cell_func = on_update_cell
    opts.draw_func = on_world_draw
    opts.default_brightness = DEFAULT_CELL_BRIGHTNESS
    world = World.new(opts)

    params:add {
        type = "number",
        id = "speed",
        name = "speed",
        min = 20,
        max = 1000,
        default = 200,
        formatter = function(param)
            local speed_str = math.ceil(param:get("speed")) .. "ms"
            return speed_str
        end,
        action = function(value)
            set_speed(value)
        end
    }
    params:add {
        type = "number",
        id = "num_walkers",
        name = "number of walkers",
        min = 1,
        max = 128,
        default = 4,
        action = function(value)
            change_walkers(value)
        end
    }
    params:add {
        type = "number",
        id = "max_dist",
        name = "max distance threshold",
        min = 8,
        max = 180,
        default = 64,
        action = function(value)
            for i, walker in ipairs(walkers) do
                if walker and walker.sonar then
                    walker.sonar:set_max_dist(value)
                end
            end
        end
    }
    params:add_separator()
    params:add {
        type = "number",
        id = "low_freq",
        name = "lowest frequency",
        min = 100,
        max = 1000,
        default = 200
    }
    params:add {
        type = "number",
        id = "hi_freq",
        name = "highest frequency",
        min = 1000,
        max = 10000,
        default = 5000
    }
    params:add {
        type = "number",
        id = "release_mult",
        name = "release percentage",
        min = 1,
        max = 100,
        default = 50,
        formatter = function(param)
            local rel_pct = math.ceil(param:get("release_mult")) .. "%"
            return rel_pct
        end
    }

    params:default()

    arc_params:register_at(1, "release_mult")
    arc_params:register_at(2, "max_dist")
    arc_params:register_at(3, "num_walkers", 1.0)
    arc_params:register_at(4, "speed", 1.0)
    arc_params:add_arc_params()

    clock:start(params:get("speed") / 1000, -1)
end

function key(n, z)
    if n == 2 and z == 1 then
        reset()
    end

    redraw()
end

function redraw()
    screen.clear()
    world:draw()
    screen.update()
end
