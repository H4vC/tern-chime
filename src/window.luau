--!strict
-- Chime: a sound when a pane raises an unseen alert, an agent yields to you,
-- or a long shell command finishes.
--
-- Triggers (all for panes you are not looking at, unless only_unfocused=false):
--   alert  a pane's unseen-alert flag rises: a terminal bell, an agent that
--          finished or is waiting out of sight, or a pane whose program
--          exited. Tern shows one alert per pane until you look at it, so a
--          second bell while the flag stands chimes nothing new.
--   yield  an agent block leaves "working" for "idle": its turn is done and
--          control is back with you. (working -> "waiting_input" plays the
--          alert sound instead: it needs you, not just your attention.)
--   done   a shell command ran longer than min_seconds and finished.
--
-- Chimes never overlap: simultaneous events share one chime, and a chime in
-- one window suppresses the same moment's chime in every other window.
--
-- Configuration is sounds.toml in the plugin folder (ships with defaults) or
-- <plugin data>/sounds.toml, which wins when present so a reinstall keeps
-- your sounds. It is re-read every few seconds; no reload needed.

type Config = {
	sounds: { [string]: string },
	only_unfocused: boolean,
	min_seconds: number,
}

local TICK_MS = 250
local CONFIG_EVERY_TICKS = 20 -- re-read sounds.toml about every 5 s
local MIN_GAP_MS = 500 -- same-window debounce for back-to-back events
local CLAIM_WINDOW_MS = 2000 -- cross-window dedup: one chime per moment

local SEP = if tern.runtime.os == "windows" then "\\" else "/"
local DATA_SEP = tern.plugin.data .. SEP
local DATA_CONFIG = DATA_SEP .. "sounds.toml"
local PLUGIN_CONFIG = tern.plugin.dir .. SEP .. "sounds.toml"

-- Config ----------------------------------------------------------------------------------

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Cut a `#` comment, keeping `#` inside quotes.
local function strip_comment(line: string): string
	local in_single = false
	local in_double = false
	local i = 1
	while i <= #line do
		local c = string.sub(line, i, i)
		if c == "\\" and (in_single or in_double) then
			i += 2
		elseif c == "'" and not in_double then
			in_single = not in_single
			i += 1
		elseif c == '"' and not in_single then
			in_double = not in_double
			i += 1
		elseif c == "#" and not in_single and not in_double then
			return string.sub(line, 1, i - 1)
		else
			i += 1
		end
	end
	return line
end

-- A quoted value without its quotes, or nil when not quoted. Only the
-- matching quote and the backslash unescape, so Windows paths work as-is
-- in double quotes (`"C:\sounds\ping.wav"` needs no doubling).
local function unquote(s: string): string?
	if #s < 2 then
		return nil
	end
	local first = string.sub(s, 1, 1)
	if first ~= '"' and first ~= "'" then
		return nil
	end
	if string.sub(s, -1) ~= first then
		return nil
	end
	local inner = string.sub(s, 2, -2)
	if first == '"' then
		inner = string.gsub(inner, '\\"', '"')
		inner = string.gsub(inner, "\\\\", "\\")
	else
		inner = string.gsub(inner, "\\'", "'")
	end
	return inner
end

local function default_config(): Config
	local dir = tern.plugin.dir .. SEP .. "sounds"
	return {
		sounds = {
			alert = dir .. SEP .. "alert.wav",
			yield = dir .. SEP .. "yield.wav",
			done = dir .. SEP .. "done.wav",
		},
		only_unfocused = true,
		min_seconds = 30,
	}
end

local function is_absolute(p: string): boolean
	if string.sub(p, 1, 1) == "/" then
		return true
	end
	return string.match(p, "^[A-Za-z]:[\\/]") ~= nil or string.sub(p, 1, 2) == "\\\\"
end

local function resolve_path(p: string, base: string): string
	if string.sub(p, 1, 1) == "~" then
		local home = tern.getenv("HOME") or tern.getenv("USERPROFILE") or ""
		if home ~= "" then
			p = home .. string.sub(p, 2)
		end
	end
	if is_absolute(p) then
		return p
	end
	return base .. SEP .. p
end

local function parse_config(text: string, base: string): (Config, { string })
	local config = default_config()
	local problems: { string } = {}
	for raw in string.gmatch(text, "[^\r\n]+") do
		local line = trim(strip_comment(raw))
		if line ~= "" then
			local key, value = string.match(line, "^([A-Za-z_][%w_]*)%s*=%s*(.-)%s*$")
			if key == nil or value == nil or value == "" then
				table.insert(problems, "Skipping line: " .. line)
			elseif key == "alert" or key == "yield" or key == "done" then
				local quoted = unquote(value)
				if quoted == nil then
					table.insert(problems, key .. ": expected a quoted path, got " .. value)
				elseif quoted == "" then
					config.sounds[key] = ""
				else
					config.sounds[key] = resolve_path(quoted, base)
				end
			elseif key == "only_unfocused" then
				if value == "true" then
					config.only_unfocused = true
				elseif value == "false" then
					config.only_unfocused = false
				else
					table.insert(problems, "only_unfocused: expected true or false, got " .. value)
				end
			elseif key == "min_seconds" then
				local n = tonumber(value)
				if n == nil or n < 0 then
					table.insert(proproblems, "min_seconds: expected seconds >= 0, got " .. value)
				else
					config.min_seconds = n
				end
			else
				table.insert(problems, "Unknown key: " .. key)
			end
		end
	end
	return config, problems
end

local config = default_config()
local config_source = "(defaults)"
local config_key: string? = nil
local warned: { [string]: boolean } = {}

-- The data-folder config wins when it reads; the shipped one is the fallback.
local function read_config_file(): (string?, string?)
	for _, path in { DATA_CONFIG, PLUGIN_CONFIG } do
		local ok, text = pcall(tern.fs.read, path, 64 * 1024)
		if ok and type(text) == "string" then
			return text :: string, path
		end
	end
	return nil, nil
end

local function load_config(): { string }
	local text, path = read_config_file()
	if text == nil or path == nil then
		config = default_config()
		config_source = "(defaults)"
		warned = {}
		return {}
	end
	local parsed, problems = parse_config(text, if path == DATA_CONFIG then tern.plugin.data else tern.plugin.dir)
	config = parsed
	config_source = path
	warned = {}
	for kind, sound in config.sounds do
		if sound ~= "" and not tern.fs.exists(sound) then
			table.insert(problems, kind .. ": file not found: " .. sound)
		end
	end
	return problems
end

local function snapshot_key(): string?
	local text, path = read_config_file()
	if text == nil or path == nil then
		return nil
	end
	return path .. "\n" .. text
end

local function maybe_reload_config()
	local key = snapshot_key()
	if key == config_key then
		return
	end
	config_key = key
	local problems = load_config()
	if #problems > 0 then
		tern.log.warn("Chime: " .. table.concat(problems, "; "))
	end
end

-- Mute + cross-window claim -----------------------------------------------------------------

local is_muted = false

local function refresh_muted()
	local ok, value = pcall(tern.kv.get, "muted")
	is_muted = ok and value == true
end

-- One chime per moment across windows: whoever claims it plays it.
local function claim_chime(): boolean
	local now_ms = tern.now()
	local ok, at = pcall(tern.kv.get, "last_chime")
	-- `at <= now_ms` ignores a stale value written by an older build (seconds, not ms).
	if ok and type(at) == "number" and at <= now_ms and now_ms - (at :: number) < CLAIM_WINDOW_MS then
		return false
	end
	pcall(tern.kv.set, "last_chime", now_ms)
	return true
end

-- Playback ----------------------------------------------------------------------------------

local function spawn(argv: { string }, path: string, on_done: (() -> ())?)
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = 15000 }, function(result: ProcessResult)
			if result.timed_out then
				tern.log.warn("Chime: playing " .. path .. " timed out")
			elseif result.status ~= 0 then
				local detail = if result.stderr ~= "" then result.stderr else "exit " .. tostring(result.status)
				tern.log.warn("Chime: couldn't play " .. path .. ": " .. trim(detail))
			end
			if on_done then
				on_done()
			end
		end)
	end)
	if not ok then
		tern.log.warn("Chime: couldn't start the player: " .. tostring(err))
		if on_done then
			on_done()
		end
	end
end

local linux_player: string? = nil
local linux_probe_failed = false
local linux_probing = false
local linux_queue: { { path: string, on_done: (() -> ())? } } = {}

-- Preference order: PipeWire-native first (pw-play ships with pipewire),
-- then PulseAudio, ALSA, then the heavy/general players.
local LINUX_PLAYERS = { "pw-play", "paplay", "aplay", "ffplay", "play" }

local function linux_argv(player: string, path: string): { string }
	if player == "ffplay" then
		return { "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", path }
	elseif player == "play" then
		return { "play", "-q", path }
	elseif player == "aplay" then
		return { "aplay", "-q", path }
	elseif player == "paplay" then
		return { "paplay", path }
	else
		return { "pw-play", path }
	end
end

local function probe_linux_player()
	if linux_probing or linux_probe_failed or linux_player ~= nil then
		return
	end
	linux_probing = true
	-- One probe per player would serialize N spawns; instead ask sh for the
	-- first match in preference order and read back which one answered.
	local names = table.concat(LINUX_PLAYERS, " ")
	local ok, err = pcall(function()
		tern.process.run(
			{ "sh", "-c", "for p in " .. names .. "; do command -v $p >/dev/null 2>&1 && { echo $p; exit 0; }; done; exit 1" },
			{ timeout_ms = 5000 },
			function(result: ProcessResult)
				linux_probing = false
				local name = string.match(result.stdout, "([%w-]+)")
				if result.status == 0 and name ~= nil and name ~= "" then
					linux_player = name
					for _, entry in linux_queue do
						spawn(linux_argv(name, entry.path), entry.path, entry.on_done)
					end
				else
					linux_probe_failed = true
					tern.log.warn("Chime: no sound player found (need one of: " .. names .. ")")
				end
				linux_queue = {}
			end
		)
	end)
	if not ok then
		linux_probing = false
		linux_probe_failed = true
		linux_queue = {}
		tern.log.warn("Chime: couldn't probe for a sound player: " .. tostring(err))
	end
end

local warned_no_player = false

local function play_file(path: string, on_done: (() -> ())?)
	local os_name = tern.runtime.os
	if os_name == "ios" then
		if on_done then
			on_done()
		end
	elseif os_name == "windows" then
		-- Via wscript (a windowless GUI host): spawning hidden PowerShell
		-- directly still flashes a console box on creation. SoundPlayer
		-- takes WAV only.
		spawn({ "wscript.exe", "//Nologo", tern.plugin.dir .. SEP .. "scripts" .. SEP .. "play.vbs", path }, path, on_done)
	elseif os_name == "macos" then
		spawn({ "afplay", path }, path, on_done)
	elseif os_name == "linux" then
		local player = linux_player
		if player ~= nil then
			spawn(linux_argv(player, path), path, on_done)
		elseif not linux_probe_failed then
			table.insert(linux_queue, { path = path, on_done = on_done })
			probe_linux_player()
		elseif not warned_no_player then
			warned_no_player = true
			tern.log.warn("Chime: silent (no Linux player; install pipewire-pulse, alsa-utils, sox or ffmpeg)")
			if on_done then
				on_done()
			end
		else
			if on_done then
				on_done()
			end
		end
	else
		tern.log.warn("Chime: no player for " .. os_name)
		if on_done then
			on_done()
		end
	end
end

-- One sound at a time: two chimes never mix into one distorted burst.
-- `wait` queues a sound even while another plays (the palette's test sound
-- must always be heard); a normal chime is dropped while one is sounding,
-- which is what "Chimes never overlap" promises.
local queue: { string } = {}
local playing = false

local function pump()
	if playing then
		return
	end
	local path = table.remove(queue, 1)
	if path == nil then
		return
	end
	playing = true
	play_file(path, function()
		playing = false
		pump()
	end)
end

local function enqueue(path: string, wait: boolean)
	if not wait and (playing or #queue > 0) then
		return
	end
	table.insert(queue, path)
	pump()
end

local last_chime_at = -math.huge

local function chime(kind: string, _pane: number)
	local path = config.sounds[kind]
	if path == nil or path == "" or is_muted then
		return
	end
	local ok_exists, exists = pcall(tern.fs.exists, path)
	if not ok_exists or not exists then
		if not warned[path] then
			warned[path] = true
			tern.log.warn("Chime: " .. kind .. " sound not found: " .. path)
		end
		return
	end
	local now = tern.now()
	if now - last_chime_at < MIN_GAP_MS then
		return
	end
	if not claim_chime() then
		return
	end
	last_chime_at = now
	enqueue(path, false)
end

-- Triggers ----------------------------------------------------------------------------------

local function list_agents(cx: WindowCx): { AgentBlock }
	local ok, agents = pcall(function()
		return cx.agents:list()
	end)
	if ok then
		return agents :: { AgentBlock }
	end
	return {}
end

local alerts: { [number]: boolean } = {}
local agent_state: { [number]: string } = {}
local seeded = false
local tick_count = 0

local function tick_body(cx: WindowCx)
	tick_count += 1
	if tick_count % CONFIG_EVERY_TICKS == 0 then
		maybe_reload_config()
	end
	refresh_muted()

	-- One candidate per pane; the alert edge wins over a same-tick yield.
	local candidates: { [number]: string } = {}
	local focused: { [number]: boolean } = {}

	local now_alerts: { [number]: boolean } = {}
	for _, pane in cx.session:panes() do
		local id = pane.pane
		local alerted = pane.alert == true
		now_alerts[id] = alerted
		focused[id] = pane.focused == true
		if seeded and alerted and not alerts[id] then
			candidates[id] = "alert"
		end
	end
	alerts = now_alerts

	local now_states: { [number]: string } = {}
	for _, agent in list_agents(cx) do
		local id = agent.pane
		now_states[id] = agent.state
		local prev = agent_state[id]
		if prev == "working" and (agent.state == "idle" or agent.state == "waiting_input") then
			if candidates[id] == nil then
				candidates[id] = if agent.state == "waiting_input" then "alert" else "yield"
			end
		end
	end
	agent_state = now_states

	for id, kind in candidates do
		if config.only_unfocused and focused[id] then
			-- You are looking at it; no chime.
		else
			chime(kind, id)
		end
	end
	seeded = true
end

-- The timer re-arms first so one bad tick can't stop the loop.
local function tick(cx: WindowCx?)
	tern.timer(TICK_MS, tick)
	if cx == nil then
		return
	end
	local ok, err = pcall(tick_body, cx :: WindowCx)
	if not ok then
		tern.log.warn("Chime tick failed: " .. tostring(err))
	end
end

tern.timer(TICK_MS, tick)

tern.on("command_finished", function(ev: CommandFinishedEvent, cx: WindowCx)
	if ev.took_ms < config.min_seconds * 1000 then
		return
	end
	local ok, info = pcall(function(): PaneInfo?
		return cx.session:pane(ev.pane)
	end)
	if not ok or info == nil then
		return
	end
	if config.only_unfocused and info.focused then
		return
	end
	chime("done", ev.pane)
end)

-- Palette + status ----------------------------------------------------------------------------

tern.command({
	id = "mute",
	title = "Chime: Mute / unmute",
	icon = "bell",
	run = function(cx: WindowCx)
		is_muted = not is_muted
		pcall(tern.kv.set, "muted", is_muted)
		tern.chrome.refresh()
		cx:toast("info", "Chime", if is_muted then "Muted" else "Unmuted")
	end,
})

tern.command({
	id = "test",
	title = "Chime: Play test sound",
	icon = "bell",
	run = function(cx: WindowCx)
		local path = config.sounds["yield"]
		if path == nil or path == "" then
			cx:toast("error", "Chime", "No yield sound configured")
			return
		end
		local ok_exists, exists = pcall(tern.fs.exists, path)
		if not ok_exists or not exists then
			cx:toast("error", "Chime", "Missing: " .. path)
			return
		end
		enqueue(path, true)
		cx:toast("info", "Chime", "Playing " .. path)
	end,
})

tern.command({
	id = "reload",
	title = "Chime: Reload sounds",
	icon = "bell",
	run = function(cx: WindowCx)
		config_key = snapshot_key()
		local problems = load_config()
		if #problems == 0 then
			cx:toast("info", "Chime", "Sounds reloaded from " .. config_source)
		else
			cx:toast("error", "Chime", table.concat(problems, "\n"))
		end
	end,
})

tern.command({
	id = "diagnose",
	title = "Chime: Diagnose panes and agents",
	icon = "bell",
	run = function(cx: WindowCx)
		local lines: { string } = {}
		table.insert(lines, "config: " .. config_source)
		table.insert(lines, "muted: " .. tostring(is_muted))
		table.insert(lines, "only_unfocused: " .. tostring(config.only_unfocused))
		table.insert(lines, "min_seconds: " .. tostring(config.min_seconds))
		for _, kind in { "alert", "yield", "done" } do
			local path = config.sounds[kind]
			local mark = "(off)"
			if path ~= nil and path ~= "" then
				local ok_exists, exists = pcall(tern.fs.exists, path)
				mark = path .. (if ok_exists and exists then "" else "  MISSING")
			end
			table.insert(lines, kind .. " = " .. mark)
		end
		table.insert(lines, "")
		table.insert(lines, "panes:")
		for _, pane in cx.session:panes() do
			table.insert(
				lines,
				"  "
					.. tostring(pane.pane)
					.. " kind="
					.. tostring(pane.kind)
					.. " program="
					.. tostring(pane.program)
					.. " busy="
					.. tostring(pane.busy)
					.. " alert="
					.. tostring(pane.alert)
					.. " focused="
					.. tostring(pane.focused)
					.. " at_prompt="
					.. tostring(pane.at_prompt)
					.. " title="
					.. string.sub(pane.title, 1, 60)
			)
		end
		table.insert(lines, "")
		table.insert(lines, "agents:")
		for _, agent in list_agents(cx) do
			table.insert(
				lines,
				"  "
					.. tostring(agent.pane)
					.. " state="
					.. agent.state
					.. " command="
					.. tostring(agent.command)
					.. " model="
					.. tostring(agent.model)
			)
		end
		local out = tern.plugin.data .. SEP .. "diagnose.txt"
		local ok_write, err = pcall(tern.fs.write, out, table.concat(lines, "\n") .. "\n")
		if ok_write then
			cx:toast("info", "Chime", "Wrote " .. out)
		else
			cx:toast("error", "Chime", "Couldn't write " .. out .. ": " .. tostring(err))
		end
	end,
})

-- Mute is invisible otherwise; the segment shows it and clicks back to sound.
tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	if is_muted then
		return { { text = "chime muted", icon = "bell", tone = "muted", command = "plugin.chime.mute" } }
	end
	return nil
end)

-- Startup -------------------------------------------------------------------------------------

refresh_muted()
config_key = snapshot_key()
local startup_problems = load_config()
if #startup_problems > 0 then
	tern.log.warn("Chime: " .. table.concat(startup_problems, "; "))
end
