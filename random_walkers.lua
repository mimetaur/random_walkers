-- Random Walkers

engine.name = "RandomWalkerPolyPercPannable"

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local DEFAULT_CELL_BRIGHTNESS = 8
local MIN_BRIGHTNESS = 2
local MAX_AMP = 0.8
local MIN_AMP = 0.2

-------------------------------------------------------------------------------
-- DEPENDENCIES
-------------------------------------------------------------------------------

local ArcParams = include("arc_params/lib/arc_params")

local json = include("random_walkers/lib/json")
local World = include("random_walkers/lib/world")
local Walker = include("random_walkers/lib/walker")
local WalkerSonar = include("random_walkers/lib/walker_sonar")

local Billboard = include("billboard/lib/billboard")
local billboard = Billboard.new()

-------------------------------------------------------------------------------
-- Script Local Vars
-------------------------------------------------------------------------------

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
            billboard:display_param("speed", math.ceil(value))
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
            billboard:display_param("num walkers", math.ceil(value))
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
            billboard:display_param("distance threshold", math.ceil(value))
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
        end,
        action = function(value)
            billboard:display_param("release amount", math.ceil(value) .. "%")
        end
    }

    arc_params:register("release_mult", 1.0)
    arc_params:register("max_dist", 1.0)
    arc_params:register("num_walkers", 0.1)
    arc_params:register("speed", 1.0)
    arc_params:add_arc_params()

    params:default()

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
    billboard:draw()
    screen.update()
end
