local install = require("../titles")

local function native(initialFocus, configure)
	local world = { handlers = {}, timers = {}, titleWrites = 0,
		preferences = { enabled = true, owner = "desktop" },
		tabs = { [3] = { id = 3, session = 2, pane = initialFocus or 10 }, [4] = { id = 4, session = 5, pane = 20 } },
		panes = {
			[10] = { pane = 10, tab = 3, title = "Build the editor", program = "omp" },
			[11] = { pane = 11, tab = 3, title = "Review the API", program = "omp" },
			[20] = { pane = 20, tab = 4, title = "Ship the website", program = "omp" },
			[90] = { pane = 90, tab = 3, title = "Attention", block = "tern.canvas" },
			[91] = { pane = 91, tab = 4, title = "Attention", block = "tern.canvas" },
			[92] = { pane = 92, tab = 3, title = "Attention", block = "tern.canvas" },
		},
		canvases = { { pane = 90, owner = "attention", title = "Attention" },
			{ pane = 91, owner = "attention", title = "Attention" },
			{ pane = 92, owner = "another-plugin", title = "Attention" } },
	}
	local cx = { session = {}, canvas = {} }
	local sdk = { kv = {} }
	function cx:window_key() return "desktop" end
	function sdk.kv.get(_key) return world.preferences end
	function cx.session:tabs()
		local result = {}
		for _, tab in world.tabs do table.insert(result, tab) end
		return result
	end
	function cx.session:panes()
		local result = {}
		for _, pane in world.panes do table.insert(result, pane) end
		return result
	end
	function cx.canvas:list() return world.canvases end
	function cx.canvas:set(pane, change)
		local canvas
		for _, candidate in world.canvases do if candidate.pane == pane then canvas = candidate; break end end
		assert(canvas and canvas.owner == "attention", "only a confirmed owned canvas can be retitled")
		assert(utf8.len(change.title) <= 80, "native canvas title exceeds 80 characters")
		canvas.title, world.panes[pane].title = change.title, change.title
		world.titleWrites += 1
	end
	function sdk.on(event, fn) world.handlers[event] = fn end
	function sdk.timer(_ms, fn) table.insert(world.timers, fn) end
	function world:emit(event, payload)
		if self.handlers[event] then self.handlers[event](payload, cx) end
	end
	function world:focus(pane)
		local tab = self.panes[pane].tab
		self.tabs[tab].pane = pane
		self:emit("focus", { pane = pane, tab = tab })
	end
	function world:title(tabId)
		local tab = self.tabs[tabId]
		-- Tern 0.9.8's vertical sidebar uses native names, not chrome formatter output.
		return tab.name or self.panes[tab.pane].title
	end
	if configure then configure(world) end
	install(sdk)
	for _, fn in world.timers do fn(cx) end
	return world
end

do
	local world = native()
	world:focus(90)
	assert(world:title(3) == "Build the editor", "Attention must retain the previously focused content title")
	world:focus(11)
	assert(world:title(3) == "Review the API", "normal content focus keeps native title behavior")
	assert(world.panes[90].title == "Attention", "leaving Attention restores its own pane header")
	assert(world.tabs[3].name == nil, "title presentation must not rename the user's tab")
	world:focus(90)
	assert(world:title(3) == "Review the API", "the most recently focused content pane wins")
	world:focus(91)
	assert(world:title(4) == "Ship the website", "another tab must have its own remembered content pane")
	assert(world:title(3) == "Review the API", "switching tabs must not replace an inactive tab's label")
end

do
	local world = native()
	world:focus(90)
	assert(world:title(3) == "Build the editor")
	world.panes[10].title = "Editor finished"
	world:emit("title", { pane = 10, title = "Editor finished" })
	assert(world:title(3) == "Editor finished", "background source title changes must update the native sidebar label")
	world.panes[11].title = "Unselected work"
	world:emit("title", { pane = 11, title = "Unselected work" })
	assert(world:title(3) == "Editor finished", "a non-selected pane's title must not steal the label")
	world.tabs[3].name = "My explicit name"
	assert(world:title(3) == "My explicit name", "explicit tab names take priority")
	world.tabs[3].name = nil
	assert(world:title(3) == "Editor finished", "clearing an explicit name restores the remembered pane label")
end

do
	local world = native()
	world:focus(92)
	world:focus(90)
	assert(world:title(3) == "Attention", "exclude by canvas owner, not by a matching displayed title")
	world:focus(11)
	world:focus(90)
	world.panes[11] = nil
	world:emit("pane_closed", { pane = 11 })
	assert(world:title(3) == "Build the editor", "closed content must not leave a stale sidebar label")
	world.panes[10].tab = 4
	world:emit("focus", { pane = 90, tab = 3 })
	assert(world:title(3) == "Attention", "a moved pane cannot continue supplying its old tab's label")
end

do
	local world = native(90)
	assert(world:title(3) == "Build the editor", "loading while Attention is focused seeds from existing content")
	world.panes[10].title, world.panes[10].program, world.panes[10].cwd = "", "", "/work/editor"
	world:emit("cwd", { pane = 10, path = "/work/editor" })
	assert(world:title(3) == "editor", "untitled content falls back to its directory")
	world.panes[10].program = "zsh"
	world:emit("command_started", { pane = 10, line = "zsh" })
	assert(world:title(3) == "zsh", "an untitled running program is a useful fallback")
	local writes = world.titleWrites
	world:emit("title", { pane = 10, title = "" })
	assert(world.titleWrites == writes, "unchanged observations must not repeatedly rewrite native canvas titles")
end

do
	local world = native()
	-- Native events are queued: the snapshot can already show Attention by delivery time.
	world.tabs[3].pane = 90
	world:emit("focus", { pane = 11, tab = 3 })
	world:emit("focus", { pane = 90, tab = 3 })
	assert(world:title(3) == "Review the API", "queued focus events must retain the actual last content selection")
	world.tabs[3], world.panes[10], world.panes[11], world.panes[90], world.panes[92] = nil, nil, nil, nil, nil
	world:emit("tab_closed", { tab = 3 })
	world.tabs[3] = { id = 3, pane = 90 }
	world.panes[90] = { pane = 90, tab = 3, title = "Attention", block = "tern.canvas" }
	world:emit("tab_created", { tab = 3 })
	assert(world:title(3) == "Attention", "a tab without content must not inherit a closed tab's label")
end

do
	local world = native(90, function(state)
		state.canvases = { { pane = 92, owner = "another-plugin" } }
		state.preferences = { enabled = true, owner = "desktop", instances = { localHost = {
			["3"] = { tab = 3, session = 2, pane = 90 },
			["foreign"] = { tab = 3, session = 2, pane = 92 },
		} } }
	end)
	assert(world:title(3) == "Attention" and world.titleWrites == 0,
		"missing canvas metadata must not trigger an unsafe title write")
	world:focus(11)
	world:focus(90)
	table.insert(world.canvases, { pane = 90, owner = "attention", title = "Attention" })
	world:emit("title", { pane = 90, title = "Attention" })
	assert(world:title(3) == "Review the API", "metadata arrival must retain the last real content selection")
	world:focus(92)
	world:focus(90)
	assert(world:title(3) == "Attention", "explicit native ownership overrides a stale saved registry entry")
end

do
	local world = native(nil, function(state) state.preferences.owner = "another-window" end)
	world:focus(90)
	assert(world:title(3) == "Attention" and world.titleWrites == 0,
		"a second window must not compete with the Attention owner for shared pane titles")
	world.preferences.owner, world.preferences.enabled = "desktop", false
	world:focus(10)
	world:focus(90)
	assert(world:title(3) == "Attention" and world.titleWrites == 0, "disabled Attention must not mutate pane titles")
end

do
	local world = native()
	world.panes[10].title = string.rep("字", 81)
	world:focus(90)
	assert(world:title(3) == string.rep("字", 80), "long titles must respect the native limit without splitting UTF-8")
end

print("Attention sidebar title checks passed")
return true
