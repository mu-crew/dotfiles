import { execFile } from "node:child_process";
import { Plugin } from "@opencode/plugin/tui";

// A TUI plugin, not a server one: OpenCode 2 runs server plugins in one shared
// background service whose $TMUX_PANE is whichever pane first started it, so
// every notification landed on that pane. A TUI plugin runs in the terminal
// process, where $TMUX_PANE (murmur notify's default --pane) is this pane.
export default Plugin.define({
	id: "murmur.notify",
	setup(ctx) {
		const notify = (type: string, message: string) => {
			const payload = JSON.stringify({ source: "opencode", type, title: "OpenCode", message });
			const child = execFile("murmur", ["notify"], () => {});
			child.stdin?.on("error", () => {}).end(payload);
		};

		// Every TUI receives every session's events, including sessions another
		// TUI started. A root session is ours once this TUI has shown it, as the
		// routed session or an open tab. Claimed on every event, so a session
		// started here stays ours after navigating away before it finishes.
		const mine = new Set<string>();
		const claim = () => {
			const route = ctx.ui.router.current();
			if (route.type === "session") mine.add(ctx.data.session.root(route.sessionID));
			if (ctx.ui.tabs.enabled()) for (const tab of ctx.ui.tabs.list()) mine.add(ctx.data.session.root(tab.sessionID));
		};
		const isMine = (sessionID: string) => {
			claim();
			return mine.has(ctx.data.session.root(sessionID));
		};

		const unsubscribe = [
			ctx.data.listen(claim),
			// murmur keys on "session.idle"; 2.0.32 reports a finished turn as
			// session.execution.succeeded instead.
			ctx.data.on("session.execution.succeeded", (event) => {
				const { sessionID } = event.data;
				if (!isMine(sessionID)) return;
				const session = ctx.data.session.get(sessionID);
				// Only a known subagent is skipped; unknown sessions still notify.
				if (session?.parentID) return;
				notify("session.idle", session?.title || "Task completed");
			}),
			ctx.data.on("permission.asked", (event) => {
				const { sessionID, action, resources } = event.data;
				if (!isMine(sessionID)) return;
				const detail = resources.length ? `: ${resources.join(", ")}` : "";
				notify("permission.asked", `${action}${detail}`);
			}),
		];
		return () => {
			for (const off of unsubscribe) off();
		};
	},
});
