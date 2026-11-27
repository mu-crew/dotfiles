-- An example ~/.config/rex/init.lua: put the clone's rex/ on package.path,
-- then set up the agent switcher. Use an absolute path in place of the HOME
-- one if you cloned somewhere else.
-- luacheck: read globals rex
package.path = os.getenv("HOME") .. "/.local/share/mu-crew-dotfiles/rex/?.lua;" .. package.path
require("mu-crew").setup({ key = "cmd+j" })
