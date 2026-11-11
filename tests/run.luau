-- One require per suite, in dependency order. The luau CLI returns a failed COMPILE as the
-- module's value instead of raising it, so a suite with a syntax error would otherwise be
-- skipped silently and the battery would still print its pass lines. Guard: a failed load
-- yields an error STRING; a healthy suite never returns a string.
for _, name in {
	"model.test", "identity.test", "durable.test", "triage.test", "layout.test",
	"view.test", "titles.test", "navigation.test", "phone.test", "controller.test",
	"host.test", "phone_package.test",
} do
	local module = require("./" .. name)
	assert(type(module) ~= "string", name .. " failed to load: " .. tostring(module))
end
print("Attention behavior checks passed")
