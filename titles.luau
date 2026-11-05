local function label(pane: { title: string?, program: string?, cwd: string? }): string?
	local title = pane.title
	if not title or title == "" then title = pane.program end
	if not title or title == "" then
		title = if pane.cwd and pane.cwd ~= "" then pane.cwd:match("([^/]+)/*$") or pane.cwd else nil
	end
	if not title then return nil end
	local limit = utf8.offset(title, 81)
	return if limit then title:sub(1, limit - 1) else title
end

local function install(tern)
	local tabs = {}

	local function refresh(cx, focused)
		local prefs = tern.kv.get("preferences")
		if type(prefs) ~= "table" or not prefs.enabled or prefs.owner ~= cx:window_key() then return end
		local attention, known, panes, fallback, present = {}, {}, {}, {}, {}
		local nativeCanvases = cx.canvas:list()
		for _, canvas in nativeCanvases do
			known[canvas.pane] = true
			if canvas.owner == "attention" then attention[canvas.pane] = true end
		end
		for _, pane in cx.session:panes() do panes[pane.pane] = pane end
		local nativeTabs = cx.session:tabs()
		for _, tab in nativeTabs do present[tab.id] = tab end
		-- Restored native canvases can be listed as panes before their owner metadata arrives.
		if type(prefs.instances) == "table" then
			for _, instances in prefs.instances do
				if type(instances) ~= "table" then continue end
				for _, saved in instances do
					if type(saved) ~= "table" then continue end
					local pane = panes[saved.pane]
					local tab = pane and present[pane.tab]
					if not known[saved.pane] and pane and pane.block == "tern.canvas" and tab
						and tab.id == saved.tab and tab.session == saved.session then
						attention[saved.pane] = true
					end
				end
			end
		end
		for _, pane in panes do
			if pane.tab and not pane.parked and not attention[pane.pane] then
				local previous = fallback[pane.tab]
				if not previous or pane.pane < previous.pane then fallback[pane.tab] = pane end
			end
		end
		local selected = panes[focused]
		for _, tab in nativeTabs do
			local saved = tabs[tab.id]
			if not saved then saved = {}; tabs[tab.id] = saved end
			-- Events are queued; their selection can precede the focus in this snapshot.
			local current = if selected and selected.tab == tab.id then selected else panes[tab.pane]
			if current and current.tab == tab.id and not current.parked and not attention[current.pane] then
				saved.pane = current.pane
			end
			local source = panes[saved.pane]
			if not source or source.tab ~= tab.id or source.parked or attention[source.pane] then
				source = fallback[tab.id]
				saved.pane = if source then source.pane else nil
			end
			local title = if source then label(source) else nil
			local attentionPane = if attention[tab.pane] then tab.pane else nil
			saved.title, saved.attentionPane = title, attentionPane
		end
		for tab in tabs do
			if not present[tab] then tabs[tab] = nil end
		end
		for _, canvas in nativeCanvases do
			if canvas.owner ~= "attention" then continue end
			local pane = panes[canvas.pane]
			if not pane then continue end
			local saved = tabs[pane.tab]
			local title = if saved and saved.attentionPane == canvas.pane then saved.title or "Attention" else "Attention"
			if canvas.title ~= title then cx.canvas:set(canvas.pane, { title = title }) end
		end
	end

	tern.on("focus", function(ev, cx) refresh(cx, ev.pane) end)
	for _, event in { "title", "cwd", "command_started", "command_finished", "pane_created", "pane_closed",
		"tab_created", "tab_closed" } do
		tern.on(event, function(_ev, cx) refresh(cx) end)
	end
	-- A reload does not deliver window_start to an existing plugin.
	tern.timer(0, function(cx) refresh(cx) end)
end

return install
